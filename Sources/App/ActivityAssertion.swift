import Foundation

/// Holds a `ProcessInfo` activity assertion for as long as there is work worth protecting.
///
/// Without one, macOS App Nap throttles timers, thread priority, and network activity once the
/// app has been in the background for a while — which for a downloader means transfers quietly
/// slowing down whenever the user switches to another app.
///
/// `userInitiatedAllowingIdleSystemSleep` opts out of App Nap (and sudden termination) while
/// still letting the Mac sleep on idle as usual; keeping the machine awake outright would be
/// `.userInitiated`.
@MainActor
final class ActivityAssertion {
    private var token: NSObjectProtocol?
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    var isActive: Bool { token != nil }

    /// Begins or ends the assertion to match `active`. Redundant calls are ignored, so this is
    /// safe to drive straight from a state-change stream.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            token = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: reason
            )
        } else if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}
