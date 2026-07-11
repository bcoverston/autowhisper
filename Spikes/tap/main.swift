// Spike a: capture system audio via a Core Audio process tap (optionally + mic
// in the same aggregate device) and write WAV files. Throwaway code.
//
// Usage: spike-tap [seconds] [--with-mic]
// Output: ~/Desktop/spike-tap-<stream>.wav

import AVFoundation
import CoreAudio
import Foundation

if CommandLine.arguments.contains("--log") {
    let logPath = FileManager.default.currentDirectoryPath + "/Spikes/out/spike-tap.log"
    freopen(logPath, "w", stdout)
    freopen(logPath, "a", stderr)
}
setvbuf(stdout, nil, _IONBF, 0)

nonisolated func runSpike() {

    let seconds = Double(CommandLine.arguments.dropFirst().first(where: { Double($0) != nil }) ?? "10") ?? 10
    let withMic = CommandLine.arguments.contains("--with-mic")

    func check(_ status: OSStatus, _ what: String) {
        guard status == noErr else {
            fatalError("\(what) failed: \(status)")
        }
    }

    func deviceUID(of deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        check(withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }, "get device UID")
        return uid as String
    }

    func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
              "get default device")
        return deviceID
    }

    // 1. Global mono tap over all system audio.
    let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    tapDescription.uuid = UUID()
    tapDescription.muteBehavior = .unmuted
    tapDescription.name = "spike-tap"
    tapDescription.isPrivate = true

    var tapID = AudioObjectID(kAudioObjectUnknown)
    check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")
    print("tap created: \(tapID)")

    // 2. Tap stream format.
    var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var tapASBD = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &tapASBD), "get tap format")
    print("tap format: \(tapASBD.mSampleRate) Hz, \(tapASBD.mChannelsPerFrame) ch")

    // 3. Aggregate device: real output as main sub-device + the tap (+ mic when asked).
    let outputUID = deviceUID(of: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
    if withMic {
        let micUID = deviceUID(of: defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
        subDevices.append([kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1])
        print("mic sub-device: \(micUID)")
    }
    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceNameKey: "spike-tap-aggregate",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: subDevices,
        kAudioAggregateDeviceTapListKey: [
            [kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
          "AudioHardwareCreateAggregateDevice")
    print("aggregate created: \(aggregateID)")

    // 4. IOProc: write every input stream to its own WAV (file I/O is fine for a spike).
    let desktop = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Spikes/out")
    final class StreamWriter {
        var files: [AVAudioFile] = []
        var formats: [AVAudioFormat] = []
        var buffersLogged = false
    }
    let writer = StreamWriter()
    let queue = DispatchQueue(label: "spike-tap-io")

    var procID: AudioDeviceIOProcID?
    check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
        let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        if !writer.buffersLogged {
            writer.buffersLogged = true
            print("input streams: \(ablPointer.count) buffers: " +
                  ablPointer.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", "))
        }
        for (index, buffer) in ablPointer.enumerated() {
            if writer.files.count <= index {
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: tapASBD.mSampleRate,
                    channels: buffer.mNumberChannels,
                    interleaved: true)!
                let url = desktop.appending(path: "spike-tap-stream\(index).wav")
                try? FileManager.default.removeItem(at: url)
                guard let file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                                  commonFormat: .pcmFormatFloat32, interleaved: true) else {
                    continue
                }
                writer.files.append(file)
                writer.formats.append(format)
            }
            let format = writer.formats[index]
            var singleBuffer = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &singleBuffer) else { continue }
            try? writer.files[index].write(from: pcm)
        }
    }, "create IOProc")

    check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    print("recording \(Int(seconds))s… play some audio\(withMic ? " and speak" : "")")
    Thread.sleep(forTimeInterval: seconds)

    check(AudioDeviceStop(aggregateID, procID), "AudioDeviceStop")
    AudioDeviceDestroyIOProcID(aggregateID, procID!)
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    writer.files.removeAll()   // finalize WAV headers
    print("done → Spikes/out/spike-tap-stream*.wav")

}

runSpike()
