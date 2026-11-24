import Foundation

/// The four lanes of the main window, in display order.
public enum Lane: String, Codable, Sendable, CaseIterable, Identifiable {
    case yourMove
    case ciRunning
    case inMergeQueue
    case waiting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .yourMove: "Your move"
        case .ciRunning: "CI running"
        case .inMergeQueue: "In merge queue"
        case .waiting: "Waiting on others"
        }
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

/// A PR's status, its lane for this viewer, and the two lines of text a row shows.
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

    public static let defaultGuardCheckPatterns = ["required-commit"]

    public init(
        now: Date = Date(), guardCheckPatterns: [String] = Self.defaultGuardCheckPatterns,
        queueDrops: [String: QueueDrop] = [:]
    ) {
        self.now = now
        self.guardCheckPatterns = guardCheckPatterns
        self.queueDrops = queueDrops
    }

    func isGuard(_ check: CheckRun) -> Bool {
        let name = check.name.lowercased()
        return guardCheckPatterns.contains { !$0.isEmpty && name.contains($0.lowercased()) }
    }
}

/// Turns a PR into a status, a lane, and a sentence.
///
/// "Owner" means the viewer authored the PR or is assigned to it, so an agent's PR
/// assigned to you is yours to shepherd. Rows are tried in order; the first match wins.
///
/// | #  | Condition                                                    | Status                         | Owner's lane   | Anyone else's lane |
/// |----|--------------------------------------------------------------|--------------------------------|----------------|--------------------|
/// | 1  | Draft                                                        | draft                          | waiting        | waiting            |
/// | 2  | Has a merge queue entry                                      | inMergeQueue                   | inMergeQueue   | inMergeQueue       |
/// | 3  | Dropped from the queue, same head commit as when it dropped  | droppedFromMergeQueue          | yourMove       | waiting            |
/// | 4  | Review requested from the viewer by name (viewer not author) | reviewRequestedFromYou         | yourMove       | yourMove           |
/// | 5  | Mergeable is CONFLICTING or merge state is DIRTY             | mergeConflicts                 | yourMove       | waiting            |
/// | 6  | A check other than a guard failed                            | ciFailed                       | yourMove       | waiting            |
/// | 7  | A check is still running                                     | ciRunning                      | ciRunning      | ciRunning          |
/// | 8  | Review decision is CHANGES_REQUESTED                         | changesRequested               | yourMove       | waiting            |
/// | 9  | Only guard checks failed                                     | greenBlocked(.requiredCheck)   | yourMove       | waiting            |
/// | 10 | Merge state is BEHIND                                        | greenBlocked(.behindBase)      | yourMove       | waiting            |
/// | 11 | Review decision is REVIEW_REQUIRED                           | waitingOnReview                | waiting        | waiting            |
/// | 12 | Merge state or mergeable is UNKNOWN                          | checkingMergeability           | waiting        | waiting            |
/// | 13 | Merge state is BLOCKED                                       | greenBlocked(.branchProtection)| yourMove       | waiting            |
/// | 14 | Otherwise (CLEAN, HAS_HOOKS, UNSTABLE)                       | readyToMerge                   | yourMove       | waiting            |
///
/// Rows 6, 7 and 9 need check detail for the current head commit. Without it they are
/// skipped, and GitHub's merge state decides.
public enum PRClassifier {
    public static func classify(_ pr: PullRequest, viewer: String, context: ClassificationContext = .init()) -> StatusInfo {
        let isOwner = pr.isAuthored(by: viewer) || pr.isAssigned(to: viewer)
        let ownerLane: Lane = isOwner ? .yourMove : .waiting
        let checks = pr.currentChecks
        let now = context.now

        // 1
        if pr.isDraft {
            return info(.draft, .waiting, "Draft", "Not ready for review yet")
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
                .inMergeQueue, headline, detail
            )
        }
        // 3
        if let drop = context.queueDrops[pr.id], drop.headSHA == pr.headSHA {
            var parts: [String] = []
            if let reason = drop.reason, !reason.isEmpty { parts.append(Formatting.humanize(reason).capitalizedFirst) }
            parts.append(Formatting.ago(drop.at, now: now))
            return info(.droppedFromMergeQueue(reason: drop.reason, at: drop.at), ownerLane, "Dropped from merge queue", parts.joined(separator: " · "))
        }
        // 4
        if pr.requestsReview(from: viewer), !pr.isAuthored(by: viewer) {
            let who = pr.author ?? "Someone"
            return info(.reviewRequestedFromYou(author: pr.author), .yourMove, "Review requested from you", "\(who) · \(Formatting.ago(pr.updatedAt, now: now))")
        }
        // 5
        if pr.mergeable == .conflicting || pr.mergeStateStatus == .dirty {
            return info(.mergeConflicts(base: pr.baseRef), ownerLane, "Merge conflicts with \(pr.baseRef)", "Resolve them so CI can run")
        }
        let failing = checks?.failing ?? []
        let realFailures = failing.filter { !context.isGuard($0) }
        // 6
        if let checks, !realFailures.isEmpty {
            let names = realFailures.map(\.name)
            let headline = names.count == 1
                ? "Check failed: \(names[0])"
                : "\(names.count) checks failed: \(Formatting.names(names, moreSuffix: ""))"
            return info(.ciFailed(failing: names, total: checks.checks.count), ownerLane, headline, finishedDetail(checks, now: now))
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
            return info(.changesRequested(by: by), ownerLane, headline, when.map { Formatting.ago($0, now: now).capitalizedFirst } ?? "")
        }
        // 9
        if !failing.isEmpty {
            let names = failing.map(\.name)
            return info(
                .greenBlocked(.requiredCheck(names: names)), ownerLane,
                "CI passed · blocked by \(Formatting.names(names, moreSuffix: ""))", "Needs a rebase onto \(pr.baseRef)"
            )
        }
        // 10
        if pr.mergeStateStatus == .behind {
            return info(.greenBlocked(.behindBase(base: pr.baseRef)), ownerLane, "CI passed · blocked: behind \(pr.baseRef)", "Update the branch; CI will run again")
        }
        // 11
        if pr.reviewDecision == .reviewRequired {
            let reviewers = pr.reviewRequests.map(\.displayName)
            let detail = reviewers.isEmpty ? "No reviewer requested yet" : Formatting.names(reviewers, limit: 3, moreSuffix: " more")
            return info(.waitingOnReview(reviewers: reviewers), .waiting, "Waiting on review", detail)
        }
        // 12
        if pr.mergeStateStatus == .unknown || pr.mergeable == .unknown {
            return info(.checkingMergeability, .waiting, "Checking mergeability", "GitHub is still working it out")
        }
        // 13
        if pr.mergeStateStatus == .blocked {
            return info(.greenBlocked(.branchProtection), ownerLane, "CI passed · blocked by branch protection", "A rule still blocks the merge")
        }
        // 14
        var parts: [String] = []
        if let checks, let done = checks.checks.compactMap(\.completedAt).max() {
            parts.append("CI passed \(Formatting.ago(done, now: now))")
        }
        if pr.reviewDecision == .approved { parts.append("approved") }
        parts.append(pr.autoMergeEnabled ? "auto-merge is on but hasn't merged it" : "no merge queue")
        return info(.readyToMerge(autoMerge: pr.autoMergeEnabled), ownerLane, "Ready to merge", parts.joined(separator: " · "))
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
