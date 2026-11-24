import Foundation
import Testing
@testable import GitHubPRWatchCore

@MainActor
@Suite struct PRStoreTests {
    let signedInConfig = AppConfig(authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api"], onboardingComplete: true)

    func store(_ api: StaticGitHubAPI, config: AppConfig? = nil, views: [SavedView]? = SampleData.views) -> PRStore {
        PRStore(dependencies: .inMemory(api: api, config: config ?? signedInConfig, views: views))
    }

    @Test func freshInstallNeedsOnboarding() {
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI()))
        #expect(s.needsOnboarding)
        #expect(s.auth == .signedOut)
        #expect(s.views == BuiltInViews.defaults)
        #expect(s.isCLIInstalled)
        #expect(!s.isDeviceFlowAvailable)
    }

    @Test func signInWithCLIThenOnboard() async {
        let config = InMemoryDocumentStore<AppConfig>()
        var deps = PRStoreDependencies.inMemory(api: StaticGitHubAPI())
        deps.config = config
        let s = PRStore(dependencies: deps)
        await s.signInWithGitHubCLI()
        #expect(s.auth == .signedIn(SampleData.viewer, .githubCLI))
        #expect(try! config.load()?.authMethod == .githubCLI)

        await s.loadRepoChoices()
        #expect(s.repoChoices.count == SampleData.repos.count)
        #expect(s.suggestedRepos.contains("acme/web"))

        s.completeOnboarding(repos: ["acme/web"], views: [BuiltInViews.mine])
        #expect(!s.needsOnboarding)
        #expect(s.watchedRepos == ["acme/web"])
        #expect(s.views.map(\.name) == ["Mine"])
        #expect(s.selectedViewID == BuiltInViews.mineID)
        #expect(try! config.load()?.onboardingComplete == true)
        s.stop()
    }

    @Test func pastedTokenGoesToSecretsAndSignOutRemovesIt() async {
        var deps = PRStoreDependencies.inMemory(api: StaticGitHubAPI())
        let secrets = InMemorySecrets()
        deps.secrets = secrets
        let s = PRStore(dependencies: deps)
        await s.signIn(pastedToken: "  ghp_placeholder \n")
        #expect(s.authMethod == .pastedToken)
        #expect(secrets.read(SecretKeys.githubToken) == "ghp_placeholder")
        s.signOut()
        #expect(s.auth == .signedOut)
        #expect(secrets.read(SecretKeys.githubToken) == nil)
    }

    @Test func cliSignInNeverStoresTheToken() async {
        var deps = PRStoreDependencies.inMemory(api: StaticGitHubAPI())
        let secrets = InMemorySecrets()
        deps.secrets = secrets
        let s = PRStore(dependencies: deps)
        await s.signInWithGitHubCLI()
        #expect(secrets.read(SecretKeys.githubToken) == nil)
    }

    @Test func failedSignInExplainsWhy() async {
        let api = StaticGitHubAPI()
        await api.set(error: .unauthorized)
        let s = PRStore(dependencies: .inMemory(api: api))
        await s.signIn(pastedToken: "bad")
        #expect(s.auth == .signedOut)
        #expect(s.authError == "GitHub rejected the token.")
    }

    @Test func refreshFillsLanes() async {
        let s = store(StaticGitHubAPI())
        await s.refresh()
        #expect(s.connection == .upToDate)
        #expect(s.lastUpdated != nil)
        #expect(s.pullRequests.count == SampleData.pullRequests().count)
        let lanes = s.lanes(for: BuiltInViews.mineID)
        #expect(lanes.map(\.lane) == Lane.allCases)
        let yourMove = lanes[0].pullRequests.map(\.pr.number)
        #expect(yourMove.contains(4821))
        #expect(yourMove.contains(1290))
        #expect(!yourMove.contains(4835)) // Someone else's PR is not in Mine.
        #expect(lanes[2].pullRequests.map(\.pr.number) == [4818])
        #expect(s.pullRequests(in: BuiltInViews.needsMyReviewID).map(\.pr.number) == [4835])
        // Mine and Needs my review are pinned: 6 of mine plus the review request.
        #expect(s.yourMoveCount == 7)
    }

    @Test func onlyPRsInSomeViewGetCheckDetail() async {
        let s = store(StaticGitHubAPI(), views: [BuiltInViews.needsMyReview])
        await s.refresh()
        let withChecks = s.pullRequests.filter { $0.pr.checks != nil }.map(\.pr.number)
        #expect(withChecks == [4835])
    }

    @Test func firstPollIsSilentThenEventsFlow() async {
        let api = StaticGitHubAPI(prs: [pr(checks: [check("ci", .running)])])
        let s = store(api, config: AppConfig(authMethod: .githubCLI, viewer: Viewer(login: me), watchedRepos: ["acme/web"], onboardingComplete: true))
        var received: [PREvent] = []
        s.onEvents = { received += $0 }
        await s.refresh()
        #expect(received.isEmpty)
        await api.set(prs: [pr(checks: [check("ci")])])
        await s.refresh()
        #expect(received.map(\.kind) == [.ciReady])
        #expect(received.first?.viewName == "Mine")
        #expect(s.recentEvents.count == 1)
    }

    @Test func droppedStatusShowsAfterQueueExit() async {
        let api = StaticGitHubAPI(prs: [pr(queue: MergeQueueEntry(position: 0), checks: [check("ci")])])
        let s = store(api, config: AppConfig(authMethod: .githubCLI, viewer: Viewer(login: me), watchedRepos: ["acme/web"], onboardingComplete: true))
        await s.refresh()
        await api.set(prs: [pr(checks: [check("ci")])])
        await s.refresh()
        #expect(s.pullRequests.first?.info.status.kind == .droppedFromMergeQueue)
        #expect(s.pullRequests.first?.info.lane == .yourMove)
    }

    @Test func errorsAreDistinctStates() async {
        let api = StaticGitHubAPI()
        let s = store(api)
        await api.set(error: .offline)
        await s.refresh()
        #expect(s.connection == .offline)
        await api.set(error: .secondaryRateLimit(retryAfter: 60))
        await s.refresh()
        if case .secondaryRateLimited = s.connection {} else { Issue.record("expected secondary rate limit, got \(s.connection)") }
        await api.set(error: .rateLimited(resetAt: t0))
        await s.refresh()
        #expect(s.connection == .rateLimited(until: t0))
        await api.set(error: .unauthorized)
        await s.refresh()
        #expect(s.connection == .tokenRejected)
        #expect(s.connection.message != nil)
    }

    @Test func failedReposKeepTheirPRs() async {
        final class FlakyAPI: GitHubAPI, @unchecked Sendable {
            var failWeb = false
            let base = StaticGitHubAPI()
            func viewer() async throws -> Viewer { SampleData.viewer }
            func repositories() async throws -> [Repo] { [] }
            func openPullRequests(in repos: [String]) async throws -> OpenPullRequests {
                var result = try await base.openPullRequests(in: repos.filter { !(failWeb && $0 == "acme/web") })
                if failWeb { result.failedRepos = ["acme/web"] }
                return result
            }
            func checkDetails(for prs: [PullRequest]) async throws -> [String: CheckSummary] { try await base.checkDetails(for: prs) }
            func latestRateLimit() async -> RateLimit? { nil }
        }
        let api = FlakyAPI()
        let s = PRStore(dependencies: .inMemory(api: api, config: signedInConfig, views: SampleData.views))
        await s.refresh()
        let before = s.pullRequests.count
        api.failWeb = true
        await s.refresh()
        #expect(s.pullRequests.count == before)
        #expect(s.failedRepos == ["acme/web"])
    }

    @Test func viewsPersistAndReclassify() async {
        let viewsStore = InMemoryDocumentStore<[SavedView]>()
        var deps = PRStoreDependencies.inMemory(api: StaticGitHubAPI(), config: signedInConfig)
        deps.views = viewsStore
        let s = PRStore(dependencies: deps)
        var custom = SavedView(name: "Agents", rule: FilterRule(match: .all, [.predicate(.author(.anyOf(["jlin-agent"])))]))
        s.saveView(custom)
        #expect(try! viewsStore.load()?.last?.name == "Agents")
        custom.name = "Agent work"
        s.saveView(custom)
        #expect(s.views.filter { $0.id == custom.id }.map(\.name) == ["Agent work"])
        s.moveViews(fromOffsets: IndexSet(integer: s.views.count - 1), toOffset: 0)
        #expect(s.views.first?.id == custom.id)
        s.deleteView(id: custom.id)
        #expect(!s.views.contains { $0.id == custom.id })
        #expect(try! viewsStore.load()?.count == BuiltInViews.defaults.count)
    }

    @Test func restoredSessionFetchesViewerWhenUnknown() async {
        let s = store(StaticGitHubAPI(), config: AppConfig(authMethod: .githubCLI, watchedRepos: ["acme/web"], onboardingComplete: true))
        #expect(s.auth == .signingIn(.githubCLI))
        await s.refresh()
        #expect(s.viewer == SampleData.viewer)
    }

    @Test func costEstimate() {
        let a = RateLimit(cost: 1, remaining: 4990, resetAt: t0)
        let b = RateLimit(cost: 1, remaining: 4980, resetAt: t0)
        #expect(PRStore.cost(before: a, after: b) == 10)
        #expect(PRStore.cost(before: nil, after: b) == 1)
    }
}
