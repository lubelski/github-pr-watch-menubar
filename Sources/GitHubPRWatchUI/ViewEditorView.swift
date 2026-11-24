import GitHubPRWatchCore
import SwiftUI

/// The view editor sheet (Figma row 4B, "Rule builder", modeled on Mail rules and Finder
/// smart folders). Shown over the main window.
///
/// - `.manage` (the default): a list of views to reorder, duplicate, delete, edit or add.
/// - `.edit(id)`: straight to one view's editor.
/// - `.create(template)`: a new view, from the template chooser when `template` is `nil`.
///
/// Saving goes through `PRStore.saveView(_:)`. Nothing here talks to GitHub.
public struct ViewEditorView: View {
    public enum Mode: Equatable, Sendable {
        case manage
        case edit(UUID)
        case create(ViewTemplate?)
    }

    enum Screen: Equatable {
        case list
        case templates
        case editor(ViewDraft, isNew: Bool, focusLogins: Bool)
    }

    let store: PRStore
    let mode: Mode
    let onDone: (() -> Void)?
    @State private var screen: Screen
    @Environment(\.dismiss) private var dismiss

    public init(store: PRStore, mode: Mode = .manage, onDone: (() -> Void)? = nil) {
        self.store = store
        self.mode = mode
        self.onDone = onDone
        _screen = State(initialValue: Self.firstScreen(store: store, mode: mode))
    }

    public var body: some View {
        Group {
            switch screen {
            case .list:
                ManageViewsList(store: store, onEdit: edit, onNew: { screen = .templates }, onDone: finish)
            case .templates:
                TemplateChooser(onPick: create, onCancel: back)
            case .editor(let draft, let isNew, let focusLogins):
                ViewEditorForm(
                    store: store, draft: draft, isNew: isNew, focusLogins: focusLogins,
                    onFinish: { saved in
                        if let saved, isNew { store.selectedViewID = saved.id }
                        back()
                    }
                )
                .id(draft.id)
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 440, idealHeight: 720)
    }

    private static func firstScreen(store: PRStore, mode: Mode) -> Screen {
        switch mode {
        case .manage: return .list
        case .edit(let id):
            guard let view = store.views.first(where: { $0.id == id }) else { return .list }
            return .editor(ViewDraft(view), isNew: false, focusLogins: false)
        case .create(nil): return .templates
        case .create(let template?):
            return .editor(template.draft(existingNames: store.views.map(\.name)), isNew: true, focusLogins: template.needsLogins)
        }
    }

    private func edit(_ id: UUID) {
        guard let view = store.views.first(where: { $0.id == id }) else { return }
        screen = .editor(ViewDraft(view), isNew: false, focusLogins: false)
    }

    private func create(_ template: ViewTemplate) {
        screen = .editor(template.draft(existingNames: store.views.map(\.name)), isNew: true, focusLogins: template.needsLogins)
    }

    /// Back to the list when the sheet opened on it; otherwise the sheet is done.
    private func back() {
        if mode == .manage { screen = .list } else { finish() }
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }
}

// MARK: - Editor form

/// One view's editor: name and symbol, rules, live preview, notifications, pin, and
/// Save / Cancel / Delete. Public so the render tool can draw it in a given state.
public struct ViewEditorForm: View {
    let store: PRStore
    let isNew: Bool
    let focusLogins: Bool
    /// Called with the saved view, or `nil` after Cancel or Delete.
    let onFinish: (SavedView?) -> Void

    private let original: ViewDraft
    @State private var draft: ViewDraft
    @State private var revealIssues: Bool
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @FocusState private var focusedRow: UUID?
    @FocusState private var nameFocused: Bool

    public init(
        store: PRStore, draft: ViewDraft, isNew: Bool, focusLogins: Bool = false, revealIssues: Bool = false,
        onFinish: @escaping (SavedView?) -> Void = { _ in }
    ) {
        self.store = store
        self.isNew = isNew
        self.focusLogins = focusLogins
        self.onFinish = onFinish
        self.original = draft
        _draft = State(initialValue: draft)
        _revealIssues = State(initialValue: revealIssues)
    }

    /// Unsaved edits. A new view nobody touched can be cancelled without asking.
    private var isDirty: Bool { draft != original }
    private var issues: [ViewDraftIssue] { draft.issues }
    private var flagged: Set<UUID> { revealIssues ? Set(issues.compactMap(\.rowID)) : [] }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 18) {
                    GridRow {
                        label("Name")
                        nameRow
                    }
                    GridRow {
                        label("Filter")
                        VStack(alignment: .leading, spacing: 8) {
                            RuleListEditor(draft: $draft, store: store, focus: $focusedRow, flagged: flagged)
                            if revealIssues, !issues.isEmpty { issueList }
                        }
                    }
                    GridRow {
                        label("Preview")
                        PreviewSection(store: store, draft: draft)
                    }
                    GridRow {
                        label("Notify me")
                        NotifySection(notify: $draft.notify)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isDirty)
        .onAppear {
            if focusLogins, let id = draft.firstEmptyPeopleRowID {
                focusedRow = id
            } else if isNew, draft.name.isEmpty {
                nameFocused = true
            }
        }
        .confirmationDialog("Delete “\(original.name)”?", isPresented: $confirmDelete) {
            Button("Delete View", role: .destructive) {
                store.deleteView(id: original.id)
                onFinish(nil)
            }
        } message: {
            Text("Its rules and notification settings go too. PRs aren't affected.")
        }
        .confirmationDialog(isNew ? "Discard this new view?" : "Discard changes to “\(original.name)”?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { onFinish(nil) }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text(isNew ? "New View" : "Edit View")
                .font(.headline)
            Spacer()
            Toggle("Pin to menu bar", isOn: $draft.pinnedToMenubar)
                .toggleStyle(.checkbox)
                .help("Show this view's PRs in the menu bar popover and count them in the badge.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var nameRow: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $draft.name, prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .frame(maxWidth: 260)
                .flagged(revealIssues && issues.contains { $0.kind == .nameMissing })
                .accessibilityLabel("Name")
            SymbolPicker(symbol: $draft.symbol)
        }
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Delete View…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Cancel") {
                if isDirty { confirmDiscard = true } else { onFinish(nil) }
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .trailing)
            .padding(.top, 4)
            .gridColumnAlignment(.trailing)
    }

    private func save() {
        guard let view = draft.savedView else {
            revealIssues = true
            if issues.first?.kind == .nameMissing {
                nameFocused = true
            } else if let id = issues.first(where: { $0.rowID != nil })?.rowID {
                focusedRow = id
            }
            return
        }
        store.saveView(view)
        onFinish(view)
    }
}

/// The view's SF Symbol, chosen from a short list.
struct SymbolPicker: View {
    @Binding var symbol: String

    var body: some View {
        Menu {
            Picker("Symbol", selection: $symbol) {
                ForEach(ViewSymbols.all, id: \.self) { name in
                    Label(name, systemImage: name).labelStyle(.iconOnly).tag(name)
                }
            }
            .pickerStyle(.palette)
        } label: {
            Image(systemName: symbol)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Symbol")
        .accessibilityLabel("Symbol")
    }
}

// MARK: - Preview

/// "Matches 5 open PRs right now", and the first few.
struct PreviewSection: View {
    let store: PRStore
    let draft: ViewDraft
    static let limit = 5

    var body: some View {
        let preview = store.preview(draft.rule)
        let unfinished = draft.issues.filter { $0.kind == .emptyValue || $0.kind == .emptyGroup }.count
        let notes = notes(preview, unfinished: unfinished)
        VStack(alignment: .leading, spacing: 6) {
            Text(headline(preview.matches.count))
                .font(.callout.weight(.semibold))
                .padding(.top, 4)
            if !preview.matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.matches.prefix(Self.limit)) { item in
                        PRRowView(item, style: .compact)
                    }
                }
                .padding(.horizontal, -6)
            }
            if !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(_ count: Int) -> String {
        if store.viewer == nil { return "Sign in to see which PRs match" }
        switch count {
        case 0: return "No open PRs match right now"
        case 1: return "Matches 1 open PR right now"
        default: return "Matches \(count) open PRs right now"
        }
    }

    private func notes(_ preview: RulePreview, unfinished: Int) -> String {
        var parts: [String] = []
        if preview.matches.count > Self.limit { parts.append("And \(preview.matches.count - Self.limit) more.") }
        if preview.undecided > 0 {
            parts.append("\(preview.undecided) more may match once their CI detail loads on the next refresh.")
        }
        if unfinished > 0 { parts.append(unfinished == 1 ? "Ignoring 1 unfinished rule." : "Ignoring \(unfinished) unfinished rules.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Notifications

/// One switch per event kind. CI finishing is one switch with an outcome filter.
struct NotifySection: View {
    @Binding var notify: Set<EventKind>

    private static let others: [EventKind] = [.enteredMergeQueue, .droppedFromMergeQueue, .approved, .changesRequested, .reviewRequested, .newMatch]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                ciRow
                ForEach(Self.others, id: \.self) { kind in
                    Divider()
                    row(kind)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Banners use your macOS notification settings. Events only fire for PRs that match this view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ciRow: some View {
        let on = !notify.isDisjoint(with: CIOutcomeChoice.kinds)
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green).frame(width: 18)
            Text("CI finished")
            Spacer()
            if on {
                Menu {
                    ForEach(CIOutcomeChoice.kinds, id: \.self) { kind in
                        Toggle(CIOutcomeChoice.title(kind), isOn: binding(kind))
                    }
                } label: {
                    Text(CIOutcomeChoice.summary(notify))
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel("CI outcomes")
            }
            Toggle("CI finished", isOn: Binding(
                get: { on },
                set: { newValue in
                    if newValue { notify.formUnion(CIOutcomeChoice.kinds) } else { notify.subtract(CIOutcomeChoice.kinds) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
    }

    private func row(_ kind: EventKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(kind)).foregroundStyle(Self.tint(kind)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(kind))
                if kind == .newMatch {
                    Text("Once it's ready for review, not while it's a draft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(Self.title(kind), isOn: binding(kind))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 34)
    }

    private func binding(_ kind: EventKind) -> Binding<Bool> {
        Binding(
            get: { notify.contains(kind) },
            set: { if $0 { notify.insert(kind) } else { notify.remove(kind) } }
        )
    }

    static func title(_ kind: EventKind) -> String {
        switch kind {
        case .newMatch: "New PR matches this view"
        default: kind.title
        }
    }

    static func symbol(_ kind: EventKind) -> String {
        switch kind {
        case .enteredMergeQueue: "arrow.right.to.line.circle"
        case .droppedFromMergeQueue: "exclamationmark.triangle"
        case .approved: "checkmark.seal"
        case .changesRequested: "exclamationmark.bubble"
        case .reviewRequested: "eye"
        case .newMatch: "tray.and.arrow.down"
        default: "checkmark.circle"
        }
    }

    static func tint(_ kind: EventKind) -> Color {
        switch kind {
        case .enteredMergeQueue: .purple
        case .droppedFromMergeQueue: .red
        case .approved: .green
        case .changesRequested: .orange
        case .reviewRequested: .blue
        default: .secondary
        }
    }
}

// MARK: - Templates

/// Starting points for a new view.
struct TemplateChooser: View {
    let onPick: (ViewTemplate) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New View").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Start from a template. You can change every rule after.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(ViewTemplate.allCases) { template in
                        Button { onPick(template) } label: { card(template) }
                            .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func card(_ template: ViewTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: template.symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(height: 26, alignment: .leading)
            Text(template.title).font(.headline)
            Text(template.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Manage views

/// Every view, to reorder (drag), duplicate, delete, edit, or add.
struct ManageViewsList: View {
    let store: PRStore
    let onEdit: (UUID) -> Void
    let onNew: () -> Void
    let onDone: () -> Void

    @State private var selection: UUID?
    @State private var pendingDelete: SavedView?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Views").font(.headline)
                Spacer()
                Button(action: onNew) { Label("New View…", systemImage: "plus") }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            List(selection: $selection) {
                ForEach(store.views) { view in
                    row(view).tag(view.id)
                }
                .onMove { store.moveViews(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first { menuItems(id) }
            } primaryAction: { ids in
                if let id = ids.first { onEdit(id) }
            }
            Divider()
            HStack(spacing: 8) {
                Button("Edit…") { selection.map(onEdit) }
                    .disabled(selection == nil)
                Button("Duplicate") { duplicate() }
                    .disabled(selection == nil)
                Button("Delete…") { pendingDelete = store.views.first { $0.id == selection } }
                    .disabled(selection == nil)
                Text("Drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete View", role: .destructive) {
                if let id = pendingDelete?.id {
                    store.deleteView(id: id)
                    if selection == id { selection = nil }
                }
                pendingDelete = nil
            }
        } message: {
            Text("Its rules and notification settings go too. PRs aren't affected.")
        }
    }

    private func row(_ view: SavedView) -> some View {
        let count = store.pullRequests(in: view.id).count
        let summary = view.rule.summary
        return HStack(spacing: 10) {
            Image(systemName: view.symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(view.name).fontWeight(.medium)
                    if view.pinnedToMenubar {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Pinned to the menu bar")
                            .accessibilityLabel("Pinned to the menu bar")
                    }
                }
                Text(summary.prefix(1).uppercased() + summary.dropFirst())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if store.viewer != nil {
                Text("\(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) open PRs")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func menuItems(_ id: UUID) -> some View {
        Button("Edit…") { onEdit(id) }
        Button("Duplicate") { store.duplicateView(id: id) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = store.views.first { $0.id == id } }
    }

    private func duplicate() {
        guard let id = selection, let copy = store.duplicateView(id: id) else { return }
        selection = copy.id
    }
}
