import Foundation

/// Keeps macOS from applying App Nap / timer coalescing to this process while audio is
/// flowing. Without it a receiver whose window is hidden behind another window sees its
/// network callbacks delayed by 100 ms or more, which shows up as jitter and underruns.
final class ActivityGuard {
    private var token: NSObjectProtocol?
    private let reason: String

    init(reason: String) { self.reason = reason }

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical, .suddenTerminationDisabled],
            reason: reason)
    }

    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }

    deinit { end() }
}
