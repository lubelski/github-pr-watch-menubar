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
            MainWindowView(store: services.store, notifier: services.notifier, activity: services.activity)
        }
        .defaultSize(width: 1100, height: 680)
        // The title row above the toolbar row, so the centered app name has a row of its own.
        .windowToolbarStyle(.expanded)
        .defaultLaunchBehavior(services.store.needsOnboarding ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarPopoverView(store: services.store, activity: services.activity)
        } label: {
            MenuBarItemLabel(services: services)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: services.store, notifier: services.notifier)
        }
        .windowResizability(.contentMinSize)
    }
}
