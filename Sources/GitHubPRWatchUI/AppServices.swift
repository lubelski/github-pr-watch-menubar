import AppKit
import GitHubPRWatchCore
import SwiftUI

/// Names shared by the app's scenes.
public enum AppInfo {
    /// The static window title, centered in a plain title bar.
    public static let name = "GitHub PR Watch"
    public static let mainWindowID = "main"
}

/// The store, the notifier and the menu bar activity, wired together. One per process.
@MainActor
public final class AppServices {
    public let store: PRStore
    public let notifier: any Notifier
    public let activity: MenuBarActivity
    private var wakeObserver: (any NSObjectProtocol)?

    public init(store: PRStore, notifier: any Notifier, activity: MenuBarActivity = MenuBarActivity()) {
        self.store = store
        self.notifier = notifier
        self.activity = activity
        store.onEvents = { [weak store, weak notifier, weak activity] events in
            guard let store, let notifier, let activity else { return }
            activity.handle(events, settings: store.notificationSettings, notifier: notifier)
        }
    }

    /// The real app: live dependencies, banners, and a refresh on wake. Starts polling
    /// when onboarding is already done.
    public static func live() -> AppServices {
        let services = AppServices(store: PRStore(dependencies: .live()), notifier: UserNotifier())
        services.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak store = services.store] _ in
            MainActor.assumeIsolated { store?.refreshNow() }
        }
        services.store.start()
        return services
    }

    /// Lets a summary banner open the main window. Call from a view that can open windows.
    public func registerWindowOpener(_ open: @escaping @MainActor () -> Void) {
        (notifier as? UserNotifier)?.openApp = open
    }
}
