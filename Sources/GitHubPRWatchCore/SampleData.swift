import Foundation

/// Placeholder people, repos and PRs for windowless renders and previews. Never real data.
public enum SampleData {
    public static let viewer = Viewer(login: "rchen", name: "Riley Chen")

    public static let repos: [Repo] = [
        Repo(nameWithOwner: "acme/web", pushedAt: Date().addingTimeInterval(-3600), hasMergeQueue: true),
        Repo(nameWithOwner: "acme/api", pushedAt: Date().addingTimeInterval(-7200)),
        Repo(nameWithOwner: "acme/infra", pushedAt: Date().addingTimeInterval(-86_400 * 3)),
        Repo(nameWithOwner: "acme/mobile", pushedAt: Date().addingTimeInterval(-86_400 * 9)),
        Repo(nameWithOwner: "acme/docs", pushedAt: Date().addingTimeInterval(-86_400 * 40)),
        Repo(nameWithOwner: "rchen/dotfiles", pushedAt: Date().addingTimeInterval(-86_400 * 2)),
    ]

    public static let agentLogin = "jlin-agent"

    /// The sample viewer's teams.
    public static let teams: Set<String> = ["acme/platform"]

    /// Starter views with the agent and watchlist filled in.
    public static var views: [SavedView] {
        [BuiltInViews.mine, BuiltInViews.needsMyReview, BuiltInViews.agentPRs([agentLogin]), BuiltInViews.watchlist(["tbrandt", "nhaddad"])]
    }

    /// One PR in each state, relative to `now`.
    public static func pullRequests(now: Date = Date()) -> [PullRequest] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func check(_ name: String, running: Bool = false, failed: Bool = false, start: Double, end: Double? = nil, required: Bool = false) -> CheckRun {
            CheckRun(
                name: name, status: running ? .inProgress : .completed,
                conclusion: running ? nil : (failed ? .failure : .success),
                startedAt: ago(start), completedAt: running ? nil : ago(end ?? 0), isRequired: required
            )
        }
        func summary(_ sha: String, _ checks: [CheckRun]) -> CheckSummary {
            CheckSummary(headSHA: sha, rollup: nil, checks: checks)
        }

        return [
            PullRequest(
                id: "PR_running", repo: "acme/web", number: 4826, title: "Paginate audit log table",
                author: agentLogin, assignees: ["rchen"], reviewDecision: .reviewRequired, mergeStateStatus: .blocked,
                headSHA: "a1", updatedAt: ago(5),
                checks: summary("a1", [check("build", start: 23, end: 18), check("e2e-chrome", running: true, start: 23), check("lint", start: 23, end: 20)])
            ),
            PullRequest(
                id: "PR_ready", repo: "acme/api", number: 1290, title: "Add idempotency keys to payment intents",
                author: agentLogin, assignees: ["rchen"], reviewDecision: .approved, mergeStateStatus: .clean,
                headSHA: "b1", updatedAt: ago(6),
                checks: summary("b1", [check("build", start: 40, end: 6), check("test", start: 40, end: 8)])
            ),
            PullRequest(
                id: "PR_behind", repo: "acme/api", number: 1288, title: "Add audit events for SSO changes",
                author: "rchen", reviewDecision: .approved, mergeStateStatus: .behind,
                headSHA: "c1", updatedAt: ago(30),
                checks: summary("c1", [check("build", start: 60, end: 30)])
            ),
            PullRequest(
                id: "PR_guard", repo: "acme/api", number: 1284, title: "Rate limit export endpoint per org, with a longer title that wraps onto a second line",
                author: "rchen", reviewDecision: .approved, mergeStateStatus: .blocked,
                headSHA: "d1", updatedAt: ago(45),
                checks: summary("d1", [check("build", start: 70, end: 40), check("required-commit", failed: true, start: 70, end: 69, required: true)])
            ),
            PullRequest(
                id: "PR_failed", repo: "acme/web", number: 4821, title: "Migrate billing settings to new form kit",
                author: "rchen", reviewDecision: .reviewRequired, mergeStateStatus: .blocked,
                headSHA: "e1", updatedAt: ago(2),
                checks: summary("e1", [check("e2e-chrome", failed: true, start: 36, end: 2), check("lint", failed: true, start: 36, end: 30), check("build", start: 36, end: 20)])
            ),
            PullRequest(
                id: "PR_queue", repo: "acme/web", number: 4818, title: "Upgrade router to v7",
                author: "rchen", reviewDecision: .approved, mergeStateStatus: .clean, autoMergeEnabled: true,
                mergeQueueEntry: MergeQueueEntry(position: 2, state: .awaitingChecks, estimatedTimeToMerge: 720, queueLength: 7),
                headSHA: "f1", updatedAt: ago(12)
            ),
            PullRequest(
                id: "PR_conflict", repo: "acme/web", number: 4809, title: "Fix flaky date picker test in Safari",
                author: agentLogin, assignees: ["rchen"], mergeable: .conflicting, mergeStateStatus: .dirty,
                headSHA: "g1", updatedAt: ago(9)
            ),
            PullRequest(
                id: "PR_waiting", repo: "acme/web", number: 4799, title: "Onboarding checklist empty state",
                author: "rchen", reviewRequests: [.user("nhaddad"), .user("tbrandt")], reviewDecision: .reviewRequired,
                mergeStateStatus: .blocked, headSHA: "h1", updatedAt: ago(180),
                checks: summary("h1", [check("build", start: 200, end: 185)])
            ),
            PullRequest(
                id: "PR_changes", repo: "acme/api", number: 1279, title: "Remove legacy v1 auth middleware",
                author: "rchen", latestReviews: [Review(author: "srivera", state: .changesRequested, submittedAt: ago(60))],
                reviewDecision: .changesRequested, mergeStateStatus: .blocked, headSHA: "i1", updatedAt: ago(60),
                checks: summary("i1", [check("build", start: 90, end: 70)])
            ),
            PullRequest(
                id: "PR_draft", repo: "acme/web", number: 4840, title: "Spike: virtualized PR list",
                isDraft: true, author: "rchen", mergeStateStatus: .unknown, headSHA: "j1", updatedAt: ago(240)
            ),
            PullRequest(
                id: "PR_review", repo: "acme/web", number: 4835, title: "Dark mode tokens for charts",
                author: "apark", reviewRequests: [.user("rchen")], reviewDecision: .reviewRequired, mergeStateStatus: .blocked,
                headSHA: "k1", updatedAt: ago(20),
                checks: summary("k1", [check("build", running: true, start: 12)])
            ),
            PullRequest(
                id: "PR_watch", repo: "acme/api", number: 1295, title: "Trace sampling config per service",
                author: "tbrandt", reviewRequests: [.team("acme/platform")], reviewDecision: .reviewRequired,
                mergeStateStatus: .blocked, headSHA: "l1", updatedAt: ago(9),
                checks: summary("l1", [check("build", running: true, start: 9)])
            ),
        ]
    }
}

/// Answers every call from fixed data. For renders and tests.
public actor StaticGitHubAPI: GitHubAPI {
    public var viewerValue: Viewer
    public var repos: [Repo]
    public var prs: [PullRequest]
    public var rateLimit: RateLimit?
    /// Thrown by every call while set.
    public var error: GitHubError?
    /// The viewer's teams, as `org/slug`. `nil` acts like a token without `read:org`.
    public var teams: Set<String>?

    public init(
        viewer: Viewer = SampleData.viewer, repos: [Repo] = SampleData.repos, prs: [PullRequest] = SampleData.pullRequests(),
        rateLimit: RateLimit? = nil, teams: Set<String>? = []
    ) {
        self.viewerValue = viewer
        self.repos = repos
        self.prs = prs
        self.rateLimit = rateLimit
        self.teams = teams
    }

    public func set(teams: Set<String>?) { self.teams = teams }

    public func viewerTeams(login: String, organizations: [String]) async throws -> TeamMemberships {
        if let error { throw error }
        guard let teams else { return TeamMemberships(teams: [], missingScope: true) }
        let orgs = Set(organizations.map { $0.lowercased() })
        return TeamMemberships(teams: teams.filter { orgs.contains(String($0.lowercased().split(separator: "/").first ?? "")) })
    }

    public func set(prs: [PullRequest]) { self.prs = prs }
    public func set(error: GitHubError?) { self.error = error }

    public func viewer() async throws -> Viewer {
        if let error { throw error }
        return viewerValue
    }

    public func repositories() async throws -> [Repo] {
        if let error { throw error }
        return repos
    }

    public func openPullRequests(in repos: [String]) async throws -> OpenPullRequests {
        if let error { throw error }
        let wanted = Set(repos.map { $0.lowercased() })
        return OpenPullRequests(pullRequests: prs.filter { wanted.contains($0.repo.lowercased()) }.map {
            var pr = $0
            pr.checks = nil
            return pr
        })
    }

    public func checkDetails(for prs: [PullRequest]) async throws -> [String: CheckSummary] {
        if let error { throw error }
        let wanted = Set(prs.map(\.id))
        var result: [String: CheckSummary] = [:]
        for pr in self.prs where wanted.contains(pr.id) {
            result[pr.id] = pr.checks ?? CheckSummary(headSHA: pr.headSHA, rollup: nil, checks: [])
        }
        return result
    }

    public func latestRateLimit() async -> RateLimit? { rateLimit }
}
