import GitHubPRWatchCore
import SwiftUI

/// The main window (Figma row 1B, "Lanes by state"): the view picker, last update, Refresh,
/// New View and a filter field in the window's toolbar; banners for connection trouble under
/// it; then four lanes by state (Your move, CI running, In merge queue, Waiting on others),
/// each scrolling on its own.
///
/// The controls are real toolbar items, so the system draws them in Liquid Glass, and the
/// filter is the toolbar's own search field. The title bar above them says the app's name,
/// centered (see `centeredTitleBar`, applied by `MainWindowView`).
///
/// What fills and orders the lanes is `LaneBoard` in Core. Keyboard: arrows move the selection
/// across cards and lanes, Return opens it, ⌘R refreshes, ⌘F filters, Escape clears the filter
/// and Return in the filter goes back to the lanes.
public struct LanesWindowView: View {
    @Bindable var store: PRStore

    @State private var query = ""
    @State private var selectedPR: String?
    /// PRs opened this session. Opening a just-finished PR clears its highlight.
    @State private var opened: Set<String> = []
    @State private var showDrafts = false
    @State private var editor: EditorSheet?
    /// The window's width and the view tabs' natural width, to choose tabs or one menu.
    @State private var windowWidth: CGFloat = 0
    @State private var tabsWidth: CGFloat = 0
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case board, search }

    public init(store: PRStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            LanesBanners(store: store)
            TimelineView(.periodic(from: .now, by: 20)) { context in
                content(board(now: context.date))
            }
        }
        .frame(minWidth: 900, minHeight: 480)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar {
            LanesToolbar(
                store: store, editor: $editor,
                showsTabs: LanesToolbarLayout.showsTabs(tabsWidth: tabsWidth, windowWidth: windowWidth)
            )
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("Filter"))
        .searchFocused($focus, equals: .search)
        .onSubmit(of: .search) { focus = .board }
        .background { shortcutsAndMeasuring }
        .sheet(item: $editor) { sheet in
            ViewEditorSheet(store: store, sheet: sheet)
        }
        .onAppear { focus = .board }
    }

    /// ⌘F and ⌘R from anywhere in the window, and an invisible copy of the view tabs that
    /// reports how wide they want to be. A toolbar item is never offered less than its natural
    /// width, so the toolbar can't decide this itself.
    private var shortcutsAndMeasuring: some View {
        ZStack {
            Button("Filter") { focus = .search }
                .keyboardShortcut("f", modifiers: .command)
            Button("Refresh") { store.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isRefreshing || store.viewer == nil)
            ViewTabsWithMenu(store: store, editor: $editor)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

/// Which editor sheet is open.
enum EditorSheet: String, Identifiable {
    case new, edit
    var id: String { rawValue }
}

// MARK: - Toolbar

/// The window's toolbar: the view picker on the leading side; the last update, Refresh and
/// New View on the trailing side, before the search field that `.searchable` adds.
///
/// The system groups neighboring items into one glass shape. The last-updated text sits
/// outside any shape, Refresh has its own, and New View is set apart with a fixed spacer.
private struct LanesToolbar: ToolbarContent {
    @Bindable var store: PRStore
    @Binding var editor: EditorSheet?
    let showsTabs: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if showsTabs {
                ViewTabsWithMenu(store: store, editor: $editor)
            } else {
                ViewMenu(store: store, editor: $editor)
            }
        }
        ToolbarItem(placement: .primaryAction) { LastUpdatedText(store: store) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { RefreshButton(store: store) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { editor = .new } label: {
                Label("New View", systemImage: "plus")
            }
            .help("New View…")
        }
    }
}

/// The view tabs and the menu beside them with New View and Edit View.
private struct ViewTabsWithMenu: View {
    @Bindable var store: PRStore
    @Binding var editor: EditorSheet?

    var body: some View {
        HStack(spacing: 6) {
            ViewTabs(store: store)
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
    }
}

private struct RefreshButton: View {
    let store: PRStore

    var body: some View {
        // ⌘R is on a button in the window's content (see `LanesWindowView`), so it works
        // wherever focus is; this one shows the state.
        Button { store.refreshNow() } label: {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(store.isRefreshing ? 0 : 1)
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }
            .frame(width: 18, height: 18)
        }
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
///
/// The toolbar's glass shape is the track the tabs sit in, so they draw only the selected
/// tab's capsule.
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background {
                        if selected { selection }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(choice.name), \(count) your move")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private var selection: some View {
        Capsule(style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
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
            Text(LanesToolbarLayout.lastUpdatedText(isRefreshing: store.isRefreshing, lastUpdated: store.lastUpdated, now: context.date))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
        }
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

/// `ViewEditorView` in a sheet. New opens the template chooser. Edit opens the selected view,
/// or the manage list when the selection is not a saved view (the "All" tab).
private struct ViewEditorSheet: View {
    let store: PRStore
    let sheet: EditorSheet
    @Environment(\.dismiss) private var dismiss

    private var mode: ViewEditorView.Mode {
        switch sheet {
        case .new:
            return .create(nil)
        case .edit:
            if let id = store.selectedViewID, store.views.contains(where: { $0.id == id }) {
                return .edit(id)
            }
            return .manage
        }
    }

    var body: some View {
        ViewEditorView(store: store, mode: mode, onDone: { dismiss() })
            .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
    }
}
