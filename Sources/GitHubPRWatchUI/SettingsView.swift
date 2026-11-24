import GitHubPRWatchCore
import SwiftUI

/// STUB for the settings phase: account, watched repos, views, and polling. The settings
/// agent owns this file.
public struct SettingsView: View {
    let store: PRStore
    let notifier: any Notifier

    public init(store: PRStore, notifier: any Notifier) {
        self.store = store
        self.notifier = notifier
    }

    public var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") { account }
            Tab("Views", systemImage: "line.3.horizontal.decrease.circle") { ViewEditorView(store: store) }
        }
        .frame(width: 520, height: 460)
    }

    private var account: some View {
        Form {
            Section("GitHub") {
                if let viewer = store.viewer {
                    LabeledContent("Signed in as") { Text("@\(viewer.login)") }
                    LabeledContent("Using") { Text(store.authMethod.map(Self.describe) ?? "") }
                    Button("Sign Out") { store.signOut() }
                } else {
                    Text("Not signed in. Open the main window to sign in.").foregroundStyle(.secondary)
                }
            }
            Section("Watched repos") {
                if store.watchedRepos.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(store.watchedRepos, id: \.self) { Text($0) }
            }
            Section("Polling") {
                ConnectionStatusView(store: store)
                if let limit = store.rateLimit {
                    LabeledContent("Rate limit") {
                        Text("\(limit.remaining) of \(limit.limit) points left, resets \(limit.resetAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func describe(_ method: AuthMethod) -> String {
        switch method {
        case .githubCLI: "GitHub CLI login"
        case .deviceFlow: "Sign in with GitHub"
        case .pastedToken: "Pasted token"
        }
    }
}
