import GitHubPRWatchCore

/// What Settings needs from the updater. The app target's `AppUpdater` is the real one and the
/// only code that imports Sparkle, so this library and the render tool never link it.
@MainActor
public protocol AppUpdating: AnyObject {
    /// Whether this build can update itself. Only a release build, whose Info.plist has a
    /// feed and a public key, can.
    var isAvailable: Bool { get }
    /// False while a check is already running.
    var canCheck: Bool { get }
    /// Whether updates are looked for, downloaded, and installed without asking.
    var updatesAutomatically: Bool { get set }
    /// Checks now and shows the result in the updater's own window.
    func checkForUpdates()
}

/// A build that does not update itself: development builds, renders, and tests.
@MainActor
public final class NoUpdater: AppUpdating {
    public init() {}
    public var isAvailable: Bool { false }
    public var canCheck: Bool { false }
    public var updatesAutomatically: Bool {
        get { false }
        set {}
    }
    public func checkForUpdates() {}
}
