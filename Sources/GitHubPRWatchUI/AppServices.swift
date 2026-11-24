import AppKit
import GitHubPRWatchCore
import SwiftUI

/// Names shared by the app's scenes.
public enum AppInfo {
    /// The static window title, centered in a plain title bar.
    public static let name = "GitHub PR Watch"
    public static let mainWindowID = "main"
}

/// The store and the notifier, wired together. One per process.
@MainActor
public final class AppServices {
    public let store: PRStore
    public let notifier: any Notifier
    private var wakeObserver: (any NSObjectProtocol)?

    public init(store: PRStore, notifier: any Notifier) {
        self.store = store
        self.notifier = notifier
        store.onEvents = { [weak notifier] events in notifier?.post(events) }
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
}
