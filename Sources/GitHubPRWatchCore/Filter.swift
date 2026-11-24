import Foundation

// A view is a saved filter: a named rule tree plus notification rules. The tree is
// groups of conditions, like a Finder smart folder. A group matches when all, any, or
// none of its conditions match. A condition is a predicate or a nested group.

/// A set of users: the viewer ("me"), the viewer's teams, named logins, or any mix.
/// For review requests a login may also name a team as `org/slug`.
public struct UserList: Codable, Sendable, Equatable, Hashable {
    public var includesMe: Bool
    /// The teams the viewer belongs to. Only review requests go to teams, so only
    /// `Predicate.reviewRequested` uses it. Absent in views saved before it existed.
    public var includesMyTeams: Bool
    public var logins: [String]

    public init(includesMe: Bool = false, includesMyTeams: Bool = false, logins: [String] = []) {
        self.includesMe = includesMe
        self.includesMyTeams = includesMyTeams
        self.logins = logins
    }

    public static let me = UserList(includesMe: true)
    /// Me, or any team I'm on.
    public static let meOrMyTeams = UserList(includesMe: true, includesMyTeams: true)
    public static func anyOf(_ logins: [String]) -> UserList { UserList(logins: logins) }

    public var isEmpty: Bool { !includesMe && !includesMyTeams && logins.isEmpty }

    func contains(_ login: String, viewer: String) -> Bool {
        if includesMe, login.caseInsensitiveCompare(viewer) == .orderedSame { return true }
        return logins.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    /// Whether a review request to `team` (`org/slug`) counts.
    func containsTeam(_ team: String, viewerTeams: Set<String>) -> Bool {
        if includesMyTeams, viewerTeams.contains(team.lowercased()) { return true }
        return logins.contains { $0.caseInsensitiveCompare(team) == .orderedSame }
    }

    /// `me`, `rchen, jlin-agent`, `me or rchen`, `me or my teams`.
    public var summary: String {
        var parts = includesMe ? ["me"] : []
        if includesMyTeams { parts.append("my teams") }
        parts += logins
        return parts.isEmpty ? "nobody" : parts.joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey { case includesMe, includesMyTeams, logins }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includesMe = try container.decodeIfPresent(Bool.self, forKey: .includesMe) ?? false
        includesMyTeams = try container.decodeIfPresent(Bool.self, forKey: .includesMyTeams) ?? false
        logins = try container.decodeIfPresent([String].self, forKey: .logins) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(includesMe, forKey: .includesMe)
        // Written only when set, so a view without it stays readable by older builds.
        if includesMyTeams { try container.encode(includesMyTeams, forKey: .includesMyTeams) }
        try container.encode(logins, forKey: .logins)
    }
}

/// What evaluating a rule needs besides the PR.
public struct FilterContext: Sendable {
    /// The signed-in login, which "me" stands for.
    public var viewer: String
    /// The viewer's teams as lowercased `org/slug`, for "review requested from my teams".
    public var viewerTeams: Set<String>
    /// Lanes already worked out by the classifier, by PR ID. A lane predicate classifies
    /// PRs missing from here itself, with `classification`.
    public var lanes: [String: Lane]
    public var classification: ClassificationContext

    public init(
        viewer: String, viewerTeams: Set<String> = [], lanes: [String: Lane] = [:],
        classification: ClassificationContext = .init()
    ) {
        self.viewer = viewer
        self.viewerTeams = Set(viewerTeams.map { $0.lowercased() })
        self.lanes = lanes
        self.classification = classification
        self.classification.viewerTeams = self.viewerTeams
    }
}

/// The CI state a predicate can ask for.
public enum CIStateFilter: String, Codable, Sendable, CaseIterable {
    case running, passed, failed
    /// The head commit has no checks at all.
    case noChecks
}

/// The merge state a predicate can ask for.
public enum MergeStateFilter: String, Codable, Sendable, CaseIterable {
    /// In a merge queue.
    case inQueue
    /// Has merge conflicts.
    case conflicts
    /// Behind its base branch.
    case behind
    /// Blocked by branch protection.
    case blocked
    /// GitHub would merge it now.
    case clean
    /// Auto-merge is enabled.
    case autoMerge
}

/// One test against a PR. Lists mean "is any of".
///
/// Cases added after the first release (`not`, `unassigned`, `titleContains`, `baseBranch`,
/// `lane`) are new keys in the saved JSON, so views saved earlier still decode.
public enum Predicate: Codable, Sendable, Equatable, Hashable {
    case author(UserList)
    case assignee(UserList)
    /// A review is requested from any of the users, or from a team they name.
    case reviewRequested(UserList)
    /// `nameWithOwner`, such as `acme/web`. Case-insensitive.
    case repo([String])
    /// Has any of these labels. Case-insensitive.
    case label([String])
    case isDraft(Bool)
    case ci([CIStateFilter])
    case mergeState([MergeStateFilter])
    /// The opposite of a predicate. Still `nil` when the inner one is.
    indirect case not(Predicate)
    /// Nobody is assigned.
    case unassigned
    /// The title contains the text, ignoring case and diacritics.
    case titleContains(String)
    /// The base branch is any of these. Case-sensitive, as git is.
    case baseBranch([String])
    /// The PR's lane for the viewer is any of these.
    case lane([Lane])

    /// Whether the PR matches. `nil` means the predicate needs check detail the PR doesn't have.
    public func evaluate(_ pr: PullRequest, viewer: String) -> Bool? {
        evaluate(pr, in: FilterContext(viewer: viewer))
    }

    public func evaluate(_ pr: PullRequest, in context: FilterContext) -> Bool? {
        let viewer = context.viewer
        switch self {
        case .author(let users):
            guard let author = pr.author else { return false }
            return users.contains(author, viewer: viewer)
        case .assignee(let users):
            return pr.assignees.contains { users.contains($0, viewer: viewer) }
        case .reviewRequested(let users):
            return pr.reviewRequests.contains { request in
                switch request {
                case .user(let login): users.contains(login, viewer: viewer)
                case .team(let team): users.containsTeam(team, viewerTeams: context.viewerTeams)
                }
            }
        case .not(let inner):
            return inner.evaluate(pr, in: context).map { !$0 }
        case .unassigned:
            return pr.assignees.isEmpty
        case .titleContains(let text):
            let needle = text.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return true }
            return pr.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .baseBranch(let branches):
            return branches.contains(pr.baseRef)
        case .lane(let lanes):
            if let lane = context.lanes[pr.id] { return lanes.contains(lane) }
            // Without check detail the classifier can't tell a failing or running PR from a
            // waiting one, unless the PR is a draft or queued, which decide the lane first.
            if pr.currentChecks == nil, !pr.isDraft, pr.mergeQueueEntry == nil { return nil }
            return lanes.contains(PRClassifier.classify(pr, viewer: viewer, context: context.classification).lane)
        case .repo(let repos):
            return repos.contains { $0.caseInsensitiveCompare(pr.repo) == .orderedSame }
        case .label(let labels):
            return pr.labels.contains { label in labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        case .isDraft(let draft):
            return pr.isDraft == draft
        case .ci(let states):
            guard let state = CIStateFilter.of(pr) else { return nil }
            return states.contains(state)
        case .mergeState(let states):
            return states.contains { $0.matches(pr) }
        }
    }

    public var summary: String {
        switch self {
        case .author(let u): "author is \(u.summary)"
        case .assignee(let u): "assignee is \(u.summary)"
        case .reviewRequested(let u): "review requested from \(u.summary)"
        case .repo(let r): "repo is \(r.isEmpty ? "none" : r.joined(separator: ", "))"
        case .label(let l): "label is \(l.isEmpty ? "none" : l.joined(separator: ", "))"
        case .isDraft(let d): d ? "is a draft" : "is not a draft"
        case .ci(let s): "CI is \(s.map(\.rawValue).joined(separator: " or "))"
        case .mergeState(let s): "merge state is \(s.map(\.rawValue).joined(separator: " or "))"
        case .not(let p): "not (\(p.summary))"
        case .unassigned: "nobody is assigned"
        case .titleContains(let t): "title contains \"\(t)\""
        case .baseBranch(let b): "base branch is \(b.isEmpty ? "none" : b.joined(separator: ", "))"
        case .lane(let l): "lane is \(l.map(\.title).joined(separator: " or "))"
        }
    }
}

extension CIStateFilter {
    /// The PR's CI state, or `nil` without check detail for the current head.
    public static func of(_ pr: PullRequest) -> CIStateFilter? {
        guard let checks = pr.currentChecks else { return nil }
        if checks.checks.isEmpty { return .noChecks }
        if !checks.failing.isEmpty { return .failed }
        if !checks.running.isEmpty { return .running }
        return .passed
    }
}

extension MergeStateFilter {
    func matches(_ pr: PullRequest) -> Bool {
        switch self {
        case .inQueue: pr.mergeQueueEntry != nil
        case .conflicts: pr.mergeable == .conflicting || pr.mergeStateStatus == .dirty
        case .behind: pr.mergeStateStatus == .behind
        case .blocked: pr.mergeStateStatus == .blocked
        case .clean: pr.mergeStateStatus == .clean || pr.mergeStateStatus == .hasHooks
        case .autoMerge: pr.autoMergeEnabled
        }
    }
}

/// A group of conditions.
public struct FilterRule: Codable, Sendable, Equatable, Hashable {
    public enum Match: String, Codable, Sendable, CaseIterable {
        case all, any, none
    }

    public var match: Match
    public var conditions: [FilterCondition]

    public init(match: Match, _ conditions: [FilterCondition]) {
        self.match = match
        self.conditions = conditions
    }

    /// Three-valued evaluation: `nil` when the answer depends on check detail the PR
    /// doesn't have yet. An empty `all` group matches everything; an empty `any` nothing.
    public func evaluate(_ pr: PullRequest, viewer: String) -> Bool? {
        evaluate(pr, in: FilterContext(viewer: viewer))
    }

    public func evaluate(_ pr: PullRequest, in context: FilterContext) -> Bool? {
        let results = conditions.map { $0.evaluate(pr, in: context) }
        switch match {
        case .all:
            if results.contains(false) { return false }
            return results.contains(nil) ? nil : true
        case .any:
            if results.contains(true) { return true }
            return results.contains(nil) ? nil : false
        case .none:
            if results.contains(true) { return false }
            return results.contains(nil) ? nil : true
        }
    }

    /// True only when the PR certainly matches.
    public func matches(_ pr: PullRequest, viewer: String) -> Bool {
        evaluate(pr, viewer: viewer) == true
    }

    /// True unless the PR certainly doesn't match. Used to pick which PRs get check detail.
    public func mightMatch(_ pr: PullRequest, viewer: String) -> Bool {
        evaluate(pr, viewer: viewer) != false
    }

    public func matches(_ pr: PullRequest, in context: FilterContext) -> Bool {
        evaluate(pr, in: context) == true
    }

    public func mightMatch(_ pr: PullRequest, in context: FilterContext) -> Bool {
        evaluate(pr, in: context) != false
    }

    /// `author is me, or assignee is me`.
    public var summary: String {
        let parts = conditions.map(\.summary)
        switch match {
        case .all: return parts.joined(separator: ", and ")
        case .any: return parts.joined(separator: ", or ")
        case .none: return "none of (" + parts.joined(separator: "; ") + ")"
        }
    }
}

public indirect enum FilterCondition: Codable, Sendable, Equatable, Hashable {
    case predicate(Predicate)
    case group(FilterRule)

    public func evaluate(_ pr: PullRequest, viewer: String) -> Bool? {
        evaluate(pr, in: FilterContext(viewer: viewer))
    }

    public func evaluate(_ pr: PullRequest, in context: FilterContext) -> Bool? {
        switch self {
        case .predicate(let p): p.evaluate(pr, in: context)
        case .group(let g): g.evaluate(pr, in: context)
        }
    }

    public var summary: String {
        switch self {
        case .predicate(let p): p.summary
        case .group(let g): "(\(g.summary))"
        }
    }
}

// MARK: - Views

/// Events a view can notify about. CI finishing has one case per outcome.
public enum EventKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// CI passed, approved, nothing else will merge it: the PR is ready to merge.
    case ciReady
    /// CI passed but the PR is blocked (behind base, a guard check, branch protection).
    case ciBlocked
    /// CI failed. The event names the failing checks.
    case ciFailed
    /// CI passed and the PR still waits on something else, such as a review or the queue.
    case ciPassed
    case enteredMergeQueue
    case droppedFromMergeQueue
    case approved
    case changesRequested
    case reviewRequested
    /// A PR started matching this view.
    case newMatch

    public var title: String {
        switch self {
        case .ciReady: "CI finished: green and ready"
        case .ciBlocked: "CI finished: green but blocked"
        case .ciFailed: "CI finished: failed"
        case .ciPassed: "CI finished: green, still waiting"
        case .enteredMergeQueue: "Entered merge queue"
        case .droppedFromMergeQueue: "Dropped from merge queue"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequested: "Review requested from me"
        case .newMatch: "New PR in this view"
        }
    }
}

/// A named saved filter and the events it notifies about.
public struct SavedView: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    public var rule: FilterRule
    public var notify: Set<EventKind>
    public var pinnedToMenubar: Bool

    public init(
        id: UUID = UUID(), name: String, symbol: String = "line.3.horizontal.decrease.circle",
        rule: FilterRule, notify: Set<EventKind> = [], pinnedToMenubar: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.rule = rule
        self.notify = notify
        self.pinnedToMenubar = pinnedToMenubar
    }

    public func matches(_ pr: PullRequest, viewer: String) -> Bool { rule.matches(pr, viewer: viewer) }
    public func matches(_ pr: PullRequest, in context: FilterContext) -> Bool { rule.matches(pr, in: context) }
}

/// The four starter views. Fixed IDs so templates can be recognized after editing.
public enum BuiltInViews {
    public static let mineID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let needsMyReviewID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static let watchlistID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let agentPRsID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    /// Authored by me or assigned to me.
    public static let mine = SavedView(
        id: mineID, name: "Mine", symbol: "tray",
        rule: FilterRule(match: .any, [.predicate(.author(.me)), .predicate(.assignee(.me))]),
        notify: [.ciReady, .ciBlocked, .ciFailed, .droppedFromMergeQueue, .changesRequested, .approved],
        pinnedToMenubar: true
    )

    /// Review requested from me.
    public static let needsMyReview = SavedView(
        id: needsMyReviewID, name: "Needs my review", symbol: "eye",
        rule: FilterRule(match: .all, [.predicate(.reviewRequested(.me))]),
        notify: [.reviewRequested],
        pinnedToMenubar: true
    )

    /// Open, authored by any of `logins`, not a draft.
    public static func watchlist(_ logins: [String] = []) -> SavedView {
        SavedView(
            id: watchlistID, name: "Watchlist", symbol: "person.2",
            rule: FilterRule(match: .all, [.predicate(.author(.anyOf(logins))), .predicate(.isDraft(false))]),
            notify: [.newMatch]
        )
    }

    /// Authored by any of `agents` and assigned to me.
    public static func agentPRs(_ agents: [String] = []) -> SavedView {
        SavedView(
            id: agentPRsID, name: "Agent PRs", symbol: "sparkles",
            rule: FilterRule(match: .all, [.predicate(.author(.anyOf(agents))), .predicate(.assignee(.me))]),
            notify: [.ciReady, .ciBlocked, .ciFailed, .droppedFromMergeQueue]
        )
    }

    /// All four, in the order onboarding lists them.
    public static var all: [SavedView] { [mine, needsMyReview, agentPRs(), watchlist()] }

    /// The views a new install starts with when nothing else is chosen.
    public static var defaults: [SavedView] { [mine, needsMyReview] }
}
