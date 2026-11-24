import GitHubPRWatchCore
import SwiftUI

/// The main window (Figma row 1B, "Lanes by state"): a bar with the view picker, last update,
/// Refresh and a filter field; banners for connection trouble; then four lanes by state
/// (Your move, CI running, In merge queue, Waiting on others), each scrolling on its own.
///
/// What fills and orders the lanes is `LaneBoard` in Core. Keyboard: arrows move the selection
/// across cards and lanes, Return opens it, ⌘R refreshes, ⌘F filters, Escape clears the filter.
public struct LanesWindowView: View {
    @Bindable var store: PRStore

    @State private var query = ""
    @State private var selectedPR: String?
    /// PRs opened this session. Opening a just-finished PR clears its highlight.
    @State private var opened: Set<String> = []
    @State private var showDrafts = false
    @State private var editor: EditorSheet?
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case board, search }

    public init(store: PRStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            LanesBar(store: store, query: $query, focus: $focus, editor: $editor)
            Divider()
            LanesBanners(store: store)
            TimelineView(.periodic(from: .now, by: 20)) { context in
                content(board(now: context.date))
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .sheet(item: $editor) { _ in
            ViewEditorSheet(store: store)
        }
        .onAppear { focus = .board }
    }

    // MARK: Board

    struct Board {
        var lanes: [PRStore.LaneGroup]
        var justFinished: [String: Date]
        var movedNotes: [LaneBoard.MovedNote]
        /// PRs in the view before the filter field.
        var unfilteredCount: Int

        var isEmpty: Bool { lanes.allSatisfy(\.pullRequests.isEmpty) }
    }

    private func board(now: Date) -> Board {
        let all = store.boardPullRequests(for: store.selectedViewID)
        let justFinished = LaneBoard.justFinished(events: store.recentEvents, current: all, now: now)
            .filter { !opened.contains($0.key) }
        let shown = all.filter { LaneBoard.matches($0, query: query) }
        return Board(
            lanes: LaneBoard.lanes(shown, justFinished: justFinished, now: now),
            justFinished: justFinished,
            movedNotes: LaneBoard.movedNotes(justFinished: justFinished, board: shown, now: now),
            unfilteredCount: all.count
        )
    }

    /// Card IDs per lane, as the keyboard sees them: collapsed drafts are skipped.
    private func columns(_ board: Board) -> [[String]] {
        board.lanes.map { group in
            group.pullRequests.filter { showDrafts || group.lane != .waiting || !$0.pr.isDraft }.map(\.id)
        }
    }

    // MARK: Content and states

    @ViewBuilder private func content(_ board: Board) -> some View {
        if store.viewer == nil, store.auth == .signedOut {
            Placeholder(symbol: "person.crop.circle.badge.questionmark", title: "Signed out", message: "Sign in to see your pull requests.")
        } else if store.views.isEmpty {
            Placeholder(symbol: "line.3.horizontal.decrease.circle", title: "No views yet", message: "A view is a saved filter that fills the lanes.") {
                Button("New View…") { editor = .new }
            }
        } else if store.lastUpdated == nil {
            if let message = store.connection.message, !store.isRefreshing {
                Placeholder(symbol: "icloud.slash", title: "Couldn't load pull requests yet", message: message) {
                    if case .rateLimited = store.connection {} else {
                        Button("Try Again") { store.refreshNow() }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Loading pull requests…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if board.unfilteredCount == 0 {
            Placeholder(symbol: "tray", title: "No pull requests match this view", message: "Open PRs in your watched repos that match \(viewName) will show up here.") {
                if store.selectedViewID != PRStore.allViewsID {
                    Button("Edit View…") { editor = .edit }
                }
            }
        } else if board.isEmpty {
            Placeholder(symbol: "magnifyingglass", title: "No pull requests match “\(query)”", message: "Filters by title, number, author or repo.") {
                Button("Clear Filter") { query = ""; focus = .board }
            }
        } else {
            lanes(board)
        }
    }

    private var viewName: String {
        store.selectedViewID == PRStore.allViewsID ? "any view" : "“\(store.selectedView?.name ?? "this view")”"
    }

    private func lanes(_ board: Board) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(board.lanes) { group in
                LaneColumnView(
                    group: group,
                    viewer: store.viewer?.login,
                    selectedID: focus == .board ? selectedPR : nil,
                    justFinished: board.justFinished,
                    movedNotes: group.lane == .ciRunning ? board.movedNotes : [],
                    showDrafts: $showDrafts,
                    onOpen: { item in
                        opened.insert(item.id)
                        selectedPR = item.id
                        focus = .board
                    }
                )
            }
        }
        .padding(10)
        .focusable()
        .focused($focus, equals: .board)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
            let current = self.board(now: .now)
            switch press.key {
            case .return:
                guard let id = selectedPR, let item = current.lanes.lazy.flatMap(\.pullRequests).first(where: { $0.id == id }) else { return .ignored }
                opened.insert(id)
                openURL(item.pr.url)
            case .upArrow: selectedPR = LaneBoard.move(selectedPR, .up, columns: columns(current))
            case .downArrow: selectedPR = LaneBoard.move(selectedPR, .down, columns: columns(current))
            case .leftArrow: selectedPR = LaneBoard.move(selectedPR, .left, columns: columns(current))
            case .rightArrow: selectedPR = LaneBoard.move(selectedPR, .right, columns: columns(current))
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: store.selectedViewID) { selectedPR = nil }
    }

    @Environment(\.openURL) private var openURL
}

/// Which editor sheet is open. Both use `ViewEditorView`'s existing initializer.
enum EditorSheet: String, Identifiable {
    case new, edit
    var id: String { rawValue }
}

// MARK: - Bar

/// The bar under the title bar: view picker, last update, Refresh, the filter field and New View.
private struct LanesBar: View {
    @Bindable var store: PRStore
    @Binding var query: String
    var focus: FocusState<LanesWindowView.Focus?>.Binding
    @Binding var editor: EditorSheet?

    var body: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ViewTabs(store: store)
                    moreMenu
                }
                ViewMenu(store: store, editor: $editor)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            LastUpdatedText(store: store)
            refreshButton
            FilterField(query: $query, focus: focus)
            Button { editor = .new } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New View…")
            .accessibilityLabel("New View")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // ⌘F focuses the filter field from anywhere in the window.
            Button("Filter") { focus.wrappedValue = .search }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("New View…") { editor = .new }
            Button("Edit View…") { editor = .edit }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Views")
        .accessibilityLabel("View options")
    }

    private var refreshButton: some View {
        Button { store.refreshNow() } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(store.isRefreshing ? 0 : 1)
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(store.isRefreshing || store.viewer == nil)
        .help("Refresh (⌘R)")
        .accessibilityLabel(store.isRefreshing ? "Refreshing" : "Refresh")
    }
}

/// One choice in the view picker: a saved view or "All".
private struct ViewChoice: Identifiable {
    var id: UUID
    var name: String
    var symbol: String
}

private extension PRStore {
    var viewChoices: [ViewChoice] {
        views.map { ViewChoice(id: $0.id, name: $0.name, symbol: $0.symbol) }
            + (views.count > 1 ? [ViewChoice(id: PRStore.allViewsID, name: "All", symbol: "square.stack")] : [])
    }

    var isSelected: (UUID) -> Bool {
        let current = views.contains { $0.id == selectedViewID } || selectedViewID == PRStore.allViewsID ? selectedViewID : views.first?.id
        return { $0 == current }
    }
}

/// The view picker as tabs, like the design: each view's name and its your-move count.
private struct ViewTabs: View {
    @Bindable var store: PRStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isSelected = store.isSelected
        HStack(spacing: 2) {
            ForEach(store.viewChoices) { choice in
                let selected = isSelected(choice.id)
                let count = store.yourMoveCount(for: choice.id)
                Button { store.selectedViewID = choice.id } label: {
                    HStack(spacing: 5) {
                        Text(choice.name).lineLimit(1)
                        if count > 0 { CountBadge(count: count, prominent: selected) }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(choice.name), \(count) your move")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

/// The view picker as one menu, for windows too narrow for the tabs.
private struct ViewMenu: View {
    @Bindable var store: PRStore
    @Binding var editor: EditorSheet?

    var body: some View {
        let isSelected = store.isSelected
        let current = store.viewChoices.first { isSelected($0.id) }
        Menu {
            ForEach(store.viewChoices) { choice in
                Toggle(isOn: Binding(get: { isSelected(choice.id) }, set: { if $0 { store.selectedViewID = choice.id } })) {
                    Label("\(choice.name) · \(store.yourMoveCount(for: choice.id)) your move", systemImage: choice.symbol)
                }
            }
            Divider()
            Button("New View…") { editor = .new }
            Button("Edit View…") { editor = .edit }
        } label: {
            HStack(spacing: 5) {
                Text(current?.name ?? "Views")
                if let current { CountBadge(count: store.yourMoveCount(for: current.id), prominent: true) }
            }
        }
        .fixedSize()
        .accessibilityLabel("View: \(current?.name ?? "none")")
    }
}

private struct CountBadge: View {
    let count: Int
    let prominent: Bool

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(prominent ? Color.white : Color.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.primary.opacity(0.1)))
            .accessibilityHidden(true)
    }
}

private struct LastUpdatedText: View {
    let store: PRStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if store.isRefreshing {
                    Text("Updating…")
                } else if let updated = store.lastUpdated {
                    let ago = Formatting.ago(updated, now: context.date)
                    Text(ago == "now" ? "Updated just now" : "Updated \(ago)")
                } else {
                    Text("Not updated yet")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }
}

private struct FilterField: View {
    @Binding var query: String
    var focus: FocusState<LanesWindowView.Focus?>.Binding

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .focused(focus, equals: .search)
                .onExitCommand { query = ""; focus.wrappedValue = .board }
                .onKeyPress(.downArrow) { focus.wrappedValue = .board; return .handled }
                .accessibilityLabel("Filter pull requests")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(width: 180)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .help("Filter by title, number, author or repo (⌘F)")
    }
}

// MARK: - Banners

/// Connection trouble and repos that couldn't be read, above the lanes. Each banner says what
/// happened in words and with a symbol; the tint only backs that up.
private struct LanesBanners: View {
    let store: PRStore

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.connection.message {
                banner(symbol: symbol, text: message + staleNote, tint: tint) { action }
            }
            if !store.failedRepos.isEmpty {
                let repos = Formatting.names(store.failedRepos, limit: 3)
                banner(
                    symbol: "exclamationmark.triangle.fill",
                    text: "Can't read \(repos). Its pull requests are as of the last update that worked.",
                    tint: .orange
                ) { EmptyView() }
            }
        }
    }

    private var staleNote: String {
        guard let updated = store.lastUpdated else { return "" }
        let ago = Formatting.ago(updated, now: .now)
        return " Last updated \(ago == "now" ? "just now" : ago)."
    }

    private var symbol: String {
        switch store.connection {
        case .offline: "wifi.slash"
        case .rateLimited, .secondaryRateLimited: "hourglass"
        case .tokenRejected: "person.crop.circle.badge.exclamationmark"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch store.connection {
        case .rateLimited, .secondaryRateLimited: .secondary
        case .tokenRejected, .failed: .red
        default: .orange
        }
    }

    @ViewBuilder private var action: some View {
        switch store.connection {
        case .rateLimited:
            EmptyView()
        case .tokenRejected where store.authMethod == .githubCLI:
            Button("Use GitHub CLI Login Again") {
                Task {
                    await store.signInWithGitHubCLI()
                    store.refreshNow()
                }
            }
        case .tokenRejected:
            SettingsLink { Text("Open Settings…") }
        default:
            Button("Try Again") { store.refreshNow() }.disabled(store.isRefreshing)
        }
    }

    private func banner<Action: View>(symbol: String, text: String, tint: Color, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action().controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Placeholders and the editor sheet

private struct Placeholder<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `ViewEditorView` in a sheet, with a Done button.
private struct ViewEditorSheet: View {
    let store: PRStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ViewEditorView(store: store)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
    }
}
