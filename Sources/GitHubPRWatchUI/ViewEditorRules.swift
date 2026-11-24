import GitHubPRWatchCore
import SwiftUI

/// The rule list of the view editor: "Match [all] of the following rules", then one line per
/// rule, [field] [operator] [value] [−] [+], with nested groups one level deep.
struct RuleListEditor: View {
    @Binding var draft: ViewDraft
    let store: PRStore
    let focus: FocusState<UUID?>.Binding
    /// Rows to outline in red.
    let flagged: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Match")
                MatchPicker(match: $draft.match)
                Text("of the following rules:")
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(draft.items) { item in
                    switch item.content {
                    case .row(let row):
                        RuleRowView(
                            row: rowBinding(row.id), store: store, focus: focus, isNested: false,
                            isFlagged: flagged.contains(row.id),
                            onAdd: { focus.wrappedValue = draft.addRow(after: item.id) },
                            onRemove: { draft.remove(row.id) },
                            onMakeGroup: { makeGroup(item.id, match: $0) }
                        )
                    case .group(let group):
                        groupView(item.id, group)
                    case .preserved(let condition):
                        PreservedRow(summary: condition.summary) { draft.remove(item.id) }
                    }
                }
                if draft.items.isEmpty {
                    Text("No rules yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            HStack(spacing: 12) {
                Button {
                    focus.wrappedValue = draft.addRow(after: draft.items.last?.id)
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Button {
                    focus.wrappedValue = draft.addGroup()
                } label: {
                    Label("Add Group", systemImage: "plus.square.on.square")
                }
                .help("A group matches when any, all, or none of its own rules do. Use it for “author is me or assignee is me”.")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    @ViewBuilder
    private func groupView(_ itemID: UUID, _ group: RuleGroupDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                MatchPicker(match: groupMatchBinding(itemID), capitalized: true)
                Text("of the following are true:")
                Spacer(minLength: 8)
                RowButtons(
                    onRemove: { draft.remove(itemID) },
                    onAdd: { focus.wrappedValue = draft.addRow(after: itemID) },
                    removeHelp: "Remove this group and its rules"
                )
            }
            .flagged(flagged.contains(itemID))
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.rows) { row in
                        RuleRowView(
                            row: rowBinding(row.id), store: store, focus: focus, isNested: true,
                            isFlagged: flagged.contains(row.id),
                            onAdd: { focus.wrappedValue = draft.addRow(inGroup: itemID, after: row.id) },
                            onRemove: { draft.remove(row.id) },
                            onMakeGroup: { _ in }
                        )
                    }
                }
            }
            .padding(.leading, 6)
        }
    }

    private func rowBinding(_ id: UUID) -> Binding<RuleRowDraft> {
        Binding(
            get: { draft.row(id) ?? RuleRowDraft(id: id, field: .repo) },
            set: { draft.update($0) }
        )
    }

    private func groupMatchBinding(_ id: UUID) -> Binding<FilterRule.Match> {
        Binding(
            get: {
                guard let item = draft.items.first(where: { $0.id == id }), case .group(let group) = item.content else { return .any }
                return group.match
            },
            set: { match in
                guard let index = draft.items.firstIndex(where: { $0.id == id }), case .group(var group) = draft.items[index].content else { return }
                group.match = match
                draft.items[index].content = .group(group)
            }
        )
    }

    /// Turns a top-level row into a group holding that row, as Mail's "Any of the following…".
    private func makeGroup(_ itemID: UUID, match: FilterRule.Match) {
        guard let index = draft.items.firstIndex(where: { $0.id == itemID }), case .row(let row) = draft.items[index].content else { return }
        draft.items[index] = .group(RuleGroupDraft(match: match, rows: [row]))
    }
}

/// "all / any / none" as a pop-up button.
struct MatchPicker: View {
    @Binding var match: FilterRule.Match
    var capitalized = false

    var body: some View {
        Picker("Match", selection: $match) {
            ForEach(FilterRule.Match.allCases, id: \.self) { m in
                Text(capitalized ? m.rawValue.capitalized : m.rawValue).tag(m)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// What the field pop-up can choose: a field, or turning the row into a group.
enum FieldMenuChoice: Hashable {
    case field(RuleField)
    case group(FilterRule.Match)
}

/// One [field] [operator] [value] [−] [+] line.
struct RuleRowView: View {
    @Binding var row: RuleRowDraft
    let store: PRStore
    let focus: FocusState<UUID?>.Binding
    let isNested: Bool
    let isFlagged: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onMakeGroup: (FilterRule.Match) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            line
            if row.field == .reviewRequested, row.op == .fromMeOrMyTeams {
                TeamAccessNote(access: store.teamAccess, teams: store.viewerTeams)
                    .padding(.leading, fieldWidth + 10)
            }
        }
    }

    private var fieldWidth: CGFloat { isNested ? 152 : 164 }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Picker("Field", selection: fieldChoice) {
                ForEach(RuleField.allCases) { field in
                    Text(field.title).tag(FieldMenuChoice.field(field))
                }
                if !isNested {
                    Divider()
                    Text("Any of the following…").tag(FieldMenuChoice.group(.any))
                    Text("All of the following…").tag(FieldMenuChoice.group(.all))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: fieldWidth)
            .accessibilityLabel("Field")

            if row.field.operators.count > 1 {
                Picker("Operator", selection: $row.op) {
                    ForEach(row.field.operators, id: \.self) { op in
                        Text(op.title(for: row.field)).tag(op)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Operator")
            } else {
                Text(row.op.title(for: row.field))
                    .foregroundStyle(.secondary)
            }

            value
                .frame(maxWidth: .infinity, alignment: .leading)

            RowButtons(onRemove: onRemove, onAdd: onAdd, removeHelp: "Remove this rule")
        }
    }

    @ViewBuilder private var value: some View {
        switch row.valueKind {
        case .none:
            Spacer(minLength: 0)
        case .text:
            TextField("", text: $row.text, prompt: Text(row.field.placeholder))
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: row.id)
                .flagged(isFlagged)
        case .list:
            if row.isChoice {
                ChoiceMenu(row: $row)
                    .flagged(isFlagged)
            } else {
                TokenField(row: $row, suggestions: store.suggestions(for: row.field), focus: focus, isInvalid: isFlagged)
            }
        }
    }

    private var fieldChoice: Binding<FieldMenuChoice> {
        Binding(
            get: { .field(row.field) },
            set: { choice in
                switch choice {
                case .field(let field): row.setField(field)
                case .group(let match): onMakeGroup(match)
                }
            }
        )
    }
}

/// Choices for CI state, merge state, lane (several at once) and draft (one).
struct ChoiceMenu: View {
    @Binding var row: RuleRowDraft

    var body: some View {
        if row.field.allowsSeveralChoices {
            Menu {
                ForEach(row.field.choices) { choice in
                    Toggle(choice.title, isOn: Binding(
                        get: { row.values.contains(choice.value) },
                        set: { _ in row.toggleChoice(choice.value) }
                    ))
                }
            } label: {
                Text(summary)
            }
            .menuStyle(.button)
            .fixedSize()
            .accessibilityLabel("\(row.field.title) values")
        } else {
            Picker("Value", selection: Binding(get: { row.values.first ?? "" }, set: { row.toggleChoice($0) })) {
                ForEach(row.field.choices) { Text($0.title).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var summary: String {
        let titles = row.field.choices.filter { row.values.contains($0.value) }.map(\.title)
        return titles.isEmpty ? "Choose…" : titles.joined(separator: " or ")
    }
}

/// The round − and + buttons at the end of a line.
struct RowButtons: View {
    let onRemove: () -> Void
    let onAdd: () -> Void
    let removeHelp: String

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .help(removeHelp)
                .accessibilityLabel(removeHelp)
            Button(action: onAdd) { Image(systemName: "plus.circle") }
                .help("Add a rule below")
                .accessibilityLabel("Add a rule below")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
    }
}

/// A condition the builder can't edit, such as a group nested two deep. Kept as it is.
struct PreservedRow: View {
    let summary: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .help("Remove this rule")
        }
        .help("This rule is nested deeper than the editor shows. It's kept as it is.")
    }
}

/// Under "review requested is me or my teams": which teams count, or why none do.
struct TeamAccessNote: View {
    let access: PRStore.TeamAccess
    let teams: Set<String>

    var body: some View {
        Group {
            switch access {
            case .missingScope:
                Label("Can't read your teams (needs read:org). Counting requests by name.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .failed:
                Label("Couldn't read your teams. Counting requests by name for now.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .unknown:
                Text("Your teams load with the next refresh")
                    .foregroundStyle(.secondary)
            case .available:
                Text(teams.isEmpty ? "You're on no teams in these orgs" : "Your teams: " + teams.sorted().joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .help(access == .missingScope
            ? "Run `gh auth refresh -s read:org`, or use a token with read:org, so requests to your teams count as requests to you."
            : "")
    }
}

extension View {
    /// A red outline for a control that's missing its value.
    func flagged(_ isFlagged: Bool) -> some View {
        overlay {
            if isFlagged {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red, lineWidth: 1.5).padding(-2)
            }
        }
    }
}
