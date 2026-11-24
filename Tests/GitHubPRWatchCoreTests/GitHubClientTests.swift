import Foundation
import Testing
@testable import GitHubPRWatchCore

/// Response shapes copied from live read-only queries, with people and repos replaced by placeholders.
enum Fixtures {
    static let rateLimit = #""rateLimit":{"limit":5000,"cost":1,"remaining":4990,"resetAt":"2026-11-24T07:35:16Z"}"#

    static let viewer = #"{"data":{\#(rateLimit),"viewer":{"login":"rchen","name":"Riley Chen","avatarUrl":"https://example.com/a.png"}}}"#

    static func repos(hasNext: Bool = false) -> String {
        #"{"data":{\#(rateLimit),"viewer":{"repositories":{"pageInfo":{"hasNextPage":\#(hasNext),"endCursor":"Y1"},"nodes":[{"nameWithOwner":"acme/web","isPrivate":true,"isFork":false,"pushedAt":"2026-11-23T10:00:00Z","url":"https://github.com/acme/web","mergeQueue":{"id":"MQ_1"}},{"nameWithOwner":"rchen/dotfiles","isPrivate":false,"isFork":false,"pushedAt":null,"url":"https://github.com/rchen/dotfiles","mergeQueue":null}]}}}}"#
    }

    static func pullRequests(hasNext: Bool = false, number: Int = 4821) -> String {
        #"""
        {"data":{\#(rateLimit),"repository":{"nameWithOwner":"acme/web","pullRequests":{"pageInfo":{"hasNextPage":\#(hasNext),"endCursor":"C1"},"nodes":[
          {"id":"PR_kwA\#(number)","number":\#(number),"title":"Migrate billing settings","url":"https://github.com/acme/web/pull/\#(number)","isDraft":false,
           "createdAt":"2026-11-19T17:46:39Z","updatedAt":"2026-11-23T14:11:27Z","headRefOid":"31514b6","baseRefName":"main",
           "author":{"login":"jlin-agent"},
           "assignees":{"nodes":[{"login":"rchen"}]},
           "reviewRequests":{"nodes":[{"requestedReviewer":null},{"requestedReviewer":{"__typename":"User","login":"apark"}},{"requestedReviewer":{"__typename":"Team","slug":"platform","organization":{"login":"acme"}}},{"requestedReviewer":{"__typename":"Bot","login":"helper-bot"}}]},
           "latestReviews":{"nodes":[{"state":"COMMENTED","submittedAt":"2026-11-23T10:00:00Z","author":{"login":"review-bot"}},{"state":"CHANGES_REQUESTED","submittedAt":"2026-11-23T11:00:00Z","author":{"login":"srivera"}},{"state":"APPROVED","submittedAt":null,"author":null}]},
           "labels":{"nodes":[{"name":"needs-qa"}]},
           "reviewDecision":"CHANGES_REQUESTED","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
           "autoMergeRequest":{"enabledAt":"2026-11-23T12:00:00Z"},
           "mergeQueueEntry":{"position":2,"state":"AWAITING_CHECKS","enqueuedAt":"2026-11-23T12:00:00Z","estimatedTimeToMerge":720,"mergeQueue":{"entries":{"totalCount":7}}}},
          {"id":"PR_kwB","number":15149,"title":"Draft thing","url":"https://github.com/acme/web/pull/15149","isDraft":true,
           "createdAt":"2026-11-23T21:59:09Z","updatedAt":"2026-11-24T00:11:53Z","headRefOid":"663eda0","baseRefName":"trunk",
           "author":null,"assignees":{"nodes":[]},"reviewRequests":{"nodes":[]},"latestReviews":{"nodes":[]},"labels":{"nodes":[]},
           "reviewDecision":null,"mergeable":"SOMETHING_NEW","mergeStateStatus":"DRAFT_LIKE_FUTURE_VALUE","autoMergeRequest":null,"mergeQueueEntry":null}
        ]}}}}
        """#
    }

    static let checks = #"""
    {"data":{\#(rateLimit),
     "p0":{"id":"PR_kwA4821","headRefOid":"31514b6","commits":{"nodes":[{"commit":{"oid":"31514b6","statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
        {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-19T17:46:46Z","completedAt":"2026-11-19T17:49:39Z","detailsUrl":"https://github.com/acme/web/actions/runs/1/job/2","isRequired":true,"checkSuite":{"workflowRun":{"workflow":{"name":"Lint"}}}},
        {"__typename":"CheckRun","name":"e2e-chrome","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-11-19T17:46:46Z","completedAt":null,"detailsUrl":null,"isRequired":false,"checkSuite":{"workflowRun":null}},
        {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":"https://ci.example.com/1","createdAt":"2026-11-19T17:50:00Z","isRequired":false},
        {"__typename":"StatusContext","context":"deploy/preview","state":"PENDING","targetUrl":null,"createdAt":"2026-11-19T17:51:00Z","isRequired":false}
     ]}}}}]},"timelineItems":{"nodes":[{"reason":"MERGE_CONFLICT","createdAt":"2026-11-20T10:00:00Z"}]}},
     "p1":{"id":"PR_kwB","headRefOid":"663eda0","commits":{"nodes":[{"commit":{"oid":"663eda0","statusCheckRollup":null}}]},"timelineItems":{"nodes":[]}},
     "p2":null}}
    """#
}

@Suite struct GitHubClientTests {
    func client(_ transport: FakeTransport) -> GitHubClient {
        GitHubClient(transport: transport, tokens: StaticTokenProvider("placeholder-token"))
    }

    @Test func viewerAndRateLimit() async throws {
        let transport = FakeTransport(json: Fixtures.viewer)
        let c = client(transport)
        let viewer = try await c.viewer()
        #expect(viewer == Viewer(login: "rchen", name: "Riley Chen", avatarURL: URL(string: "https://example.com/a.png")))
        let limit = await c.rateLimit
        #expect(limit?.remaining == 4990)
        #expect(limit?.cost == 1)
    }

    @Test func sendsBearerTokenAndQuery() async throws {
        let transport = FakeTransport { request, _ in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer placeholder-token")
            #expect(request.httpMethod == "POST")
            #expect(request.url == GitHubClient.endpoint)
            return (200, [:], Fixtures.viewer)
        }
        _ = try await client(transport).viewer()
        #expect(transport.bodies[0].contains("viewer"))
    }

    @Test func repositoriesPaginate() async throws {
        let transport = FakeTransport { _, index in (200, [:], Fixtures.repos(hasNext: index == 0)) }
        let repos = try await client(transport).repositories()
        #expect(repos.count == 4)
        #expect(repos[0].nameWithOwner == "acme/web")
        #expect(repos[0].hasMergeQueue)
        #expect(repos[0].isPrivate)
        #expect(!repos[1].hasMergeQueue)
        #expect(transport.bodies[1].contains("\"cursor\":\"Y1\""))
    }

    @Test func openPullRequestsDecodeEveryField() async throws {
        let transport = FakeTransport(json: Fixtures.pullRequests())
        let result = try await client(transport).openPullRequests(in: ["acme/web"])
        #expect(result.failedRepos.isEmpty)
        #expect(result.pullRequests.count == 2)
        let p = result.pullRequests[0]
        #expect(p.id == "PR_kwA4821")
        #expect(p.repo == "acme/web")
        #expect(p.author == "jlin-agent")
        #expect(p.assignees == ["rchen"])
        #expect(p.reviewRequests == [.user("apark"), .team("acme/platform"), .user("helper-bot")])
        #expect(p.latestReviews.map(\.author) == ["review-bot", "srivera"])
        #expect(p.latestReviews[1].state == .changesRequested)
        #expect(p.labels == ["needs-qa"])
        #expect(p.reviewDecision == .changesRequested)
        #expect(p.mergeable == .mergeable)
        #expect(p.mergeStateStatus == .blocked)
        #expect(p.autoMergeEnabled)
        #expect(p.mergeQueueEntry == MergeQueueEntry(position: 2, state: .awaitingChecks, enqueuedAt: ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z"), estimatedTimeToMerge: 720, queueLength: 7))
        #expect(p.headSHA == "31514b6")
        #expect(p.checks == nil)
        let draft = result.pullRequests[1]
        #expect(draft.isDraft)
        #expect(draft.author == nil)
        #expect(draft.reviewDecision == nil)
        // Values GitHub may add later decode as unknown instead of failing the poll.
        #expect(draft.mergeable == .unknown)
        #expect(draft.mergeStateStatus == .unknown)
    }

    @Test func openPullRequestsPaginatePerRepo() async throws {
        let transport = FakeTransport { _, index in (200, [:], Fixtures.pullRequests(hasNext: index == 0, number: 100 + index)) }
        let result = try await client(transport).openPullRequests(in: ["acme/web"])
        #expect(result.pullRequests.count == 4)
        #expect(transport.bodies[1].contains("\"cursor\":\"C1\""))
        #expect(transport.bodies[0].contains("\"owner\":\"acme\""))
    }

    @Test func missingRepoIsReportedNotThrown() async throws {
        let transport = FakeTransport { request, _ in
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            if body.contains("\"name\":\"gone\"") {
                return (200, [:], #"{"data":{\#(Fixtures.rateLimit),"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository with the name 'acme/gone'."}]}"#)
            }
            return (200, [:], Fixtures.pullRequests())
        }
        let result = try await client(transport).openPullRequests(in: ["acme/gone", "acme/web", "not-a-repo"])
        #expect(result.failedRepos == ["acme/gone", "not-a-repo"])
        #expect(result.pullRequests.count == 2)
    }

    @Test func checkDetailsDecodeCheckRunsAndStatusContexts() async throws {
        let transport = FakeTransport(json: Fixtures.checks)
        let prs = [pr("PR_kwA4821", head: "31514b6"), pr("PR_kwB", head: "663eda0")]
        let details = try await client(transport).checkDetails(for: prs)
        let a = try #require(details["PR_kwA4821"])
        #expect(a.headSHA == "31514b6")
        #expect(a.rollup == .failure)
        #expect(a.checks.count == 4)
        #expect(a.checks[0] == CheckRun(
            name: "lint", kind: .checkRun, status: .completed, conclusion: .failure,
            startedAt: ISO8601DateFormatter().date(from: "2026-11-19T17:46:46Z"),
            completedAt: ISO8601DateFormatter().date(from: "2026-11-19T17:49:39Z"),
            detailsURL: URL(string: "https://github.com/acme/web/actions/runs/1/job/2"), isRequired: true, workflowName: "Lint"
        ))
        #expect(a.checks[1].isRunning)
        #expect(a.checks[2].kind == .statusContext)
        #expect(a.checks[2].conclusion == .success)
        #expect(a.checks[3].isRunning)
        #expect(a.failing.map(\.name) == ["lint"])
        #expect(a.lastQueueRemoval?.reason == "MERGE_CONFLICT")
        let b = try #require(details["PR_kwB"])
        #expect(b.checks.isEmpty)
        #expect(b.rollup == nil)
        // isRequired needs the PR ID inline.
        #expect(transport.bodies[0].contains(#"isRequired(pullRequestId: \"PR_kwA4821\")"#))
    }

    @Test func checkDetailsBatchAndSkipUnsafeIDs() async throws {
        let transport = FakeTransport(json: #"{"data":{\#(Fixtures.rateLimit)}}"#)
        let prs = (0..<20).map { pr("PR_\($0)") } + [pr("bad\"id")]
        _ = try await client(transport).checkDetails(for: prs)
        #expect(transport.bodies.count == 2)
        #expect(!transport.bodies.joined().contains("bad"))
    }

    @Test func unauthorized() async {
        let transport = FakeTransport(status: 401, json: #"{"message":"Bad credentials"}"#)
        await #expect(throws: GitHubError.unauthorized) { try await client(transport).viewer() }
    }

    @Test func secondaryRateLimitWithRetryAfter() async {
        let transport = FakeTransport(status: 403, headers: ["Retry-After": "90"], json: #"{"message":"You have exceeded a secondary rate limit."}"#)
        await #expect(throws: GitHubError.secondaryRateLimit(retryAfter: 90)) { try await client(transport).viewer() }
    }

    @Test func secondaryRateLimitFromMessage() async {
        let transport = FakeTransport(status: 403, json: #"{"message":"You have exceeded a secondary rate limit."}"#)
        await #expect(throws: GitHubError.secondaryRateLimit(retryAfter: nil)) { try await client(transport).viewer() }
    }

    @Test func primaryRateLimitFromHeaders() async {
        let transport = FakeTransport(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"], json: "{}")
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000))) { try await client(transport).viewer() }
    }

    @Test func primaryRateLimitFromGraphQLError() async {
        let transport = FakeTransport(json: #"{"data":{\#(Fixtures.rateLimit)},"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)
        await #expect(throws: GitHubError.rateLimited(resetAt: ISO8601DateFormatter().date(from: "2026-11-24T07:35:16Z"))) {
            try await client(transport).viewer()
        }
    }

    @Test func offline() async {
        let transport = FakeTransport { _, _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: GitHubError.offline) { try await client(transport).viewer() }
    }

    @Test func serverError() async {
        let transport = FakeTransport(status: 502, json: "Bad gateway")
        await #expect(throws: GitHubError.http(status: 502)) { try await client(transport).viewer() }
    }

    @Test func tokenProblemsSurfaceAsAuthErrors() async {
        let c = GitHubClient(transport: FakeTransport(json: Fixtures.viewer), tokens: StoredTokenProvider(store: InMemorySecrets()))
        await #expect(throws: GitHubError.auth(.noSavedToken)) { try await c.viewer() }
    }

    @Test func checkDetailQueryEmbedsOnlySafeIDs() {
        #expect(GitHubQueries.isSafeNodeID("PR_kwDODKw3uc8AAAABQd5P6A"))
        #expect(GitHubQueries.isSafeNodeID("MDExOlB1bGxSZXF1ZXN0MTIz=="))
        #expect(!GitHubQueries.isSafeNodeID("x\") { evil }"))
        #expect(!GitHubQueries.isSafeNodeID(""))
        #expect(!GitHubQueries.isSafeNodeID("é"))
    }
}
