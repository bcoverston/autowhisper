import Foundation
import whisper

/// A lock-guarded holder for a whisper context pointer, shared between an
/// actor (which loads/uses it) and the synchronous process-exit teardown
/// (which frees it while the Metal device is still valid). `@unchecked
/// Sendable` because access is manually serialized by the lock.
final class WhisperContextBox: @unchecked Sendable {
    private var ctx: OpaquePointer?
    private let lock = NSLock()

    func get() -> OpaquePointer? {
        lock.withLock { ctx }
    }

    func set(_ pointer: OpaquePointer?) {
        lock.withLock { ctx = pointer }
    }

    func free() {
        lock.withLock {
            if let c = ctx { whisper_free(c); ctx = nil }
        }
    }
}
