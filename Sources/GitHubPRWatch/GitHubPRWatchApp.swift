import GitHubPRWatchCore
import GitHubPRWatchUI
import SwiftUI

/// A menu bar app (LSUIElement) with one main window. The window opens at launch only while
/// setup is unfinished; the app shows a Dock icon while it is open.
@main
struct GitHubPRWatchApp: App {
    @State private var services = AppServices.live()

    var body: some Scene {
        Window(AppInfo.name, id: AppInfo.mainWindowID) {
            MainWindowView(store: services.store, notifier: services.notifier)
        }
        .defaultSize(width: 1100, height: 680)
        .defaultLaunchBehavior(services.store.needsOnboarding ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarPopoverView(store: services.store)
        } label: {
            MenuBarLabel(count: services.store.yourMoveCount)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: services.store, notifier: services.notifier)
        }
    }
}
