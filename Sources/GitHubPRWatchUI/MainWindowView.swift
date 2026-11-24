import GitHubPRWatchCore
import SwiftUI

/// The main window's root: onboarding until setup is done, then the lanes.
///
/// The title bar says the app's name, centered. The lanes add their controls to the window's
/// toolbar under it; onboarding adds none, so while it shows the window has the title bar only.
///
/// Signing out after setup brings onboarding back so you can sign in again. As soon as a
/// sign-in succeeds, the lanes return with the same repos and views, and a poll starts.
///
/// Bringing the window to the front counts as looking, so it clears the menu bar badge.
public struct MainWindowView: View {
    let store: PRStore
    let notifier: any Notifier
    let activity: MenuBarActivity?
    @Environment(\.appearsActive) private var appearsActive
    /// Set when the account signs out after setup; cleared by the next successful sign-in.
    @State private var signingInAgain = false

    public init(store: PRStore, notifier: any Notifier, activity: MenuBarActivity? = nil) {
        self.store = store
        self.notifier = notifier
        self.activity = activity
    }

    private var showsOnboarding: Bool {
        store.needsOnboarding || signingInAgain || store.auth == .signedOut
    }

    public var body: some View {
        Group {
            if showsOnboarding {
                OnboardingView(store: store, notifier: notifier)
            } else {
                LanesWindowView(store: store)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .centeredTitleBar()
        .showsDockIconWhileOpen()
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { activity?.markSeen() }
        }
        .onChange(of: store.auth) { _, auth in
            switch auth {
            case .signedOut:
                signingInAgain = !store.needsOnboarding
            case .signedIn:
                // During first setup, onboarding's Start Watching starts polling instead.
                if !store.needsOnboarding {
                    signingInAgain = false
                    store.refreshNow()
                }
            default:
                break
            }
        }
    }
}
