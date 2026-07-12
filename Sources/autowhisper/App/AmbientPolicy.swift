import Foundation

/// Decides when an ambient (always-on) session should roll over to a new one.
/// A session closes on any of: a long continuous silence gap (a natural
/// conversation boundary), a hard length cap, or a calendar-day boundary.
/// Pure logic — the owner drives capture start/stop from its verdict.
struct AmbientPolicy {
    // 10 min of quiet ends a session. User-tunable in minutes (Settings); a
    // separate seconds key stays for testing overrides.
    static var silenceRollover: Double {
        let minutes = UserDefaults.standard.double(forKey: "ambientSilenceMinutes")
        if minutes > 0 { return minutes * 60 }
        let override = UserDefaults.standard.double(forKey: "silenceRolloverOverride")
        return override > 0 ? override : 600
    }
    static var maxSessionSeconds: Double {
        let hours = UserDefaults.standard.double(forKey: "ambientMaxHours")
        if hours > 0 { return hours * 3600 }
        let override = UserDefaults.standard.double(forKey: "maxSessionOverride")
        return override > 0 ? override : 4 * 3600
    }
    static var minFreeBytes: Int64 {   // pause ambient below this many GB free
        let gb = UserDefaults.standard.double(forKey: "ambientMinFreeGB")
        return Int64((gb > 0 ? gb : 5) * 1_073_741_824)
    }

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
