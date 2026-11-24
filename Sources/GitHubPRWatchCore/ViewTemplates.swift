import Foundation

/// Starting points for a new view, with notification defaults that suit each.
public enum ViewTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank, mine, needsMyReview, watchlist, agentPRs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .mine: "Mine"
        case .needsMyReview: "Needs my review"
        case .watchlist: "Watchlist"
        case .agentPRs: "Agent PRs"
        }
    }

    public var subtitle: String {
        switch self {
        case .blank: "Start from one empty rule."
        case .mine: "PRs you authored or are assigned to."
        case .needsMyReview: "Review requested from you or your teams."
        case .watchlist: "Any open PR from a list of people, once it's ready for review."
        case .agentPRs: "PRs your coding agents open and assign to you."
        }
    }

    public var symbol: String {
        switch self {
        case .blank: "line.3.horizontal.decrease.circle"
        case .mine: "tray"
        case .needsMyReview: "eye"
        case .watchlist: "person.2"
        case .agentPRs: "sparkles"
        }
    }

    /// Templates that need logins open with the login field focused.
    public var needsLogins: Bool { self == .watchlist || self == .agentPRs }

    /// A new draft from the template. The name gets a number when `existingNames` has it.
    public func draft(existingNames: [String] = []) -> ViewDraft {
        var draft: ViewDraft
        switch self {
        case .blank:
            draft = ViewDraft(name: "", match: .all, items: [.row(RuleRowDraft(field: .repo))], notify: [.ciFailed, .ciReady])
        case .mine:
            draft = ViewDraft(BuiltInViews.mine)
        case .needsMyReview:
            draft = ViewDraft(BuiltInViews.needsMyReview)
            draft.items = [.row(RuleRowDraft(field: .reviewRequested, op: .fromMeOrMyTeams))]
            draft.notify = [.reviewRequested]
        case .watchlist:
            draft = ViewDraft(BuiltInViews.watchlist())
            draft.items = [
                .row(RuleRowDraft(field: .author, op: .isAnyOf)),
                .row(RuleRowDraft(field: .draft, values: ["no"])),
            ]
            draft.notify = [.newMatch]
        case .agentPRs:
            draft = ViewDraft(BuiltInViews.agentPRs())
            draft.items = [
                .row(RuleRowDraft(field: .author, op: .isAnyOf)),
                .row(RuleRowDraft(field: .assignee, op: .is, includesMe: true)),
            ]
            draft.notify = [.ciReady, .ciBlocked, .ciFailed, .droppedFromMergeQueue, .newMatch]
        }
        draft.id = UUID()
        draft.pinnedToMenubar = self == .mine || self == .needsMyReview
        if self != .blank { draft.name = Self.uniqueName(title, existing: existingNames) }
        return draft
    }

    /// `Watchlist`, or `Watchlist 2` when that's taken.
    public static func uniqueName(_ base: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

/// SF Symbols offered for a view.
public enum ViewSymbols {
    public static let all = [
        "line.3.horizontal.decrease.circle", "tray", "eye", "person.2", "sparkles", "star",
        "flag", "bolt", "bell", "hammer", "shippingbox", "tag",
        "person.crop.circle", "person.3", "bookmark", "exclamationmark.triangle",
        "checkmark.seal", "clock", "flame", "ladybug",
    ]
}
