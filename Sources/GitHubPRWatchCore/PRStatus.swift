import Foundation

/// The five lanes of the main window, in pipeline order. A lane is a fact GitHub reports
/// about the PR, the same for every viewer.
public enum Lane: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Checks are in progress.
    case ciRunning
    /// Something must change before it can merge: a failed check, merge conflicts, behind
    /// its base, a guard check, branch protection, or a drop from the merge queue.
    case failing
    /// Checks passed (or there are none) and it waits on a review, or changes were requested.
    /// Drafts sit here too, in a collapsed group.
    case inReview
    /// Checks passed, approved, nothing blocks the merge.
    case readyToMerge
    /// In a merge queue.
    case mergeQueue

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ciRunning: "CI running"
        case .failing: "Failing"
        case .inReview: "In review"
        case .readyToMerge: "Ready to merge"
        case .mergeQueue: "Merge queue"
        }
    }

    /// A lane name, including one saved by an older build, mapped to the nearest lane today.
    /// `nil` for a name with no equivalent, such as the old first lane, which depended on who
    /// was looking. See `LegacyLaneMigration`.
    public static func migrating(_ raw: String) -> Lane? {
        switch raw {
        case "inMergeQueue": .mergeQueue
        case "waiting": .inReview
        default: Lane(rawValue: raw)
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let lane = Self.migrating(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown lane \(raw)"))
        }
        self = lane
    }
}

/// Why a PR whose CI passed still can't merge.
public enum BlockReason: Codable, Sendable, Equatable, Hashable {
    /// The branch is behind its base and branch protection wants it updated.
    case behindBase(base: String)
    /// A required guard check failed, such as one that demands a recent rebase.
    case requiredCheck(names: [String])
    /// Branch protection blocks the merge for a reason GitHub doesn't name.
    case branchProtection
}

/// A record that the PR left its merge queue while still open. Kept by the transition
/// detector so the status can say "Dropped from merge queue" until something changes.
public struct QueueDrop: Codable, Sendable, Equatable, Hashable {
    public var at: Date
    public var headSHA: String
    /// One-based position when it was last seen in the queue.
    public var position: Int?
    public var reason: String?

    public init(at: Date, headSHA: String, position: Int? = nil, reason: String? = nil) {
        self.at = at
        self.headSHA = headSHA
        self.position = position
        self.reason = reason
    }
}

/// Every state a PR row can show. One symbol and one sentence per case.
public enum PRStatus: Codable, Sendable, Equatable, Hashable {
    case draft
    /// `position` is one-based.
    case inMergeQueue(position: Int, of: Int?, state: MergeQueueState, estimatedSeconds: Int?)
    case droppedFromMergeQueue(reason: String?, at: Date?)
    case reviewRequestedFromYou(author: String?)
    case mergeConflicts(base: String)
    case ciFailed(failing: [String], total: Int)
    case ciRunning(elapsed: TimeInterval?, finished: Int, total: Int)
    case changesRequested(by: [String])
    case greenBlocked(BlockReason)
    case waitingOnReview(reviewers: [String])
    case checkingMergeability
    case readyToMerge(autoMerge: Bool)

    /// A stable name for the case, for tests, filters and styling.
    public var kind: Kind {
        switch self {
        case .draft: .draft
        case .inMergeQueue: .inMergeQueue
        case .droppedFromMergeQueue: .droppedFromMergeQueue
        case .reviewRequestedFromYou: .reviewRequestedFromYou
        case .mergeConflicts: .mergeConflicts
        case .ciFailed: .ciFailed
        case .ciRunning: .ciRunning
        case .changesRequested: .changesRequested
        case .greenBlocked(.behindBase): .blockedBehindBase
        case .greenBlocked(.requiredCheck): .blockedByRequiredCheck
        case .greenBlocked(.branchProtection): .blockedByBranchProtection
        case .waitingOnReview: .waitingOnReview
        case .checkingMergeability: .checkingMergeability
        case .readyToMerge: .readyToMerge
        }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case draft, inMergeQueue, droppedFromMergeQueue, reviewRequestedFromYou, mergeConflicts
        case ciFailed, ciRunning, changesRequested, blockedBehindBase, blockedByRequiredCheck
        case blockedByBranchProtection, waitingOnReview, checkingMergeability, readyToMerge
    }
}

/// A PR's status, its lane, and the two lines of text a row shows.
public struct StatusInfo: Codable, Sendable, Equatable, Hashable {
    public var status: PRStatus
    public var lane: Lane
    /// The first status line: the fact you act on, such as `2 checks failed: e2e-chrome, lint`.
    public var headline: String
    /// The second line: when, who, or why, such as `Finished 2m ago · ran 34m`.
    public var detail: String

    /// The whole plain-language sentence.
    public var sentence: String { detail.isEmpty ? headline : "\(headline). \(detail)." }
}

/// A PR together with its classification, as the UI shows it.
public struct ClassifiedPR: Sendable, Equatable, Hashable, Identifiable {
    public var pr: PullRequest
    public var info: StatusInfo

    public var id: String { pr.id }

    public init(pr: PullRequest, info: StatusInfo) {
        self.pr = pr
        self.info = info
    }
}

/// What the classifier needs besides the PR and the viewer.
public struct ClassificationContext: Sendable {
    public var now: Date
    /// Case-insensitive substrings of check names that act as guards: when one of them
    /// fails and nothing else does, CI counts as passed and the PR as blocked.
    public var guardCheckPatterns: [String]
    /// Merge queue drops the transition detector has seen, by PR ID.
    public var queueDrops: [String: QueueDrop]
    /// The viewer's teams as lowercased `org/slug`. A review requested from one of them
    /// counts as requested from the viewer. Empty when the token can't read teams.
    public var viewerTeams: Set<String>

    public static let defaultGuardCheckPatterns = ["required-commit"]

    public init(
        now: Date = Date(), guardCheckPatterns: [String] = Self.defaultGuardCheckPatterns,
        queueDrops: [String: QueueDrop] = [:], viewerTeams: Set<String> = []
    ) {
        self.now = now
        self.guardCheckPatterns = guardCheckPatterns
        self.queueDrops = queueDrops
        self.viewerTeams = Set(viewerTeams.map { $0.lowercased() })
    }

    func isGuard(_ check: CheckRun) -> Bool {
        let name = check.name.lowercased()
        return guardCheckPatterns.contains { !$0.isEmpty && name.contains($0.lowercased()) }
    }
}

/// Turns a PR into a status, a lane, and a sentence.
///
/// The status is what the card says. The lane is the lane of that status, so a card always
/// sits in the lane its sentence describes. Rows are tried in order; the first match wins.
///
/// | #  | Condition                                                         | Status                          | Lane            |
/// |----|-------------------------------------------------------------------|---------------------------------|-----------------|
/// | 1  | Draft                                                             | draft                           | inReview (Drafts group) |
/// | 2  | Has a merge queue entry                                           | inMergeQueue                    | mergeQueue      |
/// | 3  | Dropped from the queue, same head commit as when it dropped       | droppedFromMergeQueue           | failing         |
/// | 4  | Review requested from the viewer or a team of theirs (not author) | reviewRequestedFromYou          | the lane rows 5–14 give |
/// | 5  | Mergeable is CONFLICTING or merge state is DIRTY                  | mergeConflicts                  | failing         |
/// | 6  | A check other than a guard failed                                 | ciFailed                        | failing         |
/// | 7  | A check is still running                                          | ciRunning                       | ciRunning       |
/// | 8  | Review decision is CHANGES_REQUESTED                              | changesRequested                | inReview        |
/// | 9  | Only guard checks failed                                          | greenBlocked(.requiredCheck)    | failing         |
/// | 10 | Merge state is BEHIND                                             | greenBlocked(.behindBase)       | failing         |
/// | 11 | Review decision is REVIEW_REQUIRED                                | waitingOnReview                 | inReview        |
/// | 12 | Merge state or mergeable is UNKNOWN                               | checkingMergeability            | inReview        |
/// | 13 | Merge state is BLOCKED                                            | greenBlocked(.branchProtection) | failing         |
/// | 14 | Otherwise (CLEAN, HAS_HOOKS, UNSTABLE)                            | readyToMerge                    | readyToMerge    |
///
/// So when a PR fits two lanes: merge queue, then a hard failure (dropped from the queue,
/// conflicts, a failed check, which GitHub's own rollup already reports as failed while other
/// checks run), then CI running, then changes requested, then a soft block (a guard check,
/// behind base), then waiting on review, then branch protection, then ready to merge.
///
/// Row 4 is the only one that depends on who is looking, and it changes only the card's
/// sentence: the lane never depends on the viewer. `classify(_:context:)` skips it.
///
/// Rows 6, 7 and 9 need check detail for the current head commit. Without it they are
/// skipped, and GitHub's merge state decides.
public enum PRClassifier {
    /// The status and lane as GitHub reports them, then row 4 for this viewer.
    public static func classify(_ pr: PullRequest, viewer: String, context: ClassificationContext = .init()) -> StatusInfo {
        let base = classify(pr, context: context)
        switch base.status.kind {
        case .draft, .inMergeQueue, .droppedFromMergeQueue:
            return base
        default:
            break
        }
        // 4
        if pr.requestsReview(from: viewer, orTeams: context.viewerTeams), !pr.isAuthored(by: viewer) {
            let who = pr.author ?? "Someone"
            return info(
                .reviewRequestedFromYou(author: pr.author), base.lane,
                "Review requested from you", "\(who) · \(Formatting.ago(pr.updatedAt, now: context.now))"
            )
        }
        return base
    }

    /// The status and lane without a viewer: every row but 4.
    public static func classify(_ pr: PullRequest, context: ClassificationContext = .init()) -> StatusInfo {
        let checks = pr.currentChecks
        let now = context.now

        // 1
        if pr.isDraft {
            return info(.draft, .inReview, "Draft", "Not ready for review yet")
        }
        // 2
        if let entry = pr.mergeQueueEntry {
            let position = entry.displayPosition
            let headline = entry.queueLength.map { "In merge queue · \(position) of \($0)" }
                ?? "In merge queue · position \(position)"
            let detail: String = switch entry.state {
            case .unmergeable: "Queue checks are failing"
            case .awaitingChecks: entry.estimatedTimeToMerge.map { "Merging in ~\(Formatting.duration(TimeInterval($0)))" } ?? "Waiting for queue checks"
            case .locked: "The queue is locked"
            default: entry.estimatedTimeToMerge.map { "Merging in ~\(Formatting.duration(TimeInterval($0)))" } ?? "Queued"
            }
            return info(
                .inMergeQueue(position: position, of: entry.queueLength, state: entry.state, estimatedSeconds: entry.estimatedTimeToMerge),
                .mergeQueue, headline, detail
            )
        }
        // 3
        if let drop = context.queueDrops[pr.id], drop.headSHA == pr.headSHA {
            var parts: [String] = []
            if let reason = drop.reason, !reason.isEmpty { parts.append(Formatting.humanize(reason).capitalizedFirst) }
            parts.append(Formatting.ago(drop.at, now: now))
            return info(.droppedFromMergeQueue(reason: drop.reason, at: drop.at), .failing, "Dropped from merge queue", parts.joined(separator: " · "))
        }
        // 5
        if pr.mergeable == .conflicting || pr.mergeStateStatus == .dirty {
            return info(.mergeConflicts(base: pr.baseRef), .failing, "Merge conflicts with \(pr.baseRef)", "Resolve them so CI can run")
        }
        let failing = checks?.failing ?? []
        let realFailures = failing.filter { !context.isGuard($0) }
        // 6
        if let checks, !realFailures.isEmpty {
            let names = realFailures.map(\.name)
            let headline = names.count == 1
                ? "Check failed: \(names[0])"
                : "\(names.count) checks failed: \(Formatting.names(names, moreSuffix: ""))"
            return info(.ciFailed(failing: names, total: checks.checks.count), .failing, headline, finishedDetail(checks, now: now))
        }
        // 7
        if let checks, !checks.running.isEmpty {
            let elapsed = earliestStart(checks).map { now.timeIntervalSince($0) }
            let total = checks.checks.count
            let finished = total - checks.running.count
            let headline = elapsed.map { "CI running · \(Formatting.duration($0))" } ?? "CI queued"
            return info(.ciRunning(elapsed: elapsed, finished: finished, total: total), .ciRunning, headline, "\(finished) of \(total) checks done")
        }
        // 8
        if pr.reviewDecision == .changesRequested {
            let by = pr.latestReviews.filter { $0.state == .changesRequested }.map(\.author)
            let headline = by.isEmpty ? "Changes requested" : "Changes requested by \(Formatting.names(by, moreSuffix: ""))"
            let when = pr.latestReviews.filter { $0.state == .changesRequested }.compactMap(\.submittedAt).max()
            return info(.changesRequested(by: by), .inReview, headline, when.map { Formatting.ago($0, now: now).capitalizedFirst } ?? "")
        }
        // 9
        if !failing.isEmpty {
            let names = failing.map(\.name)
            return info(
                .greenBlocked(.requiredCheck(names: names)), .failing,
                "CI passed · blocked by \(Formatting.names(names, moreSuffix: ""))", "Needs a rebase onto \(pr.baseRef)"
            )
        }
        // 10
        if pr.mergeStateStatus == .behind {
            return info(.greenBlocked(.behindBase(base: pr.baseRef)), .failing, "CI passed · blocked: behind \(pr.baseRef)", "Update the branch; CI will run again")
        }
        // 11
        if pr.reviewDecision == .reviewRequired {
            let reviewers = pr.reviewRequests.map(\.displayName)
            let detail = reviewers.isEmpty ? "No reviewer requested yet" : Formatting.names(reviewers, limit: 3, moreSuffix: " more")
            return info(.waitingOnReview(reviewers: reviewers), .inReview, "Waiting on review", detail)
        }
        // 12
        if pr.mergeStateStatus == .unknown || pr.mergeable == .unknown {
            return info(.checkingMergeability, .inReview, "Checking mergeability", "GitHub is still working it out")
        }
        // 13
        if pr.mergeStateStatus == .blocked {
            return info(.greenBlocked(.branchProtection), .failing, "CI passed · blocked by branch protection", "A rule still blocks the merge")
        }
        // 14
        var parts: [String] = []
        if let checks, let done = checks.checks.compactMap(\.completedAt).max() {
            parts.append("CI passed \(Formatting.ago(done, now: now))")
        }
        if pr.reviewDecision == .approved { parts.append("approved") }
        parts.append(pr.autoMergeEnabled ? "auto-merge is on but hasn't merged it" : "no merge queue")
        return info(.readyToMerge(autoMerge: pr.autoMergeEnabled), .readyToMerge, "Ready to merge", parts.joined(separator: " · "))
    }

    /// Classifies a list of PRs.
    public static func classify(_ prs: [PullRequest], viewer: String, context: ClassificationContext) -> [ClassifiedPR] {
        prs.map { ClassifiedPR(pr: $0, info: classify($0, viewer: viewer, context: context)) }
    }

    private static func info(_ status: PRStatus, _ lane: Lane, _ headline: String, _ detail: String) -> StatusInfo {
        StatusInfo(status: status, lane: lane, headline: headline, detail: detail)
    }

    static func earliestStart(_ checks: CheckSummary) -> Date? {
        checks.checks.compactMap(\.startedAt).min()
    }

    /// `Finished 2m ago · ran 34m`.
    static func finishedDetail(_ checks: CheckSummary, now: Date) -> String {
        guard let end = checks.checks.compactMap(\.completedAt).max() else { return "" }
        var text = "Finished \(Formatting.ago(end, now: now))"
        if let start = earliestStart(checks) {
            text += " · ran \(Formatting.duration(end.timeIntervalSince(start)))"
        }
        return text
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
