import AVFoundation
import CoreAudio
import Foundation

/// Owns the Core Audio process tap + aggregate device for system audio and
/// pumps it into a ring buffer. The microphone is captured separately
/// (MicCapture) so it can be engaged/released on demand.
///
/// Aggregates do NOT follow default-device changes (sub-devices are fixed by
/// UID at creation), and after Bluetooth renegotiation the IOProc can keep
/// firing with all-zero buffers. `onInvalidated` fires on the relevant HAL
/// property changes; the owner debounces and calls `rebuild()`, which tears
/// down and recreates BOTH tap and aggregate (the only reliable recovery).
final class SystemTapController {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var mainOutputID = AudioObjectID(kAudioObjectUnknown)
    private let ioQueue = DispatchQueue(label: "autowhisper.capture.io", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "autowhisper.capture.listeners")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    let ring = AudioRingBuffer(capacity: 48_000 * 8)
    private(set) var sampleRate: Double = 48_000

    /// Fired (possibly repeatedly, from a HAL queue) when the default output
    /// device or its sample rate changes. Owner debounces + calls rebuild().
    var onInvalidated: (@Sendable () -> Void)?

    enum TapError: Error {
        case osStatus(String, OSStatus)
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.osStatus(what, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var addr = address(selector)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID),
                  "get default device")
        return deviceID
    }

    private static func stringProperty(of deviceID: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }, "get device string property")
        return value as String
    }

    static func deviceName(_ selector: AudioObjectPropertySelector) -> String {
        (try? stringProperty(of: defaultDevice(selector), kAudioObjectPropertyName)) ?? "unknown device"
    }

    /// Creates tap + aggregate, starts IO into `ring`, installs change listeners.
    func start() throws {
        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.name = "autowhisper system tap"
        tapDescription.isPrivate = true
        try Self.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create process tap")

        var formatAddress = Self.address(kAudioTapPropertyFormat)
        var tapASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &tapASBD),
                       "get tap format")
        sampleRate = tapASBD.mSampleRate

        mainOutputID = try Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let outputUID = try Self.stringProperty(of: mainOutputID, kAudioDevicePropertyDeviceUID)
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "autowhisper capture",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                       "create aggregate device")
        self.aggregateID = aggregateID

        let ring = self.ring
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, _, _, _ in
            // Realtime path: memcpy into the ring only.
            let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for buffer in ablPointer {
                guard let data = buffer.mData else { continue }
                ring.write(data.assumingMemoryBound(to: Float.self),
                           count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            }
        }, "create IOProc")
        try Self.check(AudioDeviceStart(aggregateID, procID), "start aggregate device")

        installListeners()
    }

    func stop() {
        removeListeners()
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

    /// Full destroy-both/recreate-both — the only reliable recovery for
    /// device changes and the zero-buffer failure mode.
    func rebuild() throws {
        stop()
        try start()
    }

    private func installListeners() {
        let notify: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onInvalidated?()
        }
        var targets: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultOutputDevice)),
        ]
        if mainOutputID != kAudioObjectUnknown {
            targets.append((mainOutputID, Self.address(kAudioDevicePropertyNominalSampleRate)))
        }
        for (object, address) in targets {
            var addr = address
            if AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, notify) == noErr {
                listeners.append((object, address, notify))
            }
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, listenerQueue, block)
        }
        listeners.removeAll()
    }
}
