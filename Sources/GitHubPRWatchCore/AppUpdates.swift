import Foundation

/// The rules for updating the app, kept apart from Sparkle so they can be tested. The app
/// target's `AppUpdater` is the only code that talks to Sparkle.
///
/// Only a release build updates itself. `scripts/release.sh` has `scripts/bundle.sh` write the
/// feed address and the public signing key into Info.plist. A build without them never
/// updates itself, so a development copy is never replaced by a release.
public enum AppUpdates {
    /// Whether a bundle with this Info.plist has a feed to update from.
    public static func hasFeed(_ info: [String: Any]?) -> Bool {
        guard let feed = info?["SUFeedURL"] as? String, let key = info?["SUPublicEDKey"] as? String else {
            return false
        }
        return !feed.isEmpty && !key.isEmpty
    }

    /// What the app is doing that a relaunch would cut off.
    public struct Activity: Equatable, Sendable {
        /// A poll is running. A relaunch would drop it halfway and poll again from the start.
        public var polling: Bool
        /// A sign-in is under way: a token being checked, or a device-flow code on screen.
        public var signingIn: Bool
        /// A window of the app is open, or the app is in front. The person may be editing a
        /// view or typing a token, which live only in the window until saved.
        public var inUse: Bool

        public init(polling: Bool = false, signingIn: Bool = false, inUse: Bool = false) {
            self.polling = polling
            self.signingIn = signingIn
            self.inUse = inUse
        }
    }

    /// Why an update that is ready waits instead of relaunching the app now.
    public enum Wait: Equatable, Sendable {
        case signingIn
        case inUse
        case polling
    }

    /// Nil when the app may quit and relaunch into an update now. Otherwise the first thing
    /// that holds it back.
    public static func wait(for activity: Activity) -> Wait? {
        if activity.signingIn { return .signingIn }
        if activity.inUse { return .inUse }
        if activity.polling { return .polling }
        return nil
    }

    public static func mayRelaunch(_ activity: Activity) -> Bool {
        wait(for: activity) == nil
    }
}
