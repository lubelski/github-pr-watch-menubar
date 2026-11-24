import AppKit
import GitHubPRWatchCore
import SwiftUI

/// Settings: account, watched repos, notifications, views, polling and updates, experiments,
/// and debugging.
///
/// The layout is the one in the sibling app mac-os-agent (`SettingsRootView` in its
/// `SettingsWindow.swift`): a sidebar of sections with symbols, at a fixed width, beside the
/// selected section. It is a plain row rather than a split view, so the sidebar can't be
/// dragged or collapsed and there is no sidebar button. The sections come from `SettingsTab`
/// in Core. The title bar says the app's name, centered, the same as the main window, with a
/// hairline under it. (mac-os-agent titles its window after the section; this app keeps the
/// app's name so every window says which app it belongs to.)
public struct SettingsView: View {
    /// The sidebar's width. It is fixed: the sidebar cannot be dragged wider or collapsed.
    public static let sidebarWidth: CGFloat = 200
    /// The window's size when it first opens, and the smallest it can be. The smallest width
    /// leaves the Views section the 640 points its manage list needs beside the sidebar.
    public static let idealSize = CGSize(width: 880, height: 600)
    public static let minimumSize = CGSize(width: 850, height: 480)

    let store: PRStore
    let notifier: any Notifier
    let updater: any AppUpdating
    let build: BuildInfo
    let fixedTab: SettingsTab?
    @AppStorage(SettingsTab.storageKey) private var storedTab: SettingsTab = .account

    /// `tab` pins the section, for renders. `build` is this bundle's unless a render passes one.
    public init(
        store: PRStore, notifier: any Notifier, updater: any AppUpdating = NoUpdater(),
        build: BuildInfo = .current(), tab: SettingsTab? = nil
    ) {
        self.store = store
        self.notifier = notifier
        self.updater = updater
        self.build = build
        self.fixedTab = tab
    }

    private var selection: Binding<SettingsTab> {
        fixedTab.map { .constant($0) } ?? $storedTab
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsTab?>(
                get: { selection.wrappedValue },
                set: { if let tab = $0 { selection.wrappedValue = tab } }
            )) {
                ForEach(SettingsTab.allCases) { tab in
                    // The sidebar draws the selected row's title in a heavier weight, which
                    // widens it. A weight on the title's own Text keeps one weight throughout.
                    Label {
                        Text(tab.title).fontWeight(.regular)
                    } icon: {
                        Image(systemName: tab.symbol)
                    }
                    .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)
            Divider()
            // A minimum of zero keeps a section's ideal size from pushing the window or the
            // sidebar around.
            SettingsPane(store: store, notifier: notifier, updater: updater, build: build, tab: selection.wrappedValue)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(
            minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width,
            minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height
        )
        .centeredTitleBar(separator: .line)
    }
}

/// One section of Settings, on its own.
public struct SettingsPane: View {
    let store: PRStore
    let notifier: any Notifier
    let updater: any AppUpdating
    let build: BuildInfo
    let tab: SettingsTab

    public init(
        store: PRStore, notifier: any Notifier, updater: any AppUpdating = NoUpdater(),
        build: BuildInfo = .current(), tab: SettingsTab
    ) {
        self.store = store
        self.notifier = notifier
        self.updater = updater
        self.build = build
        self.tab = tab
    }

    public var body: some View {
        switch tab {
        case .account: AccountSettings(store: store)
        case .repos: RepoSettings(store: store)
        case .notifications: NotificationSettingsPane(store: store, notifier: notifier)
        case .views: ViewEditorView(store: store)
        case .advanced: AdvancedSettings(store: store, updater: updater, build: build)
        case .experiments: ExperimentsSettings()
        case .debugging: DebuggingSettings(store: store, build: build)
        }
    }
}

// MARK: - Account

struct AccountSettings: View {
    let store: PRStore
    @State private var switching = false
    @State private var token = ""

    var body: some View {
        Form {
            if let viewer = store.viewer, let method = store.authMethod {
                Section("GitHub") {
                    LabeledContent("Signed in as") {
                        Text(viewer.name.map { "\($0) (@\(viewer.login))" } ?? "@\(viewer.login)")
                    }
                    LabeledContent("Using") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Self.title(method))
                            Text(Self.explanation(method))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("Sign Out") { store.signOut() }
                        Button(switching ? "Cancel" : "Switch Sign-In Method…") { switching.toggle() }
                    }
                }
                if switching { signInSection(title: "Switch to") }
            } else if case .signingIn = store.auth {
                Section("GitHub") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking with GitHub…").foregroundStyle(.secondary)
                    }
                }
            } else if case .awaitingDeviceApproval(let code) = store.auth {
                Section("Sign in with GitHub") {
                    LabeledContent("Code") { Text(code.userCode).font(.title3.monospaced()).textSelection(.enabled) }
                    Text("Enter this code at \(code.verificationURL.absoluteString). This window updates when you approve.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open GitHub") { NSWorkspace.shared.open(code.verificationURL) }
                        Button("Cancel") { store.cancelDeviceFlow() }
                    }
                }
            } else {
                Section("GitHub") {
                    Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                    Text("Sign in to start watching. GitHub PR Watch only reads; it never merges, approves or comments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                signInSection(title: "Sign in")
            }
            if let error = store.authError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshCLIDetection() }
    }

    @ViewBuilder private func signInSection(title: String) -> some View {
        Section(title) {
            if store.isCLIInstalled {
                LabeledContent {
                    Button("Use GitHub CLI Login") { switchTo { await store.signInWithGitHubCLI() } }
                        .disabled(store.authMethod == .githubCLI)
                } label: {
                    Text("GitHub CLI")
                    Text(Self.explanation(.githubCLI))
                }
            }
            if store.isDeviceFlowAvailable {
                LabeledContent {
                    Button("Sign In with GitHub…") { switchTo { await store.beginDeviceFlow() } }
                } label: {
                    Text("Browser")
                    Text(Self.explanation(.deviceFlow))
                }
            }
            LabeledContent {
                HStack {
                    SecureField("Token", text: $token, prompt: Text("github_pat_…"))
                        .labelsHidden()
                        .frame(width: 180)
                    Button("Sign In") {
                        let pasted = token
                        token = ""
                        switchTo { await store.signIn(pastedToken: pasted) }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } label: {
                Text("Token")
                Text("A fine-grained token with read access to pull requests, checks and contents. " + Self.explanation(.pastedToken))
            }
        }
    }

    /// Signs out of the current method first, so switching never leaves two tokens around.
    private func switchTo(_ signIn: @escaping @MainActor () async -> Void) {
        Task {
            if store.viewer != nil { store.signOut() }
            await signIn()
            if store.viewer != nil {
                switching = false
                store.start()
            }
        }
    }

    static func title(_ method: AuthMethod) -> String {
        switch method {
        case .githubCLI: "GitHub CLI login"
        case .deviceFlow: "Sign in with GitHub"
        case .pastedToken: "Pasted token"
        }
    }

    static func explanation(_ method: AuthMethod) -> String {
        switch method {
        case .githubCLI: "Asks the gh tool for its token each time, so gh auth switch carries over. Nothing is stored here."
        case .deviceFlow: "Approve in the browser. The token is kept in your Keychain."
        case .pastedToken: "Kept in your Keychain."
        }
    }
}

// MARK: - Repos

struct RepoSettings: View {
    let store: PRStore
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                if store.watchedRepos.isEmpty {
                    Text("No repos yet. Add one below.").foregroundStyle(.secondary)
                }
                ForEach(store.watchedRepos, id: \.self) { name in
                    HStack {
                        Image(systemName: "book.closed").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(name)
                        if store.failedRepos.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                            Label("Can't read", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button {
                            update(store.watchedRepos.filter { $0 != name })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop watching \(name)")
                        .accessibilityLabel("Stop watching \(name)")
                    }
                }
            } header: {
                Text("Watched repos")
            } footer: {
                Text("Every open pull request in these repos is fetched, then sorted into your views.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Add repos") {
                TextField("Filter repos", text: $query, prompt: Text("Filter, or type owner/name"))
                    .labelsHidden()
                if store.viewer == nil {
                    Text("Sign in to see your repos.").foregroundStyle(.secondary)
                } else if store.isLoadingRepos && store.repoChoices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading repos…").foregroundStyle(.secondary)
                    }
                } else if let error = store.repoLoadError, store.repoChoices.isEmpty {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Try Again") { Task { await store.loadRepoChoices() } }
                    }
                } else {
                    if let typed = typedRepo {
                        addRow(name: typed, detail: "Not in your repo list", hasMergeQueue: false)
                    }
                    ForEach(matches.prefix(8)) { repo in
                        addRow(name: repo.nameWithOwner, detail: repo.isPrivate ? "Private" : nil, hasMergeQueue: repo.hasMergeQueue)
                    }
                    if matches.isEmpty && typedRepo == nil {
                        Text(query.isEmpty ? "You're watching every repo you have access to." : "No repos match “\(query)”.")
                            .foregroundStyle(.secondary)
                    } else if matches.count > 8 {
                        Text("\(matches.count - 8) more. Type to narrow the list.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: store.viewer?.login) {
            if store.viewer != nil, store.repoChoices.isEmpty { await store.loadRepoChoices() }
        }
    }

    private var watched: Set<String> { Set(store.watchedRepos.map { $0.lowercased() }) }

    private var matches: [Repo] {
        RepoPicker.filter(store.repoChoices, query: query).filter { !watched.contains($0.nameWithOwner.lowercased()) }
    }

    /// `owner/name` typed in full, for a repo the list doesn't have (such as another org's).
    private var typedRepo: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "/")
        guard parts.count == 2, !parts.contains(where: { $0.contains(" ") }),
              !watched.contains(text.lowercased()),
              !store.repoChoices.contains(where: { $0.nameWithOwner.caseInsensitiveCompare(text) == .orderedSame })
        else { return nil }
        return text
    }

    private func addRow(name: String, detail: String?, hasMergeQueue: Bool) -> some View {
        HStack {
            Text(name)
            if hasMergeQueue {
                Label("Merge queue", systemImage: "arrow.triangle.merge").font(.caption).foregroundStyle(.secondary)
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                update(store.watchedRepos + [name])
                query = ""
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Watch \(name)")
            .accessibilityLabel("Watch \(name)")
        }
    }

    private func update(_ repos: [String]) {
        store.setWatchedRepos(repos)
        store.refreshNow()
    }
}

// MARK: - Notifications

struct NotificationSettingsPane: View {
    let store: PRStore
    let notifier: any Notifier
    @State private var authorization: NotificationAuthorization?

    var body: some View {
        Form {
            Section("Permission") {
                permissionRow
            }
            Section {
                Toggle("Show a banner when a pull request changes", isOn: binding(\.bannersEnabled))
                Toggle("Play a sound", isOn: binding(\.playSound))
                    .disabled(!store.notificationSettings.bannersEnabled)
                Toggle("Keep quiet while GitHub PR Watch is in front", isOn: binding(\.quietWhileFrontmost))
                    .disabled(!store.notificationSettings.bannersEnabled)
            } header: {
                Text("Banners")
            } footer: {
                Text("Each view chooses which events notify, in Views. When many pull requests change at once you get up to \(NotificationPlanner.defaultMaxBanners) banners, the last one summing up the rest. A drop from the merge queue waits one poll, in case GitHub was mid-merge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle(isOn: binding(\.showMenuBarLabel)) {
                    Text("Show what changed next to the icon")
                    Text("For about \(Int(NotificationSettings.menuBarLabelDuration)) seconds, such as “#1293 ready to merge”.")
                }
            }
        }
        .formStyle(.grouped)
        .task { authorization = await notifier.authorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { authorization = await notifier.authorization() }
        }
    }

    @ViewBuilder private var permissionRow: some View {
        switch authorization {
        case .authorized:
            Label {
                Text("Allowed. Banner style and Focus are set in System Settings.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Button("Open System Settings…", action: UserNotifier.openSystemNotificationSettings)
        case .denied:
            Label("Notifications are turned off for GitHub PR Watch in System Settings.", systemImage: "bell.slash.fill")
                .foregroundStyle(.orange)
            Text("Banners can't show until you allow them there. The menu bar and the window keep working.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open System Settings…", action: UserNotifier.openSystemNotificationSettings)
        case .notDetermined:
            LabeledContent {
                Button("Turn On…") {
                    Task {
                        _ = await notifier.requestAuthorization()
                        authorization = await notifier.authorization()
                    }
                }
            } label: {
                Label("Not turned on yet", systemImage: "bell.badge")
                Text("macOS will ask once.")
            }
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.notificationSettings[keyPath: keyPath] },
            set: { value in
                var settings = store.notificationSettings
                settings[keyPath: keyPath] = value
                store.setNotificationSettings(settings)
            }
        )
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    let store: PRStore
    let updater: any AppUpdating
    let build: BuildInfo
    @State private var newPattern = ""

    static let intervals: [(TimeInterval, String)] = [
        (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Check GitHub every", selection: Binding(get: { store.pollInterval }, set: { store.setPollInterval($0) })) {
                    ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                    if !Self.intervals.contains(where: { $0.0 == store.pollInterval }) {
                        Text(Formatting.duration(store.pollInterval)).tag(store.pollInterval)
                    }
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("When less than a fifth of the hourly budget is left, polls spread out so it lasts until it resets. The last poll, the rate limit and Refresh Now are in Debugging.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(store.guardCheckPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern).monospaced()
                        Spacer()
                        Button {
                            store.setGuardCheckPatterns(store.guardCheckPatterns.filter { $0 != pattern })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(pattern)")
                        .accessibilityLabel("Remove \(pattern)")
                    }
                }
                HStack {
                    TextField("New guard check", text: $newPattern, prompt: Text("Add a check name, such as needs-rebase"))
                        .labelsHidden()
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Guard checks")
            } footer: {
                Text("A check whose name contains one of these is a guard: when it is the only failure, the pull request shows as “CI passed · blocked” instead of “CI failed”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            UpdatesSection(updater: updater, build: build)
        }
        .formStyle(.grouped)
    }

    private func addPattern() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        store.setGuardCheckPatterns(store.guardCheckPatterns + [pattern])
        newPattern = ""
    }
}
