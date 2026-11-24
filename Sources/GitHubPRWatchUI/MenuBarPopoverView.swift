import AppKit
import GitHubPRWatchCore
import SwiftUI

/// The menubar popover (Figma row 3B): "Recent changes" on top, the PRs with an event since
/// you last looked (`ChangeBadge`), newest first; then every PR grouped under the five lane
/// names, each group collapsible, Failing and Ready to merge expanded to start. Draws from
/// the views pinned to the menubar (`PRStore.menuBarPullRequests`), so a PR in two pinned
/// views shows once per group. Opening the popover clears the menu bar badge. Clicking a row
/// opens the PR and closes the popover.
public struct MenuBarPopoverView: View {
    let store: PRStore
    let activity: MenuBarActivity?
    @State private var expanded: Set<Lane>
    @State private var listHeight: CGFloat = 0
    @State private var window: NSWindow?
    @AppStorage(SettingsTab.storageKey) private var settingsTab: SettingsTab = .account
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    public static let width: CGFloat = 360
    public static let maxListHeight: CGFloat = 440

    /// `expanded` chooses which lane groups start open, for renders.
    public init(store: PRStore, activity: MenuBarActivity? = nil, expanded: Set<Lane> = MenuBarSummary.expandedByDefault) {
        self.store = store
        self.activity = activity
        self._expanded = State(initialValue: expanded)
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: Self.width)
        .background(WindowReader(window: $window))
        .onAppear {
            activity?.markSeen()
            refreshIfStale()
        }
    }

    // MARK: States

    private enum Phase {
        case signedOut, signingIn, tokenRejected, loading, failedWithoutData(String), list
    }

    private var phase: Phase {
        switch store.auth {
        case .signedOut, .awaitingDeviceApproval: return .signedOut
        case .signingIn: return store.needsOnboarding ? .signedOut : .signingIn
        case .signedIn: break
        }
        if store.needsOnboarding { return .signedOut }
        if store.connection == .tokenRejected { return .tokenRejected }
        if store.lastUpdated == nil {
            if let message = store.connection.message { return .failedWithoutData(message) }
            return .loading
        }
        return .list
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .signedOut:
            header(title: AppInfo.name)
            MessageState(
                symbol: "person.crop.circle.badge.questionmark", tint: .secondary,
                title: store.needsOnboarding ? "Finish setting up" : "Not signed in",
                message: "Sign in to GitHub and pick the repos to watch. Nothing is sent to GitHub; this app only reads.",
                action: ("Open GitHub PR Watch…", openSetup)
            )
        case .signingIn:
            header(title: AppInfo.name)
            ProgressState(text: "Checking your sign-in with GitHub…")
        case .tokenRejected:
            header(title: AppInfo.name)
            MessageState(
                symbol: "person.crop.circle.badge.exclamationmark", tint: .orange,
                title: "GitHub rejected the sign-in",
                message: store.authMethod == .githubCLI
                    ? "Run `gh auth login` in Terminal, or sign in another way."
                    : "The token may have expired or been revoked. Sign in again to keep watching.",
                action: ("Sign In Again…", { openSettingsTab(.account) })
            )
        case .loading:
            header(title: AppInfo.name)
            ProgressState(text: "Loading pull requests…")
        case .failedWithoutData(let message):
            header(title: AppInfo.name)
            MessageState(
                symbol: "wifi.exclamationmark", tint: .orange, title: "Can't load pull requests",
                message: message, action: ("Try Again", { store.refreshNow() })
            )
        case .list:
            list
        }
    }

    // MARK: List

    private var list: some View {
        let prs = store.menuBarPullRequests
        let recent = activity?.changes.recentChanges(in: prs) ?? []
        let groups = MenuBarSummary.groups(prs)
        let justChanged = MenuBarSummary.justChanged(store.recentEvents, now: .now)

        return VStack(spacing: 0) {
            listHeader(count: prs.count)
            if let message = store.connection.message {
                StaleBanner(message: message) { store.refreshNow() }
            }
            ScrollView {
                VStack(spacing: 0) {
                    if prs.isEmpty {
                        EmptyListState(sentence: MenuBarSummary.emptySentence(bannersOn: store.notificationSettings.bannersEnabled))
                    } else {
                        if !recent.isEmpty {
                            recentSection(recent, justChanged: justChanged)
                            Divider()
                        }
                        ForEach(groups) { group in
                            laneSection(group, justChanged: justChanged)
                        }
                    }
                }
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 1), Self.maxListHeight))
        }
    }

    private func listHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Pull requests").font(.system(size: 13, weight: .semibold))
            Text("\(count)").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text(viewsCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("The popover shows the views pinned to the menu bar. Pin views in Settings › Views.")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var viewsCaption: String {
        let views = store.menuBarViews
        let pinned = store.views.contains(where: \.pinnedToMenubar)
        if views.count <= 2 { return views.map(\.name).joined(separator: " + ") }
        return pinned ? "\(views.count) pinned views" : "All views"
    }

    private func recentSection(_ recent: [ClassifiedPR], justChanged: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text("Recent changes").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(recent) { item in
                    PopoverPRRow(item: item, isNew: justChanged.contains(item.id), open: openPR)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }

    private func laneSection(_ group: PRStore.LaneGroup, justChanged: Set<String>) -> some View {
        let isExpanded = expanded.contains(group.lane)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isExpanded { expanded.remove(group.lane) } else { expanded.insert(group.lane) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(group.lane.title).font(.system(size: 12, weight: .semibold))
                    Text("\(group.pullRequests.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.lane.title), \(group.pullRequests.count)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the list" : "Expands the list")

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.pullRequests) { item in
                        PopoverPRRow(item: item, isNew: justChanged.contains(item.id), open: openPR)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    private func header(title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            // Problems show above the list; the footer only says how fresh it is.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Group {
                    if store.isRefreshing {
                        Text("Updating…")
                    } else if let updated = store.lastUpdated {
                        Text("Updated \(Formatting.ago(updated, now: context.date))")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            iconButton("arrow.clockwise", help: "Refresh now") { store.refreshNow() }
                .disabled(store.isRefreshing || store.viewer == nil || store.needsOnboarding)
            Button("Open Window", action: openMainWindow)
            iconButton("gearshape", help: "Settings…") { openSettingsTab(nil) }
            iconButton("power", help: "Quit GitHub PR Watch") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Actions

    private func openPR(_ url: URL) {
        openURL(url)
        closePopover()
    }

    private func openMainWindow() {
        closePopover()
        openWindow(id: AppInfo.mainWindowID)
        NSApp.activate()
    }

    /// The main window shows onboarding while signed out, including after a sign-out.
    private func openSetup() {
        openMainWindow()
    }

    private func openSettingsTab(_ tab: SettingsTab?) {
        if let tab { settingsTab = tab }
        closePopover()
        openSettings()
        NSApp.activate()
    }

    private func closePopover() {
        window?.close()
    }

    /// Opening the popover refreshes when the last poll is more than a minute old.
    private func refreshIfStale() {
        guard let updated = store.lastUpdated, Date.now.timeIntervalSince(updated) > 60 else { return }
        store.refreshNow()
    }
}

// MARK: - Pieces

private struct MessageState: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(.init(message))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

private struct ProgressState: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct EmptyListState: View {
    let sentence: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No open pull requests").font(.system(size: 13, weight: .semibold))
            Text(sentence)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

/// Shown above the list when the last poll failed but older results are still on screen.
private struct StaleBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Try Again", action: retry).controlSize(.mini)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// Hands back the hosting window, so the popover can close itself after a click.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}
