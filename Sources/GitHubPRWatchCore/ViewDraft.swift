import Foundation

// The editable form of a view, for the rule builder. A view's rule tree becomes a list of
// rows, each [field] [operator] [value], plus nested groups one level deep. The draft turns
// back into a `SavedView` on save. Anything the builder can't show (deeper nesting, a
// predicate it has no row for) is kept as it was and shown read-only.

/// What a rule row tests.
public enum RuleField: String, CaseIterable, Identifiable, Sendable, Hashable {
    case author, assignee, reviewRequested, repo, label, draft, ci, mergeState, lane, title, baseBranch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .author: "Author"
        case .assignee: "Assignee"
        case .reviewRequested: "Review requested"
        case .repo: "Repo"
        case .label: "Label"
        case .draft: "Draft"
        case .ci: "CI state"
        case .mergeState: "Merge state"
        case .lane: "Lane"
        case .title: "Title"
        case .baseBranch: "Base branch"
        }
    }

    /// The operators the field offers, default first.
    public var operators: [RuleOperator] {
        switch self {
        case .author: [.isAnyOf, .is, .isNot]
        case .assignee: [.isAnyOf, .is, .isNot, .isEmpty, .isNotEmpty]
        case .reviewRequested: [.fromMe, .fromMeOrMyTeams, .isAnyOf]
        case .repo: [.is, .isAnyOf, .isNot]
        case .label: [.has, .doesNotHave]
        case .draft: [.is]
        case .ci, .mergeState, .lane: [.is, .isNot]
        case .title: [.contains, .doesNotContain]
        case .baseBranch: [.is, .isAnyOf, .isNot]
        }
    }

    /// Fields whose values are GitHub logins, with a "me" token.
    public var takesPeople: Bool { self == .author || self == .assignee || self == .reviewRequested }

    /// The fixed values a choice field offers, as (raw value, title).
    public var choices: [RuleChoice] {
        switch self {
        case .draft: [RuleChoice("no", "No"), RuleChoice("yes", "Yes")]
        case .ci: [
            RuleChoice(CIStateFilter.running.rawValue, "Running"), RuleChoice(CIStateFilter.passed.rawValue, "Passed"),
            RuleChoice(CIStateFilter.failed.rawValue, "Failed"), RuleChoice(CIStateFilter.noChecks.rawValue, "No checks"),
        ]
        case .mergeState: [
            RuleChoice(MergeStateFilter.clean.rawValue, "Ready"), RuleChoice(MergeStateFilter.blocked.rawValue, "Blocked"),
            RuleChoice(MergeStateFilter.conflicts.rawValue, "Conflicts"), RuleChoice(MergeStateFilter.inQueue.rawValue, "In merge queue"),
            RuleChoice(MergeStateFilter.behind.rawValue, "Behind base"), RuleChoice(MergeStateFilter.autoMerge.rawValue, "Auto-merge on"),
        ]
        case .lane: Lane.allCases.map { RuleChoice($0.rawValue, $0.title) }
        default: []
        }
    }

    /// Whether more than one choice can be picked (all choice fields but draft).
    public var allowsSeveralChoices: Bool { self != .draft }

    /// What the value field asks for, as placeholder text.
    public var placeholder: String {
        switch self {
        case .author, .assignee, .reviewRequested: "logins, or me"
        case .repo: "owner/repo"
        case .label: "label"
        case .baseBranch: "branch"
        case .title: "text"
        default: ""
        }
    }
}

public struct RuleChoice: Hashable, Sendable, Identifiable {
    public var value: String
    public var title: String
    public var id: String { value }
    public init(_ value: String, _ title: String) {
        self.value = value
        self.title = title
    }
}

public enum RuleOperator: String, CaseIterable, Sendable, Hashable {
    case `is`, isNot, isAnyOf, isEmpty, isNotEmpty, fromMe, fromMeOrMyTeams, has, doesNotHave, contains, doesNotContain

    public func title(for field: RuleField) -> String {
        switch self {
        case .is: "is"
        case .isNot: "is not"
        case .isAnyOf: "is any of"
        case .isEmpty: "is nobody"
        case .isNotEmpty: "is anybody"
        case .fromMe: "is me"
        case .fromMeOrMyTeams: "is me or my teams"
        case .has: "has any of"
        case .doesNotHave: "has none of"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        }
    }

    public var valueKind: RuleValueKind {
        switch self {
        case .isEmpty, .isNotEmpty, .fromMe, .fromMeOrMyTeams: .none
        case .contains, .doesNotContain: .text
        default: .list
        }
    }

    /// Negating operators wrap the predicate in `.not`.
    var negates: Bool { self == .isNot || self == .doesNotHave || self == .doesNotContain || self == .isNotEmpty }
}

public enum RuleValueKind: Sendable, Hashable {
    /// The operator says it all, such as "is me" or "is nobody".
    case none
    /// Free text.
    case text
    /// Tokens (logins, repos, labels, branches) or choices, by field.
    case list
}

/// One [field] [operator] [value] row.
public struct RuleRowDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public private(set) var field: RuleField
    public var op: RuleOperator
    /// The "me" token, for people fields.
    public var includesMe: Bool
    /// Logins, repos, labels or branches as typed; or choice raw values.
    public var values: [String]
    public var text: String

    public init(
        id: UUID = UUID(), field: RuleField, op: RuleOperator? = nil, includesMe: Bool = false,
        values: [String] = [], text: String = ""
    ) {
        self.id = id
        self.field = field
        self.op = op.flatMap { field.operators.contains($0) ? $0 : nil } ?? field.operators[0]
        self.includesMe = includesMe && field.takesPeople
        self.values = values
        self.text = text
        if field.choices.isEmpty == false, values.isEmpty, field == .draft { self.values = ["no"] }
    }

    /// Changes the field, keeping what still makes sense: people stay people, the operator
    /// stays when the new field has it.
    public mutating func setField(_ newField: RuleField) {
        guard newField != field else { return }
        let keepTokens = (field.takesPeople && newField.takesPeople)
            || (field.choices.isEmpty && newField.choices.isEmpty && !field.takesPeople && !newField.takesPeople)
        let oldOp = op
        field = newField
        op = newField.operators.contains(oldOp) ? oldOp : newField.operators[0]
        if !keepTokens { values = [] }
        if !newField.takesPeople { includesMe = false }
        if newField == .draft { values = ["no"] }
    }

    public var valueKind: RuleValueKind {
        if op.valueKind == .list, !field.choices.isEmpty { return .list }
        return op.valueKind
    }

    public var isChoice: Bool { !field.choices.isEmpty }

    /// True when the row needs a value it doesn't have.
    public var isMissingValue: Bool {
        switch valueKind {
        case .none: false
        case .text: text.trimmingCharacters(in: .whitespaces).isEmpty
        case .list: values.isEmpty && !includesMe
        }
    }

    /// Adds typed or pasted tokens. "me" becomes the me token in people fields. Duplicates
    /// (ignoring case) are skipped. Returns how many were added.
    @discardableResult
    public mutating func addTokens(_ raw: [String]) -> Int {
        var added = 0
        for token in raw {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if field.takesPeople, value.lowercased() == "me" {
                if !includesMe { includesMe = true; added += 1 }
                continue
            }
            guard !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
            values.append(value)
            added += 1
        }
        // "is" with several values reads as "is any of".
        if op == .is, values.count + (includesMe ? 1 : 0) > 1, field.operators.contains(.isAnyOf) { op = .isAnyOf }
        return added
    }

    /// Removes the last token, as Backspace in an empty token field does.
    public mutating func removeLastToken() {
        if !values.isEmpty { values.removeLast() } else { includesMe = false }
    }

    public mutating func toggleChoice(_ value: String) {
        if !field.allowsSeveralChoices {
            values = [value]
        } else if let index = values.firstIndex(of: value) {
            values.remove(at: index)
        } else {
            values.append(value)
        }
    }

    /// The predicate, or `nil` while the row is missing its value.
    public var predicate: Predicate? {
        guard !isMissingValue else { return nil }
        let users = UserList(includesMe: includesMe, logins: values)
        let base: Predicate? = switch field {
        case .author: .author(users)
        case .assignee: op == .isEmpty || op == .isNotEmpty ? .unassigned : .assignee(users)
        case .reviewRequested:
            switch op {
            case .fromMe: .reviewRequested(.me)
            case .fromMeOrMyTeams: .reviewRequested(.meOrMyTeams)
            default: .reviewRequested(users)
            }
        case .repo: .repo(values)
        case .label: .label(values)
        case .draft: .isDraft(values.first == "yes")
        case .ci: .ci(values.compactMap(CIStateFilter.init(rawValue:)))
        case .mergeState: .mergeState(values.compactMap(MergeStateFilter.init(rawValue:)))
        case .lane: .lane(values.compactMap(Lane.init(rawValue:)))
        case .title: .titleContains(text.trimmingCharacters(in: .whitespaces))
        case .baseBranch: .baseBranch(values)
        }
        guard let base else { return nil }
        return op.negates ? .not(base) : base
    }

    /// The row for a predicate, or `nil` when the builder has no row for it.
    public init?(predicate: Predicate) {
        var negated = false
        var inner = predicate
        if case .not(let wrapped) = predicate {
            negated = true
            inner = wrapped
            if case .not = wrapped { return nil }
        }
        func listOp(_ count: Int) -> RuleOperator { negated ? .isNot : (count > 1 ? .isAnyOf : .is) }
        switch inner {
        case .author(let u):
            guard !u.includesMyTeams else { return nil }
            self.init(field: .author, op: listOp(u.logins.count + (u.includesMe ? 1 : 0)), includesMe: u.includesMe, values: u.logins)
        case .assignee(let u):
            guard !u.includesMyTeams else { return nil }
            self.init(field: .assignee, op: listOp(u.logins.count + (u.includesMe ? 1 : 0)), includesMe: u.includesMe, values: u.logins)
        case .unassigned:
            self.init(field: .assignee, op: negated ? .isNotEmpty : .isEmpty)
        case .reviewRequested(let u):
            guard !negated else { return nil }
            if u == .me {
                self.init(field: .reviewRequested, op: .fromMe)
            } else if u == .meOrMyTeams {
                self.init(field: .reviewRequested, op: .fromMeOrMyTeams)
            } else {
                guard !u.includesMyTeams else { return nil }
                self.init(field: .reviewRequested, op: .isAnyOf, includesMe: u.includesMe, values: u.logins)
            }
        case .repo(let r): self.init(field: .repo, op: listOp(r.count), values: r)
        case .baseBranch(let b): self.init(field: .baseBranch, op: listOp(b.count), values: b)
        case .label(let l): self.init(field: .label, op: negated ? .doesNotHave : .has, values: l)
        case .isDraft(let d): self.init(field: .draft, op: .is, values: [(d != negated) ? "yes" : "no"])
        case .ci(let s): self.init(field: .ci, op: negated ? .isNot : .is, values: s.map(\.rawValue))
        case .mergeState(let s): self.init(field: .mergeState, op: negated ? .isNot : .is, values: s.map(\.rawValue))
        case .lane(let l): self.init(field: .lane, op: negated ? .isNot : .is, values: l.map(\.rawValue))
        case .titleContains(let t): self.init(field: .title, op: negated ? .doesNotContain : .contains, text: t)
        case .not: return nil
        }
    }
}

/// A nested all/any/none group of rows.
public struct RuleGroupDraft: Hashable, Sendable {
    public var match: FilterRule.Match
    public var rows: [RuleRowDraft]

    public init(match: FilterRule.Match = .any, rows: [RuleRowDraft] = []) {
        self.match = match
        self.rows = rows
    }
}

/// One line of the top-level list: a row, a nested group, or a condition the builder
/// can't edit, kept as it was.
public struct RuleItemDraft: Identifiable, Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case row(RuleRowDraft)
        case group(RuleGroupDraft)
        case preserved(FilterCondition)
    }

    public var id: UUID
    public var content: Content

    public init(id: UUID = UUID(), _ content: Content) {
        self.id = id
        self.content = content
    }

    public static func row(_ row: RuleRowDraft) -> RuleItemDraft { RuleItemDraft(id: row.id, .row(row)) }
    public static func group(_ group: RuleGroupDraft) -> RuleItemDraft { RuleItemDraft(.group(group)) }

    init(condition: FilterCondition) {
        switch condition {
        case .predicate(let p):
            if let row = RuleRowDraft(predicate: p) { self = .row(row) } else { self.init(.preserved(condition)) }
        case .group(let rule):
            var rows: [RuleRowDraft] = []
            for c in rule.conditions {
                guard case .predicate(let p) = c, let row = RuleRowDraft(predicate: p) else {
                    self.init(.preserved(condition))
                    return
                }
                rows.append(row)
            }
            self.init(.group(RuleGroupDraft(match: rule.match, rows: rows)))
        }
    }
}

/// Why a draft can't be saved yet. `rowID` points at the row or group to flag.
public struct ViewDraftIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case nameMissing, noRules, emptyValue, emptyGroup }
    public var kind: Kind
    public var rowID: UUID?
    public var message: String
}

/// A view being edited.
public struct ViewDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var match: FilterRule.Match
    public var items: [RuleItemDraft]
    public var notify: Set<EventKind>
    public var pinnedToMenubar: Bool

    public init(
        id: UUID = UUID(), name: String = "", symbol: String = "line.3.horizontal.decrease.circle",
        match: FilterRule.Match = .all, items: [RuleItemDraft] = [], notify: Set<EventKind> = [], pinnedToMenubar: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.match = match
        self.items = items
        self.notify = notify
        self.pinnedToMenubar = pinnedToMenubar
    }

    public init(_ view: SavedView) {
        self.init(
            id: view.id, name: view.name, symbol: view.symbol, match: view.rule.match,
            items: view.rule.conditions.map(RuleItemDraft.init(condition:)),
            notify: view.notify, pinnedToMenubar: view.pinnedToMenubar
        )
    }

    // MARK: Output

    /// The rule as drafted, skipping rows that are missing a value and empty groups.
    /// For the live preview, which updates while the user is still typing.
    public var rule: FilterRule {
        FilterRule(match: match, items.compactMap { item in
            switch item.content {
            case .row(let row): return row.predicate.map(FilterCondition.predicate)
            case .group(let group):
                let conditions = group.rows.compactMap { $0.predicate.map(FilterCondition.predicate) }
                return conditions.isEmpty ? nil : .group(FilterRule(match: group.match, conditions))
            case .preserved(let condition): return condition
            }
        })
    }

    /// Everything that stops a save, in display order.
    public var issues: [ViewDraftIssue] {
        var issues: [ViewDraftIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ViewDraftIssue(kind: .nameMissing, message: "Give the view a name."))
        }
        if items.isEmpty {
            issues.append(ViewDraftIssue(kind: .noRules, message: "Add at least one rule."))
        }
        for item in items {
            switch item.content {
            case .row(let row) where row.isMissingValue:
                issues.append(ViewDraftIssue(kind: .emptyValue, rowID: row.id, message: Self.missingValueMessage(row)))
            case .group(let group):
                if group.rows.isEmpty {
                    issues.append(ViewDraftIssue(kind: .emptyGroup, rowID: item.id, message: "A group needs at least one rule."))
                }
                for row in group.rows where row.isMissingValue {
                    issues.append(ViewDraftIssue(kind: .emptyValue, rowID: row.id, message: Self.missingValueMessage(row)))
                }
            default:
                break
            }
        }
        return issues
    }

    public var isValid: Bool { issues.isEmpty }

    /// The view to save, or `nil` while there are issues.
    public var savedView: SavedView? {
        guard isValid else { return nil }
        return SavedView(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), symbol: symbol,
            rule: rule, notify: notify, pinnedToMenubar: pinnedToMenubar
        )
    }

    static func missingValueMessage(_ row: RuleRowDraft) -> String {
        switch row.field {
        case .author, .assignee, .reviewRequested: "Add at least one login to “\(row.field.title)”, or remove the rule."
        case .repo: "Add a repo, or remove the rule."
        case .label: "Add a label, or remove the rule."
        case .baseBranch: "Add a branch, or remove the rule."
        case .title: "Type the text the title should contain, or remove the rule."
        case .ci, .mergeState, .lane, .draft: "Pick at least one \(row.field.title.lowercased()), or remove the rule."
        }
    }

    // MARK: Editing

    /// Adds a row after `itemID` (or at the end), copying that row's field.
    @discardableResult
    public mutating func addRow(after itemID: UUID? = nil, field: RuleField? = nil) -> UUID {
        let index = itemID.flatMap { id in items.firstIndex { $0.id == id } }
        var newField = field ?? .repo
        if field == nil, let index, case .row(let row) = items[index].content { newField = row.field }
        let row = RuleRowDraft(field: newField)
        items.insert(.row(row), at: index.map { $0 + 1 } ?? items.endIndex)
        return row.id
    }

    /// Adds a nested group with one row.
    @discardableResult
    public mutating func addGroup(after itemID: UUID? = nil, match: FilterRule.Match = .any) -> UUID {
        let index = itemID.flatMap { id in items.firstIndex { $0.id == id } }
        let row = RuleRowDraft(field: .author)
        items.insert(.group(RuleGroupDraft(match: match, rows: [row])), at: index.map { $0 + 1 } ?? items.endIndex)
        return row.id
    }

    /// Adds a row inside the group `groupID`, after `rowID` when given.
    @discardableResult
    public mutating func addRow(inGroup groupID: UUID, after rowID: UUID? = nil) -> UUID? {
        guard let index = items.firstIndex(where: { $0.id == groupID }), case .group(var group) = items[index].content else { return nil }
        let rowIndex = rowID.flatMap { id in group.rows.firstIndex { $0.id == id } }
        let field = rowIndex.map { group.rows[$0].field } ?? .author
        let row = RuleRowDraft(field: field)
        group.rows.insert(row, at: rowIndex.map { $0 + 1 } ?? group.rows.endIndex)
        items[index].content = .group(group)
        return row.id
    }

    /// Removes a top-level item, or a row inside a group. A group left empty goes too.
    public mutating func remove(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
            return
        }
        for index in items.indices {
            guard case .group(var group) = items[index].content, let rowIndex = group.rows.firstIndex(where: { $0.id == id }) else { continue }
            group.rows.remove(at: rowIndex)
            if group.rows.isEmpty {
                items.remove(at: index)
            } else {
                items[index].content = .group(group)
            }
            return
        }
    }

    /// The row with this ID, at the top level or in a group.
    public func row(_ id: UUID) -> RuleRowDraft? {
        for item in items {
            switch item.content {
            case .row(let row) where row.id == id: return row
            case .group(let group): if let row = group.rows.first(where: { $0.id == id }) { return row }
            default: continue
            }
        }
        return nil
    }

    /// Replaces the row with the same ID.
    public mutating func update(_ row: RuleRowDraft) {
        for index in items.indices {
            switch items[index].content {
            case .row(let existing) where existing.id == row.id:
                items[index].content = .row(row)
                return
            case .group(var group):
                if let rowIndex = group.rows.firstIndex(where: { $0.id == row.id }) {
                    group.rows[rowIndex] = row
                    items[index].content = .group(group)
                    return
                }
            default:
                continue
            }
        }
    }

    /// The first people row still waiting for logins, to focus when a template opens.
    public var firstEmptyPeopleRowID: UUID? {
        for item in items {
            switch item.content {
            case .row(let row) where row.field.takesPeople && row.isMissingValue: return row.id
            case .group(let group): if let row = group.rows.first(where: { $0.field.takesPeople && $0.isMissingValue }) { return row.id }
            default: continue
            }
        }
        return nil
    }

    /// Whether any rule asks about team review requests, so the editor can say when the
    /// token can't read teams.
    public var usesTeams: Bool {
        func rowUses(_ row: RuleRowDraft) -> Bool { row.field == .reviewRequested && row.op == .fromMeOrMyTeams }
        return items.contains { item in
            switch item.content {
            case .row(let row): rowUses(row)
            case .group(let group): group.rows.contains(where: rowUses)
            case .preserved: false
            }
        }
    }
}

// MARK: - Tokens

public enum TokenInput {
    /// Splits typed or pasted text into tokens on commas, semicolons, whitespace and
    /// newlines, dropping a leading `@` from each, as when pasting `@rchen, @jlin-agent`.
    public static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.hasPrefix("@") ? String($0.dropFirst()) : String($0) }
            .filter { !$0.isEmpty }
    }

    /// Whether the text ends in a separator, meaning the user finished the last token.
    public static func endsWithSeparator(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "," || last == ";" || last.isWhitespace
    }
}

// MARK: - Notifications

/// The CI-finished events as one setting with an outcome filter, as the editor shows them.
public enum CIOutcomeChoice {
    public static let kinds: [EventKind] = [.ciFailed, .ciReady, .ciBlocked, .ciPassed]

    public static func title(_ kind: EventKind) -> String {
        switch kind {
        case .ciFailed: "Failed"
        case .ciReady: "Green and ready"
        case .ciBlocked: "Green but blocked"
        case .ciPassed: "Green, still waiting"
        default: kind.title
        }
    }

    /// `Any outcome`, `Failed`, `Failed or Green and ready`.
    public static func summary(_ notify: Set<EventKind>) -> String {
        let chosen = kinds.filter(notify.contains)
        if chosen.count == kinds.count { return "Any outcome" }
        if chosen.isEmpty { return "Off" }
        return chosen.map(title).joined(separator: " or ")
    }
}
