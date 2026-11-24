import GitHubPRWatchCore
import GitHubPRWatchUI
import SwiftUI

/// A menu bar app (LSUIElement) with one main window. The window opens at launch only while
/// setup is unfinished; the app shows a Dock icon while it is open.
@main
struct GitHubPRWatchApp: App {
    @State private var services: AppServices
    /// Sparkle, in a release build. See `AppUpdater`.
    @State private var updater: AppUpdater

    init() {
        let services = AppServices.live()
        _services = State(initialValue: services)
        _updater = State(initialValue: AppUpdater { [store = services.store] in .current(store) })
    }

    var body: some Scene {
        Window(AppInfo.name, id: AppInfo.mainWindowID) {
            MainWindowView(store: services.store, notifier: services.notifier)
        }
        .defaultSize(width: 1100, height: 680)
        // The title row above the toolbar row, so the centered app name has a row of its own.
        .windowToolbarStyle(.expanded)
        .defaultLaunchBehavior(services.store.needsOnboarding ? .presented : .suppressed)
        .commands {
            // The app menu shows while the main window is open and the app is a regular app.
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
            }
        }

        MenuBarExtra {
            MenuBarPopoverView(store: services.store)
        } label: {
            MenuBarItemLabel(services: services)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: services.store, notifier: services.notifier, updater: updater)
        }
        .windowResizability(.contentMinSize)
    }
}
