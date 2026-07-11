import Foundation

/// Decides when an ambient (always-on) session should roll over to a new one.
/// A session closes on any of: a long continuous silence gap (a natural
/// conversation boundary), a hard length cap, or a calendar-day boundary.
/// Pure logic — the owner drives capture start/stop from its verdict.
struct AmbientPolicy {
    // 10 min of quiet ends a session; overridable (defaults key) for testing.
    static var silenceRollover: Double {
        let override = UserDefaults.standard.double(forKey: "silenceRolloverOverride")
        return override > 0 ? override : 600
    }
    static var maxSessionSeconds: Double {
        let override = UserDefaults.standard.double(forKey: "maxSessionOverride")
        return override > 0 ? override : 4 * 3600
    }
    static let minFreeBytes: Int64 = 5 * 1_073_741_824   // pause below 5 GB

    enum Rollover: Equatable {
        case none
        case silence
        case tooLong
        case dayBoundary
    }

    /// `sessionStart` and `silenceRunSeconds` come from the live pipeline; `now`
    /// and `startOfToday` are injected so this stays testable and pure.
    static func rollover(sessionStart: Date, silenceRunSeconds: Double,
                         now: Date, startOfToday: Date) -> Rollover {
        if silenceRunSeconds >= silenceRollover { return .silence }
        if now.timeIntervalSince(sessionStart) >= maxSessionSeconds { return .tooLong }
        if sessionStart < startOfToday { return .dayBoundary }
        return .none
    }

    static func hasFreeSpace() -> Bool {
        let values = try? SessionStore.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= minFreeBytes
    }
}
