import Foundation

/// Failures the UI tells apart.
public enum GitHubError: Error, Equatable, Sendable {
    /// 401: the token was revoked, expired, or `gh` logged out.
    case unauthorized
    /// The hourly point budget ran out. Wait until `resetAt`.
    case rateLimited(resetAt: Date?)
    /// GitHub's abuse protection. Wait `retryAfter` seconds, or back off when it isn't given.
    case secondaryRateLimit(retryAfter: TimeInterval?)
    /// No network, DNS failure, or a timeout.
    case offline
    case http(status: Int)
    case graphQL(messages: [String])
    case decoding(String)
    case auth(AuthError)
}

/// The result of fetching open PRs for several repos.
public struct OpenPullRequests: Sendable, Equatable {
    public var pullRequests: [PullRequest]
    /// Repos that couldn't be read (deleted, renamed, access lost). The others still count.
    public var failedRepos: [String]

    public init(pullRequests: [PullRequest], failedRepos: [String] = []) {
        self.pullRequests = pullRequests
        self.failedRepos = failedRepos
    }
}

/// What `PRStore` needs from GitHub. `GitHubClient` is the real one.
public protocol GitHubAPI: Sendable {
    func viewer() async throws -> Viewer
    /// Repos for the onboarding picker, most recently pushed first.
    func repositories() async throws -> [Repo]
    /// Step one of a poll: every open PR in the repos, without check detail.
    func openPullRequests(in repos: [String]) async throws -> OpenPullRequests
    /// Step two: check detail by PR ID, only for PRs that match at least one view.
    func checkDetails(for prs: [PullRequest]) async throws -> [String: CheckSummary]
    /// The budget after the most recent query.
    func latestRateLimit() async -> RateLimit?
}

/// GitHub's GraphQL API over an injectable transport.
public actor GitHubClient: GitHubAPI {
    public static let endpoint = URL(string: "https://api.github.com/graphql")!

    private let transport: any HTTPTransport
    private let tokens: any TokenProvider
    private let endpoint: URL
    /// The budget after the most recent query.
    public private(set) var rateLimit: RateLimit?
    /// How many repo pages to read for the picker (100 repos each).
    public var repositoryPageLimit = 3

    public init(transport: any HTTPTransport = URLSessionTransport(), tokens: any TokenProvider, endpoint: URL = GitHubClient.endpoint) {
        self.transport = transport
        self.tokens = tokens
        self.endpoint = endpoint
    }

    public func latestRateLimit() async -> RateLimit? { rateLimit }

    public func viewer() async throws -> Viewer {
        struct Data: Decodable {
            struct V: Decodable { let login: String; let name: String?; let avatarUrl: URL? }
            let viewer: V
        }
        let data: Data = try await query(GitHubQueries.viewer)
        return Viewer(login: data.viewer.login, name: data.viewer.name, avatarURL: data.viewer.avatarUrl)
    }

    public func repositories() async throws -> [Repo] {
        struct Data: Decodable {
            struct Viewer: Decodable { let repositories: Connection<RawRepo> }
            let viewer: Viewer
        }
        var repos: [Repo] = []
        var cursor: String?
        for _ in 0..<repositoryPageLimit {
            let data: Data = try await query(GitHubQueries.repositories, variables: ["cursor": cursor])
            repos += data.viewer.repositories.nodes.compactMap { $0?.repo }
            guard data.viewer.repositories.pageInfo.hasNextPage else { break }
            cursor = data.viewer.repositories.pageInfo.endCursor
        }
        return repos
    }

    public func openPullRequests(in repos: [String]) async throws -> OpenPullRequests {
        var result = OpenPullRequests(pullRequests: [])
        for repo in repos {
            let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { result.failedRepos.append(repo); continue }
            do {
                result.pullRequests += try await openPullRequests(owner: parts[0], name: parts[1])
            } catch GitHubError.graphQL {
                // NOT_FOUND or FORBIDDEN for this repo only. The poll goes on.
                result.failedRepos.append(repo)
            } catch is RepoMissing {
                result.failedRepos.append(repo)
            }
        }
        return result
    }

    private struct RepoMissing: Error {}

    private func openPullRequests(owner: String, name: String) async throws -> [PullRequest] {
        struct Data: Decodable {
            struct Repository: Decodable { let nameWithOwner: String; let pullRequests: Connection<RawPullRequest> }
            let repository: Repository?
        }
        var prs: [PullRequest] = []
        var cursor: String?
        repeat {
            let data: Data = try await query(GitHubQueries.openPullRequests, variables: ["owner": owner, "name": name, "cursor": cursor])
            guard let repository = data.repository else { throw RepoMissing() }
            prs += repository.pullRequests.nodes.compactMap { $0?.pullRequest(repo: repository.nameWithOwner) }
            cursor = repository.pullRequests.pageInfo.hasNextPage ? repository.pullRequests.pageInfo.endCursor : nil
        } while cursor != nil
        return prs
    }

    public func checkDetails(for prs: [PullRequest]) async throws -> [String: CheckSummary] {
        let ids = prs.map(\.id).filter(GitHubQueries.isSafeNodeID)
        var result: [String: CheckSummary] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + GitHubQueries.checkBatchSize, ids.count)])
            start += batch.count
            let nodes: AliasedNodes<RawCheckNode> = try await query(GitHubQueries.checkDetails(ids: batch), allowPartial: true)
            for node in nodes.values.compactMap({ $0 }) {
                if let summary = node.summary { result[node.id] = summary }
            }
        }
        return result
    }

    // MARK: - Transport

    private func query<T: Decodable>(_ document: String, variables: [String: String?] = [:], allowPartial: Bool = false) async throws -> T {
        let token: String
        do {
            token = try await tokens.token()
        } catch let error as AuthError {
            throw GitHubError.auth(error)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        let vars = variables.mapValues { $0.map { $0 as Any } ?? NSNull() }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": document, "variables": vars])

        let (data, response): (Foundation.Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw Self.isOffline(error) ? GitHubError.offline : GitHubError.http(status: error.errorCode)
        }
        try Self.check(response, body: data)

        let envelope: Envelope<T>
        do {
            envelope = try GitHubDecoding.decoder.decode(Envelope<T>.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
        if let limit = envelope.data?.rateLimit ?? envelope.rateLimitOnly { rateLimit = limit }
        let errors = envelope.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            throw GitHubError.rateLimited(resetAt: rateLimit?.resetAt)
        }
        guard let value = envelope.data?.value, errors.isEmpty || allowPartial else {
            throw GitHubError.graphQL(messages: errors.map(\.message))
        }
        return value
    }

    static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
            true
        default:
            false
        }
    }

    /// Maps HTTP failures to the states the UI tells apart.
    static func check(_ response: HTTPURLResponse, body: Data) throws {
        let status = response.statusCode
        if (200..<300).contains(status) { return }
        if status == 401 { throw GitHubError.unauthorized }
        if status == 403 || status == 429 {
            if let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
                throw GitHubError.secondaryRateLimit(retryAfter: retry)
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                throw GitHubError.rateLimited(resetAt: reset)
            }
            let text = String(decoding: body, as: UTF8.self).lowercased()
            if text.contains("secondary rate limit") || text.contains("abuse") {
                throw GitHubError.secondaryRateLimit(retryAfter: nil)
            }
        }
        throw GitHubError.http(status: status)
    }
}

// MARK: - Decoding

enum GitHubDecoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// `data` with the query's value beside the `rateLimit` field every query asks for.
private struct Envelope<T: Decodable>: Decodable {
    struct Payload: Decodable {
        let value: T
        let rateLimit: RateLimit?

        init(from decoder: any Decoder) throws {
            value = try T(from: decoder)
            let container = try decoder.container(keyedBy: DynamicKey.self)
            rateLimit = try container.decodeIfPresent(RawRateLimit.self, forKey: DynamicKey(stringValue: "rateLimit"))?.rateLimit
        }
    }

    struct ErrorItem: Decodable {
        let message: String
        let type: String?
    }

    let data: Payload?
    let errors: [ErrorItem]?

    enum CodingKeys: String, CodingKey { case data, errors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([ErrorItem].self, forKey: .errors)
        if errors?.isEmpty == false {
            // With errors, `data` may be partial or null. Keep what decodes.
            data = try? container.decodeIfPresent(Payload.self, forKey: .data)
            rateLimitOnly = try? container.decodeIfPresent(RateLimitOnly.self, forKey: .data)?.rateLimit?.rateLimit
        } else {
            data = try container.decodeIfPresent(Payload.self, forKey: .data)
            rateLimitOnly = nil
        }
    }

    /// The budget when the rest of `data` didn't decode.
    let rateLimitOnly: RateLimit?

    private struct RateLimitOnly: Decodable { let rateLimit: RawRateLimit? }
}

private struct RawRateLimit: Decodable {
    let limit: Int?
    let cost: Int
    let remaining: Int
    let resetAt: Date
    var rateLimit: RateLimit { RateLimit(limit: limit ?? 5000, cost: cost, remaining: remaining, resetAt: resetAt) }
}

/// Every key but `rateLimit`, each decoded as `Node`. For aliased lookups.
struct AliasedNodes<Node: Decodable>: Decodable {
    let values: [Node?]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        values = try container.allKeys.filter { $0.stringValue != "rateLimit" }.sorted { $0.stringValue < $1.stringValue }
            .map { try container.decodeIfPresent(Node.self, forKey: $0) }
    }
}

struct Connection<Node: Decodable>: Decodable {
    struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    let pageInfo: PageInfo
    let nodes: [Node?]
}

struct Nodes<Node: Decodable>: Decodable {
    let nodes: [Node?]
}

struct Login: Decodable { let login: String }

struct RawRepo: Decodable {
    struct MQ: Decodable { let id: String }
    let nameWithOwner: String
    let isPrivate: Bool
    let isFork: Bool
    let pushedAt: Date?
    let url: URL?
    let mergeQueue: MQ?

    var repo: Repo {
        Repo(nameWithOwner: nameWithOwner, isPrivate: isPrivate, isFork: isFork, pushedAt: pushedAt, url: url, hasMergeQueue: mergeQueue != nil)
    }
}

struct RawPullRequest: Decodable {
    struct Reviewer: Decodable {
        struct Org: Decodable { let login: String }
        let __typename: String
        let login: String?
        let slug: String?
        let organization: Org?
    }
    struct ReviewRequestNode: Decodable { let requestedReviewer: Reviewer? }
    struct RawReview: Decodable { let state: Review.State; let submittedAt: Date?; let author: Login? }
    struct Label: Decodable { let name: String }
    struct AutoMerge: Decodable { let enabledAt: Date? }
    struct QueueEntry: Decodable {
        struct Queue: Decodable { struct Entries: Decodable { let totalCount: Int }; let entries: Entries? }
        let position: Int
        let state: MergeQueueState
        let enqueuedAt: Date?
        let estimatedTimeToMerge: Int?
        let mergeQueue: Queue?
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let headRefOid: String
    let baseRefName: String
    let author: Login?
    let assignees: Nodes<Login>
    let reviewRequests: Nodes<ReviewRequestNode>
    let latestReviews: Nodes<RawReview>
    let labels: Nodes<Label>
    let reviewDecision: ReviewDecision?
    let mergeable: Mergeable
    let mergeStateStatus: MergeStateStatus
    let autoMergeRequest: AutoMerge?
    let mergeQueueEntry: QueueEntry?

    func pullRequest(repo: String) -> PullRequest {
        let requests: [ReviewRequest] = reviewRequests.nodes.compactMap { node in
            guard let reviewer = node?.requestedReviewer else { return nil }
            if reviewer.__typename == "Team", let slug = reviewer.slug {
                return .team(reviewer.organization.map { "\($0.login)/\(slug)" } ?? slug)
            }
            return reviewer.login.map { .user($0) }
        }
        return PullRequest(
            id: id, repo: repo, number: number, title: title, url: url, isDraft: isDraft,
            author: author?.login,
            assignees: assignees.nodes.compactMap { $0?.login },
            reviewRequests: requests,
            latestReviews: latestReviews.nodes.compactMap { r in
                r.flatMap { r in r.author.map { Review(author: $0.login, state: r.state, submittedAt: r.submittedAt) } }
            },
            labels: labels.nodes.compactMap { $0?.name },
            reviewDecision: reviewDecision, mergeable: mergeable, mergeStateStatus: mergeStateStatus,
            autoMergeEnabled: autoMergeRequest != nil,
            mergeQueueEntry: mergeQueueEntry.map {
                MergeQueueEntry(
                    position: $0.position, state: $0.state, enqueuedAt: $0.enqueuedAt,
                    estimatedTimeToMerge: $0.estimatedTimeToMerge, queueLength: $0.mergeQueue?.entries?.totalCount
                )
            },
            headSHA: headRefOid, baseRef: baseRefName, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

struct RawCheckNode: Decodable {
    struct Commit: Decodable {
        struct Rollup: Decodable { let state: RollupState; let contexts: Nodes<Context> }
        let oid: String
        let statusCheckRollup: Rollup?
    }
    struct CommitNode: Decodable { let commit: Commit }
    struct Context: Decodable {
        struct Suite: Decodable { struct Run: Decodable { struct W: Decodable { let name: String }; let workflow: W? }; let workflowRun: Run? }
        let __typename: String
        // CheckRun
        let name: String?
        let status: CheckStatus?
        let conclusion: CheckConclusion?
        let startedAt: Date?
        let completedAt: Date?
        let detailsUrl: URL?
        let checkSuite: Suite?
        // StatusContext
        let context: String?
        let state: RollupState?
        let targetUrl: URL?
        let createdAt: Date?
        // Both
        let isRequired: Bool?

        var check: CheckRun? {
            if __typename == "CheckRun", let name {
                return CheckRun(
                    name: name, kind: .checkRun, status: status ?? .pending, conclusion: conclusion,
                    startedAt: startedAt, completedAt: completedAt, detailsURL: detailsUrl,
                    isRequired: isRequired ?? false, workflowName: checkSuite?.workflowRun?.workflow?.name
                )
            }
            if __typename == "StatusContext", let context {
                let (status, conclusion): (CheckStatus, CheckConclusion?) = switch state ?? .pending {
                case .success: (.completed, .success)
                case .failure, .error: (.completed, .failure)
                case .pending, .expected: (.pending, nil)
                }
                return CheckRun(
                    name: context, kind: .statusContext, status: status, conclusion: conclusion,
                    startedAt: createdAt, completedAt: status == .completed ? createdAt : nil,
                    detailsURL: targetUrl, isRequired: isRequired ?? false
                )
            }
            return nil
        }
    }
    struct Removal: Decodable { let reason: String?; let createdAt: Date? }

    let id: String
    let headRefOid: String
    let commits: Nodes<CommitNode>
    let timelineItems: Nodes<Removal>

    var summary: CheckSummary? {
        let commit = commits.nodes.compactMap { $0?.commit }.last
        let removal = timelineItems.nodes.compactMap { $0 }.last
        return CheckSummary(
            headSHA: commit?.oid ?? headRefOid,
            rollup: commit?.statusCheckRollup?.state,
            checks: commit?.statusCheckRollup?.contexts.nodes.compactMap { $0?.check } ?? [],
            lastQueueRemoval: removal.map { MergeQueueRemoval(reason: $0.reason, at: $0.createdAt) }
        )
    }
}
