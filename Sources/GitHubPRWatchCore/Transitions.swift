import Foundation

/// What the detector remembers between polls. Persisted, so a relaunch compares against
/// the last state it saw instead of notifying about everything again.
public struct TransitionSnapshot: Codable, Sendable, Equatable {
    public var takenAt: Date
    public var viewer: String
    /// Open PRs by ID, as last seen.
    public var pullRequests: [String: PullRequest]
    /// PR IDs that matched each view, by view ID string.
    public var viewMembers: [String: Set<String>]
    /// Each view's rule when membership was recorded. A view whose rule changed starts over
    /// without "new PR" events, so editing a view doesn't fire a burst of them.
    public var viewRules: [String: FilterRule]
    /// PRs that left their merge queue while still open, by PR ID.
    public var queueDrops: [String: QueueDrop]

    public init(
        takenAt: Date, viewer: String, pullRequests: [String: PullRequest] = [:],
        viewMembers: [String: Set<String>] = [:], viewRules: [String: FilterRule] = [:],
        queueDrops: [String: QueueDrop] = [:]
    ) {
        self.takenAt = takenAt
        self.viewer = viewer
        self.pullRequests = pullRequests
        self.viewMembers = viewMembers
        self.viewRules = viewRules
        self.queueDrops = queueDrops
    }
}

/// The facts a notification needs beyond the PR itself.
public struct EventDetail: Codable, Sendable, Equatable, Hashable {
    public var failingChecks: [String]
    public var totalChecks: Int?
    /// How long CI ran, first start to last finish.
    public var ciDuration: TimeInterval?
    public var blockReason: BlockReason?
    /// One-based.
    public var queuePosition: Int?
    public var queueLength: Int?
    /// Why the PR left the merge queue, as GitHub states it.
    public var reason: String?
    /// The reviewer, approver, or the author who asked for review.
    public var actor: String?

    public init(
        failingChecks: [String] = [], totalChecks: Int? = nil, ciDuration: TimeInterval? = nil,
        blockReason: BlockReason? = nil, queuePosition: Int? = nil, queueLength: Int? = nil,
        reason: String? = nil, actor: String? = nil
    ) {
        self.failingChecks = failingChecks
        self.totalChecks = totalChecks
        self.ciDuration = ciDuration
        self.blockReason = blockReason
        self.queuePosition = queuePosition
        self.queueLength = queueLength
        self.reason = reason
        self.actor = actor
    }
}

/// A transition worth telling the user about, attributed to the view whose rule fired.
public struct PREvent: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var kind: EventKind
    /// The PR as it is now.
    public var pr: PullRequest
    public var viewID: UUID
    public var viewName: String
    public var occurredAt: Date
    public var detail: EventDetail

    public init(kind: EventKind, pr: PullRequest, viewID: UUID, viewName: String, occurredAt: Date, detail: EventDetail = .init()) {
        self.id = "\(pr.id)|\(kind.rawValue)|\(viewID.uuidString)|\(pr.headSHA)|\(Int(occurredAt.timeIntervalSince1970))"
        self.kind = kind
        self.pr = pr
        self.viewID = viewID
        self.viewName = viewName
        self.occurredAt = occurredAt
        self.detail = detail
    }
}

/// Compares two snapshots of the open PRs and returns the events between them.
///
/// Rules:
/// - No previous snapshot (first fetch after sign-in), a snapshot for another viewer, or one
///   older than `maxSnapshotAge` sets a baseline and emits nothing.
/// - Only PRs present in both snapshots can transition. A PR missing from `current` merged,
///   closed, or left the watched repos; it emits nothing, and in particular never
///   "dropped from merge queue". The caller must pass PRs from repos that failed to fetch
///   through unchanged, so they don't look closed.
/// - Each PR event goes to the first view (in the given order) that the PR matches now and
///   whose rules include the event. `newMatch` goes to every view that gained the PR.
/// - CI "finished" means: the current head has check detail, at least one check, and none
///   running; and the previous poll had check detail with a check running on the same head,
///   or had detail for a different head. A re-run on the same head notifies again.
public struct TransitionDetector: Sendable {
    public var guardCheckPatterns: [String]
    public var maxSnapshotAge: TimeInterval

    public init(
        guardCheckPatterns: [String] = ClassificationContext.defaultGuardCheckPatterns,
        maxSnapshotAge: TimeInterval = 6 * 3600
    ) {
        self.guardCheckPatterns = guardCheckPatterns
        self.maxSnapshotAge = maxSnapshotAge
    }

    public func detect(
        previous: TransitionSnapshot?, current: [PullRequest], viewer: String, views: [SavedView], now: Date
    ) -> (events: [PREvent], snapshot: TransitionSnapshot) {
        var snapshot = TransitionSnapshot(takenAt: now, viewer: viewer)
        for pr in current { snapshot.pullRequests[pr.id] = pr }
        var members: [UUID: Set<String>] = [:]
        for view in views {
            let ids = Set(current.filter { view.matches($0, viewer: viewer) }.map(\.id))
            members[view.id] = ids
            snapshot.viewMembers[view.id.uuidString] = ids
            snapshot.viewRules[view.id.uuidString] = view.rule
        }

        guard let previous, previous.viewer.caseInsensitiveCompare(viewer) == .orderedSame,
              now.timeIntervalSince(previous.takenAt) <= maxSnapshotAge
        else {
            return ([], snapshot)
        }

        // Carry queue drops forward while the PR is open, out of the queue, on the same head.
        for (id, drop) in previous.queueDrops {
            if let pr = snapshot.pullRequests[id], pr.mergeQueueEntry == nil, pr.headSHA == drop.headSHA {
                snapshot.queueDrops[id] = drop
            }
        }

        var events: [PREvent] = []
        for pr in current {
            let candidates = transitions(from: previous.pullRequests[pr.id], to: pr, viewer: viewer, now: now, snapshot: &snapshot)
            for (kind, detail) in candidates {
                guard let view = views.first(where: { $0.notify.contains(kind) && members[$0.id]?.contains(pr.id) == true }) else { continue }
                events.append(PREvent(kind: kind, pr: pr, viewID: view.id, viewName: view.name, occurredAt: now, detail: detail))
            }
        }

        for view in views where view.notify.contains(.newMatch) {
            let key = view.id.uuidString
            guard let before = previous.viewMembers[key], previous.viewRules[key] == view.rule else { continue }
            let gained = (members[view.id] ?? []).subtracting(before)
            for pr in current where gained.contains(pr.id) {
                events.append(PREvent(kind: .newMatch, pr: pr, viewID: view.id, viewName: view.name, occurredAt: now, detail: EventDetail(actor: pr.author)))
            }
        }
        return (events, snapshot)
    }

    /// The event kinds one PR went through between two polls.
    private func transitions(
        from old: PullRequest?, to pr: PullRequest, viewer: String, now: Date, snapshot: inout TransitionSnapshot
    ) -> [(EventKind, EventDetail)] {
        guard let old else {
            // A PR that just opened: only a review request from me is worth a banner here;
            // "new PR in this view" comes from view membership.
            return pr.requestsReview(from: viewer) && !pr.isAuthored(by: viewer)
                ? [(.reviewRequested, EventDetail(actor: pr.author))] : []
        }
        var result: [(EventKind, EventDetail)] = []

        // Merge queue.
        if old.mergeQueueEntry == nil, let entry = pr.mergeQueueEntry {
            snapshot.queueDrops[pr.id] = nil
            result.append((.enteredMergeQueue, EventDetail(queuePosition: entry.displayPosition, queueLength: entry.queueLength)))
        }
        if let entry = old.mergeQueueEntry, pr.mergeQueueEntry == nil {
            let reason = pr.checks?.lastQueueRemoval?.reason
            snapshot.queueDrops[pr.id] = QueueDrop(at: now, headSHA: pr.headSHA, position: entry.displayPosition, reason: reason)
            result.append((.droppedFromMergeQueue, EventDetail(queuePosition: entry.displayPosition, queueLength: entry.queueLength, reason: reason)))
        }

        // CI finished.
        if let checks = pr.currentChecks, !checks.checks.isEmpty, checks.running.isEmpty, let oldChecks = old.checks {
            let wasRunning = old.currentChecks.map { !$0.running.isEmpty } ?? false
            let newHead = oldChecks.headSHA != pr.headSHA || old.headSHA != pr.headSHA
            if wasRunning || newHead {
                result.append(ciOutcome(pr, checks: checks, viewer: viewer, now: now, snapshot: snapshot))
            }
        }

        // Reviews.
        if old.reviewDecision != .approved, pr.reviewDecision == .approved {
            let approvers = pr.latestReviews.filter { $0.state == .approved }.map(\.author)
            result.append((.approved, EventDetail(actor: approvers.last)))
        }
        let oldChangeRequesters = Set(old.latestReviews.filter { $0.state == .changesRequested }.map { $0.author.lowercased() })
        let newChangeRequesters = pr.latestReviews.filter { $0.state == .changesRequested && !oldChangeRequesters.contains($0.author.lowercased()) }
        if let reviewer = newChangeRequesters.first {
            result.append((.changesRequested, EventDetail(actor: reviewer.author)))
        } else if old.reviewDecision != .changesRequested, pr.reviewDecision == .changesRequested {
            result.append((.changesRequested, EventDetail()))
        }
        if pr.requestsReview(from: viewer), !old.requestsReview(from: viewer), !pr.isAuthored(by: viewer) {
            result.append((.reviewRequested, EventDetail(actor: pr.author)))
        }
        return result
    }

    private func ciOutcome(
        _ pr: PullRequest, checks: CheckSummary, viewer: String, now: Date, snapshot: TransitionSnapshot
    ) -> (EventKind, EventDetail) {
        let context = ClassificationContext(now: now, guardCheckPatterns: guardCheckPatterns, queueDrops: snapshot.queueDrops)
        let start = checks.checks.compactMap(\.startedAt).min()
        let end = checks.checks.compactMap(\.completedAt).max()
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }
        let realFailures = checks.failing.filter { !context.isGuard($0) }
        var detail = EventDetail(totalChecks: checks.checks.count, ciDuration: duration)
        if !realFailures.isEmpty {
            detail.failingChecks = realFailures.map(\.name)
            return (.ciFailed, detail)
        }
        let status = PRClassifier.classify(pr, viewer: viewer, context: context).status
        switch status {
        case .readyToMerge:
            return (.ciReady, detail)
        case .greenBlocked(let reason):
            detail.blockReason = reason
            detail.failingChecks = checks.failing.map(\.name)
            return (.ciBlocked, detail)
        default:
            return (.ciPassed, detail)
        }
    }
}
