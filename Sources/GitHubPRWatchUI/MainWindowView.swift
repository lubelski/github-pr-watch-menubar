import GitHubPRWatchCore
import SwiftUI

/// The main window's root: onboarding until setup is done, then the lanes.
public struct MainWindowView: View {
    let store: PRStore
    let notifier: any Notifier

    public init(store: PRStore, notifier: any Notifier) {
        self.store = store
        self.notifier = notifier
    }

    public var body: some View {
        Group {
            if store.needsOnboarding {
                OnboardingView(store: store, notifier: notifier)
            } else {
                LanesWindowView(store: store)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .showsDockIconWhileOpen()
    }
}
