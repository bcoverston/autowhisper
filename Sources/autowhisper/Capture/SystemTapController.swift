import AVFoundation
import CoreAudio
import Foundation

/// One capture stream inside the aggregate device: its ring, format, and origin.
struct CaptureStream {
    let ring: AudioRingBuffer
    let sampleRate: Double
    let isMic: Bool
}

/// Owns the Core Audio process tap + aggregate device (system audio + mic as a
/// drift-compensated sub-device) and pumps every input stream into a ring buffer.
///
/// Verified in Spikes/tap: input buffer order is [mic streams…, tap streams…];
/// the mic's input-stream count is queried so the split is not hardcoded.
final class SystemTapController {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "autowhisper.capture.io", qos: .userInteractive)
    private(set) var streams: [CaptureStream] = []

    enum TapError: Error {
        case osStatus(String, OSStatus)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.osStatus(what, status) }
    }

    private func property(_ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = property(selector)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
                  "get default device")
        return deviceID
    }

    private func deviceUID(of deviceID: AudioObjectID) throws -> String {
        var address = property(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }, "get device UID")
        return uid as String
    }

    private func inputStreamCount(of deviceID: AudioObjectID) throws -> Int {
        var address = property(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size), "get stream list size")
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Creates tap + aggregate and starts IO. Ring buffers begin filling immediately.
    func start() throws {
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.name = "autowhisper system tap"
        tapDescription.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create process tap")

        var formatAddress = property(kAudioTapPropertyFormat)
        var tapASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &tapASBD), "get tap format")

        let micID = try defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let micStreams = try inputStreamCount(of: micID)
        var micASBD = AudioStreamBasicDescription()
        var micFormatAddress = property(kAudioStreamPropertyVirtualFormat, scope: kAudioObjectPropertyScopeInput)
        var micASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(micID, &micFormatAddress, 0, nil, &micASBDSize, &micASBD) != noErr {
            micASBD.mSampleRate = tapASBD.mSampleRate   // fall back to tap rate
        }

        let outputUID = try deviceUID(of: try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
        let micUID = try deviceUID(of: micID)
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "autowhisper capture",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
                [kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "create aggregate device")

        // Buffer order: mic sub-device input streams first, then tap streams.
        // 8 s of headroom per ring at the native rate.
        let ringCapacity = Int(tapASBD.mSampleRate * 8)
        streams = (0..<(micStreams + 1)).map { index in
            CaptureStream(
                ring: AudioRingBuffer(capacity: ringCapacity),
                sampleRate: index < micStreams ? micASBD.mSampleRate : tapASBD.mSampleRate,
                isMic: index < micStreams)
        }

        let rings = streams.map(\.ring)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, _, _, _ in
            // Realtime path: memcpy into rings only.
            let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for (index, buffer) in ablPointer.enumerated() where index < rings.count {
                guard let data = buffer.mData else { continue }
                rings[index].write(data.assumingMemoryBound(to: Float.self),
                                   count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            }
        }, "create IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
