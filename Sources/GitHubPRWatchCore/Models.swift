import Foundation

/// The signed-in GitHub user.
public struct Viewer: Codable, Sendable, Equatable, Hashable {
    public var login: String
    public var name: String?
    public var avatarURL: URL?

    public init(login: String, name: String? = nil, avatarURL: URL? = nil) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// A repository the viewer can watch. Identified by `nameWithOwner`, such as `acme/web`.
public struct Repo: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var nameWithOwner: String
    public var isPrivate: Bool
    public var isFork: Bool
    public var pushedAt: Date?
    public var url: URL?
    public var hasMergeQueue: Bool

    public var id: String { nameWithOwner }
    public var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    public var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }

    public init(
        nameWithOwner: String, isPrivate: Bool = false, isFork: Bool = false,
        pushedAt: Date? = nil, url: URL? = nil, hasMergeQueue: Bool = false
    ) {
        self.nameWithOwner = nameWithOwner
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.pushedAt = pushedAt
        self.url = url
        self.hasMergeQueue = hasMergeQueue
    }
}

// MARK: - GitHub enums

/// `PullRequestReviewDecision` in GitHub's GraphQL schema.
public enum ReviewDecision: String, Codable, Sendable, Equatable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// `MergeableState`.
public enum Mergeable: String, Codable, Sendable, Equatable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// `MergeStateStatus`.
public enum MergeStateStatus: String, Codable, Sendable, Equatable {
    case behind = "BEHIND"
    case blocked = "BLOCKED"
    case clean = "CLEAN"
    case dirty = "DIRTY"
    case hasHooks = "HAS_HOOKS"
    case unknown = "UNKNOWN"
    case unstable = "UNSTABLE"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// `MergeQueueEntryState`.
public enum MergeQueueState: String, Codable, Sendable, Equatable {
    case queued = "QUEUED"
    case awaitingChecks = "AWAITING_CHECKS"
    case mergeable = "MERGEABLE"
    case unmergeable = "UNMERGEABLE"
    case locked = "LOCKED"
    case unknown = "UNKNOWN"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// `CheckStatusState`, plus the pending state of a commit status context.
public enum CheckStatus: String, Codable, Sendable, Equatable {
    case requested = "REQUESTED"
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case waiting = "WAITING"
    case pending = "PENDING"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
    }
}

/// `CheckConclusionState`.
public enum CheckConclusion: String, Codable, Sendable, Equatable {
    case actionRequired = "ACTION_REQUIRED"
    case timedOut = "TIMED_OUT"
    case cancelled = "CANCELLED"
    case failure = "FAILURE"
    case success = "SUCCESS"
    case neutral = "NEUTRAL"
    case skipped = "SKIPPED"
    case startupFailure = "STARTUP_FAILURE"
    case stale = "STALE"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .neutral
    }

    /// Conclusions that block a merge. Cancelled counts: a cancelled required run never passes.
    public var isFailing: Bool {
        switch self {
        case .actionRequired, .timedOut, .cancelled, .failure, .startupFailure: true
        case .success, .neutral, .skipped, .stale: false
        }
    }
}

/// `StatusState`, the commit's combined rollup.
public enum RollupState: String, Codable, Sendable, Equatable {
    case expected = "EXPECTED"
    case error = "ERROR"
    case failure = "FAILURE"
    case pending = "PENDING"
    case success = "SUCCESS"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
    }
}

// MARK: - Pull requests

/// A requested reviewer: a user (or bot) by login, or a team as `org/slug`.
public enum ReviewRequest: Codable, Sendable, Equatable, Hashable {
    case user(String)
    case team(String)

    public var userLogin: String? {
        if case .user(let login) = self { login } else { nil }
    }

    public var displayName: String {
        switch self {
        case .user(let login): login
        case .team(let slug): slug
        }
    }
}

/// One reviewer's latest review.
public struct Review: Codable, Sendable, Equatable, Hashable {
    public enum State: String, Codable, Sendable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case commented = "COMMENTED"
        case dismissed = "DISMISSED"
        case pending = "PENDING"

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .commented
        }
    }

    public var author: String
    public var state: State
    public var submittedAt: Date?

    public init(author: String, state: State, submittedAt: Date? = nil) {
        self.author = author
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// The PR's entry in its base branch's merge queue.
public struct MergeQueueEntry: Codable, Sendable, Equatable, Hashable {
    /// Zero-based in GitHub's API. Use `displayPosition` for people.
    public var position: Int
    public var state: MergeQueueState
    public var enqueuedAt: Date?
    /// Seconds, as GitHub estimates it.
    public var estimatedTimeToMerge: Int?
    /// How many PRs the queue holds, when GitHub says.
    public var queueLength: Int?

    public var displayPosition: Int { position + 1 }

    public init(
        position: Int, state: MergeQueueState = .queued, enqueuedAt: Date? = nil,
        estimatedTimeToMerge: Int? = nil, queueLength: Int? = nil
    ) {
        self.position = position
        self.state = state
        self.enqueuedAt = enqueuedAt
        self.estimatedTimeToMerge = estimatedTimeToMerge
        self.queueLength = queueLength
    }
}

/// One check run (GitHub Actions and Checks API) or commit status context.
public struct CheckRun: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case checkRun, statusContext }

    public var name: String
    public var kind: Kind
    public var status: CheckStatus
    public var conclusion: CheckConclusion?
    public var startedAt: Date?
    public var completedAt: Date?
    public var detailsURL: URL?
    public var isRequired: Bool
    public var workflowName: String?

    public init(
        name: String, kind: Kind = .checkRun, status: CheckStatus, conclusion: CheckConclusion? = nil,
        startedAt: Date? = nil, completedAt: Date? = nil, detailsURL: URL? = nil,
        isRequired: Bool = false, workflowName: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.detailsURL = detailsURL
        self.isRequired = isRequired
        self.workflowName = workflowName
    }

    public var isRunning: Bool { status != .completed }
    public var isFailing: Bool { status == .completed && (conclusion?.isFailing ?? false) }
}

/// Why GitHub last removed the PR from its merge queue, from the timeline.
public struct MergeQueueRemoval: Codable, Sendable, Equatable, Hashable {
    public var reason: String?
    public var at: Date?

    public init(reason: String?, at: Date?) {
        self.reason = reason
        self.at = at
    }
}

/// The detail fetched in the second, heavier query, only for PRs that match a view.
public struct CheckSummary: Codable, Sendable, Equatable, Hashable {
    /// The commit the checks ran on. Detail for an older head is ignored.
    public var headSHA: String
    public var rollup: RollupState?
    public var checks: [CheckRun]
    public var lastQueueRemoval: MergeQueueRemoval?

    public init(headSHA: String, rollup: RollupState?, checks: [CheckRun], lastQueueRemoval: MergeQueueRemoval? = nil) {
        self.headSHA = headSHA
        self.rollup = rollup
        self.checks = checks
        self.lastQueueRemoval = lastQueueRemoval
    }

    public var running: [CheckRun] { checks.filter(\.isRunning) }
    public var failing: [CheckRun] { checks.filter(\.isFailing) }
}

/// An open pull request. The light query fills everything but `checks`;
/// the check-detail query fills `checks` for PRs that match a view.
public struct PullRequest: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// GitHub's global node ID. Stable for the PR's life.
    public var id: String
    public var repo: String
    public var number: Int
    public var title: String
    public var url: URL
    public var isDraft: Bool
    public var author: String?
    public var assignees: [String]
    public var reviewRequests: [ReviewRequest]
    public var latestReviews: [Review]
    public var labels: [String]
    public var reviewDecision: ReviewDecision?
    public var mergeable: Mergeable
    public var mergeStateStatus: MergeStateStatus
    public var autoMergeEnabled: Bool
    public var mergeQueueEntry: MergeQueueEntry?
    public var headSHA: String
    public var baseRef: String
    public var createdAt: Date
    public var updatedAt: Date
    public var checks: CheckSummary?

    public init(
        id: String, repo: String, number: Int, title: String, url: URL? = nil, isDraft: Bool = false,
        author: String?, assignees: [String] = [], reviewRequests: [ReviewRequest] = [],
        latestReviews: [Review] = [], labels: [String] = [], reviewDecision: ReviewDecision? = nil,
        mergeable: Mergeable = .mergeable, mergeStateStatus: MergeStateStatus = .clean,
        autoMergeEnabled: Bool = false, mergeQueueEntry: MergeQueueEntry? = nil,
        headSHA: String = "0000000", baseRef: String = "main",
        createdAt: Date = Date(timeIntervalSince1970: 0), updatedAt: Date = Date(timeIntervalSince1970: 0),
        checks: CheckSummary? = nil
    ) {
        self.id = id
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url ?? URL(string: "https://github.com/\(repo)/pull/\(number)")!
        self.isDraft = isDraft
        self.author = author
        self.assignees = assignees
        self.reviewRequests = reviewRequests
        self.latestReviews = latestReviews
        self.labels = labels
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.autoMergeEnabled = autoMergeEnabled
        self.mergeQueueEntry = mergeQueueEntry
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.checks = checks
    }

    /// `web #4821`: the repo's name without the owner, as the design writes it.
    public var shortRef: String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo) #\(number)"
    }

    /// `acme/web #4821`.
    public var fullRef: String { "\(repo) #\(number)" }

    /// The check detail, when it belongs to the current head commit.
    public var currentChecks: CheckSummary? {
        guard let checks, checks.headSHA == headSHA else { return nil }
        return checks
    }

    public func isAuthored(by login: String) -> Bool {
        author?.caseInsensitiveCompare(login) == .orderedSame
    }

    public func isAssigned(to login: String) -> Bool {
        assignees.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    public func requestsReview(from login: String) -> Bool {
        reviewRequests.contains { $0.userLogin?.caseInsensitiveCompare(login) == .orderedSame }
    }

    /// Requested from `login` by name, or from one of `teams` (lowercased `org/slug`).
    public func requestsReview(from login: String, orTeams teams: Set<String>) -> Bool {
        reviewRequests.contains { request in
            switch request {
            case .user(let user): user.caseInsensitiveCompare(login) == .orderedSame
            case .team(let team): teams.contains(team.lowercased())
            }
        }
    }
}

/// GitHub's GraphQL point budget, read from `rateLimit` on every query.
public struct RateLimit: Codable, Sendable, Equatable {
    public var limit: Int
    public var cost: Int
    public var remaining: Int
    public var resetAt: Date

    public init(limit: Int = 5000, cost: Int, remaining: Int, resetAt: Date) {
        self.limit = limit
        self.cost = cost
        self.remaining = remaining
        self.resetAt = resetAt
    }
}
