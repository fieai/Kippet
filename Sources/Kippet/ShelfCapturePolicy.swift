enum ShelfCapturePolicy {
    static func changeToPoll(current: Int, last: Int, isPaused: Bool, expected: Int? = nil) -> Int? {
        guard !isPaused, last != current, expected == nil || expected == current else { return nil }
        return current
    }

    static func changeToSchedule(pending: Int?, scheduled: Int?) -> Int? {
        guard let pending, scheduled != pending else { return nil }
        return pending
    }

    static func allowsSource(
        bundleIdentifier: @autoclosure () -> String?, stable: Bool, excluding excludedApps: [ExcludedApp]
    ) -> Bool {
        if excludedApps.isEmpty { return true }
        guard stable, let bundleIdentifier = bundleIdentifier() else { return false }
        return !excludedApps.contains { $0.id == bundleIdentifier }
    }
}

struct ShelfPollingState: Sendable {
    var screensAsleep = false
    var systemAsleep = false
    var screenLocked = false
    var sessionInactive = false

    func shouldPoll(isPaused: Bool) -> Bool {
        !screensAsleep && !systemAsleep && !screenLocked && !sessionInactive && !isPaused
    }
}
