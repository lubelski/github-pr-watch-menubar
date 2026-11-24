import AppKit
import GitHubPRWatchCore
import SwiftUI

/// Setup on one screen (Figma row 6B). Left: sign in, starter views, notifications.
/// Right: the repo picker, which unlocks in place once signed in. Notification permission
/// is asked only from the explicit "Turn On…" button.
public struct OnboardingView: View {
    let store: PRStore
    let notifier: any Notifier

    @State private var selectedRepos: Set<String> = []
    @State private var didPreselect = false
    @State private var repoQuery = ""
    @State private var starterViews: Set<UUID> = [BuiltInViews.mineID, BuiltInViews.needsMyReviewID]
    @State private var showTokenField = false
    @State private var pastedToken = ""
    @State private var notifications: NotificationAuthorization = .notDetermined

    public init(store: PRStore, notifier: any Notifier) {
        self.store = store
        self.notifier = notifier
    }

    private var isSignedIn: Bool { store.viewer != nil }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: 330)
                    .background(.background.secondary)
                Divider()
                repoColumn
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 540)
        .task(id: isSignedIn) {
            notifications = await notifier.authorization()
            if isSignedIn, store.repoChoices.isEmpty { await store.loadRepoChoices() }
        }
        .onChange(of: store.repoChoices) { preselectIfNeeded() }
        .onAppear { store.refreshCLIDetection(); preselectIfNeeded() }
        .sheet(isPresented: deviceSheetBinding) { DeviceCodeSheet(store: store) }
    }

    // MARK: Left column

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    AppIconView(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up GitHub PR Watch").font(.headline)
                        Text("Read-only. Never merges or re-runs.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                step(1, "Sign in", done: isSignedIn) { signInSection }
                step(2, "Starter views", done: false) { starterViewsSection }
                    .disabled(!isSignedIn)
                    .opacity(isSignedIn ? 1 : 0.5)
                step(3, "Notifications", done: notifications == .authorized) { notificationSection }
                    .disabled(!isSignedIn)
                    .opacity(isSignedIn ? 1 : 0.5)
            }
            .padding(20)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle.fill")
                    .foregroundStyle(done ? Color.green : Color.primary)
                Text(title).font(.subheadline.weight(.semibold))
            }
            content()
        }
    }

    @ViewBuilder private var signInSection: some View {
        if let viewer = store.viewer {
            HStack(spacing: 10) {
                Avatar(login: viewer.login)
                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(viewer.login) on github.com").font(.callout.weight(.medium))
                    Text(methodDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Switch…") { store.signOut() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                signInOption(
                    icon: "terminal", title: "Use your GitHub CLI login",
                    subtitle: store.isCLIInstalled ? "Uses `gh`'s login. One click." : "Install the GitHub CLI (`gh`) to use this.",
                    badge: store.isCLIInstalled ? "Detected" : nil,
                    primary: store.isCLIInstalled
                ) {
                    Task { await store.signInWithGitHubCLI() }
                }
                .disabled(!store.isCLIInstalled || isBusy)

                if store.isDeviceFlowAvailable {
                    signInOption(
                        icon: "globe", title: "Sign in with GitHub",
                        subtitle: "Browser plus a short code.", badge: nil, primary: !store.isCLIInstalled
                    ) {
                        Task { await store.beginDeviceFlow() }
                    }
                    .disabled(isBusy)
                }

                if showTokenField {
                    HStack {
                        SecureField("Personal access token", text: $pastedToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submitToken)
                        Button("Sign In", action: submitToken)
                            .disabled(pastedToken.isEmpty || isBusy)
                    }
                    Text("Needs read access to pull requests, checks and commit statuses.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button {
                        showTokenField = true
                    } label: {
                        Label("Paste a token instead…", systemImage: "key")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if isBusy {
                    ProgressView().controlSize(.small)
                }
                if let error = store.authError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func signInOption(icon: String, title: String, subtitle: LocalizedStringKey, badge: String?, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(primary ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Color.accentColor : Color.secondary.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.callout.weight(.medium))
                        if let badge {
                            Label(badge, systemImage: "checkmark")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: primary ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private var starterViewsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(BuiltInViews.all) { view in
                Toggle(isOn: starterBinding(view.id)) {
                    HStack(spacing: 6) {
                        Image(systemName: view.symbol).frame(width: 16).foregroundStyle(.secondary)
                        Text(view.name)
                        if view.pinnedToMenubar {
                            Text("pinned to menubar").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            Text("Agent PRs and Watchlist need logins, which you add in Settings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var notificationSection: some View {
        HStack(alignment: .top) {
            Image(systemName: "bell").foregroundStyle(.secondary)
            Text("Banners when CI finishes or a review comes in.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            switch notifications {
            case .authorized:
                Label("On", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            case .denied:
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            case .notDetermined:
                Button("Turn On…") {
                    Task {
                        _ = await notifier.requestAuthorization()
                        notifications = await notifier.authorization()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Repo column

    private var repoColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "4.circle.fill")
                Text("Repos to watch").font(.subheadline.weight(.semibold))
                Spacer()
                if !selectedRepos.isEmpty {
                    Text("\(selectedRepos.count) selected").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Filter repos", text: $repoQuery)
                .textFieldStyle(.roundedBorder)
                .disabled(!isSignedIn)
            Group {
                if !isSignedIn {
                    ContentUnavailableView {
                        Label("Sign in to see your repos", systemImage: "lock")
                    } description: {
                        Text(store.isCLIInstalled ? "With the GitHub CLI login this takes one click." : "Sign in on the left first.")
                    }
                } else if store.isLoadingRepos && store.repoChoices.isEmpty {
                    ProgressView("Loading repos…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.repoLoadError, store.repoChoices.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load repos", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await store.loadRepoChoices() } }
                    }
                } else {
                    repoList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .padding(20)
    }

    private var repoList: some View {
        let filtered = RepoPicker.filter(store.repoChoices, query: repoQuery)
        return List {
            ForEach(RepoPicker.grouped(filtered, viewer: store.viewer?.login), id: \.owner) { group in
                Section(group.owner.uppercased()) {
                    ForEach(group.repos) { repo in
                        Toggle(isOn: repoBinding(repo.nameWithOwner)) {
                            HStack(spacing: 6) {
                                Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                                    .foregroundStyle(.secondary).frame(width: 14)
                                Text(repo.nameWithOwner)
                                if repo.hasMergeQueue {
                                    Text("Merge queue")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.purple)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("You can change all of this later in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
            Button("Start Watching") {
                let views = BuiltInViews.all.filter { starterViews.contains($0.id) }
                store.completeOnboarding(repos: orderedSelection, views: views)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isSignedIn || selectedRepos.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Helpers

    private var isBusy: Bool {
        if case .signingIn = store.auth { true } else { false }
    }

    private var methodDescription: String {
        switch store.authMethod {
        case .githubCLI: "via GitHub CLI login"
        case .deviceFlow: "via Sign in with GitHub"
        case .pastedToken: "via a pasted token"
        case nil: ""
        }
    }

    /// The selection in the picker's order, so watched repos stay sorted by recent push.
    private var orderedSelection: [String] {
        store.repoChoices.map(\.nameWithOwner).filter(selectedRepos.contains)
            + selectedRepos.filter { name in !store.repoChoices.contains { $0.nameWithOwner == name } }.sorted()
    }

    private func preselectIfNeeded() {
        guard !didPreselect, !store.repoChoices.isEmpty else { return }
        didPreselect = true
        selectedRepos = Set(store.watchedRepos.isEmpty ? store.suggestedRepos : store.watchedRepos)
    }

    private func submitToken() {
        let token = pastedToken
        pastedToken = ""
        Task { await store.signIn(pastedToken: token) }
    }

    private func starterBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { starterViews.contains(id) },
            set: { if $0 { starterViews.insert(id) } else { starterViews.remove(id) } }
        )
    }

    private func repoBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { selectedRepos.contains(name) },
            set: { if $0 { selectedRepos.insert(name) } else { selectedRepos.remove(name) } }
        )
    }

    private var deviceSheetBinding: Binding<Bool> {
        Binding(
            get: { if case .awaitingDeviceApproval = store.auth { true } else { false } },
            set: { if !$0 { store.cancelDeviceFlow() } }
        )
    }
}

/// The device-flow code, with a button that copies it and opens github.com.
struct DeviceCodeSheet: View {
    let store: PRStore

    var body: some View {
        VStack(spacing: 14) {
            if case .awaitingDeviceApproval(let code) = store.auth {
                Text("Enter this code on GitHub").font(.headline)
                Text(code.userCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy Code and Open GitHub") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    NSWorkspace.shared.open(code.verificationURL)
                }
                .keyboardShortcut(.defaultAction)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { store.cancelDeviceFlow() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}
