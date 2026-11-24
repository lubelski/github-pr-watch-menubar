import Foundation
import Testing
@testable import GitHubPRWatchCore

@MainActor
@Suite struct PRStoreSettingsTests {
    let config = AppConfig(authMethod: .githubCLI, viewer: Viewer(login: me), watchedRepos: ["acme/web"], onboardingComplete: true)

    @Test func queueDropNotifiesOnlyAfterTheNextPoll() async {
        let queued = pr(queue: MergeQueueEntry(position: 1, queueLength: 4), checks: [check("ci")])
        let out = pr(checks: [check("ci")])
        let api = StaticGitHubAPI(prs: [queued])
        let s = PRStore(dependencies: .inMemory(api: api, config: config, views: SampleData.views))
        var received: [PREvent] = []
        s.onEvents = { received += $0 }
        await s.refresh()
        await api.set(prs: [out])
        await s.refresh()
        #expect(received.isEmpty)
        // The row already says so; only the banner waits.
        #expect(s.pullRequests.first?.info.status.kind == .droppedFromMergeQueue)
        await s.refresh()
        #expect(received.map(\.kind) == [.droppedFromMergeQueue])
        #expect(received.first?.detail.queuePosition == 2)
        #expect(s.recentEvents.map(\.kind) == [.droppedFromMergeQueue])
    }

    @Test func queueBlipWhileMergingStaysSilent() async {
        let queued = pr(queue: MergeQueueEntry(position: 0), checks: [check("ci")])
        let api = StaticGitHubAPI(prs: [queued])
        let s = PRStore(dependencies: .inMemory(api: api, config: config, views: SampleData.views))
        var received: [PREvent] = []
        s.onEvents = { received += $0 }
        await s.refresh()
        await api.set(prs: [pr(checks: [check("ci")])])
        await s.refresh()
        await api.set(prs: []) // merged
        await s.refresh()
        #expect(received.isEmpty)
    }

    @Test func settingsPersist() {
        let store = InMemoryDocumentStore<AppConfig>(config)
        var deps = PRStoreDependencies.inMemory(api: StaticGitHubAPI())
        deps.config = store
        let s = PRStore(dependencies: deps)
        #expect(s.notificationSettings == NotificationSettings())
        #expect(s.pollInterval == PollPolicy.defaultInterval)

        s.setNotificationSettings(NotificationSettings(bannersEnabled: false, playSound: false))
        s.setPollInterval(5)
        s.setGuardCheckPatterns([" required-commit ", "", "Required-Commit", "needs-rebase"])

        #expect(s.pollInterval == PRStore.minimumPollInterval)
        #expect(s.guardCheckPatterns == ["required-commit", "needs-rebase"])
        let saved = try! store.load()!
        #expect(saved.notifications?.bannersEnabled == false)
        #expect(saved.pollInterval == 30)
        #expect(saved.guardCheckPatterns == ["required-commit", "needs-rebase"])

        let reloaded = PRStore(dependencies: deps)
        #expect(reloaded.notificationSettings.playSound == false)
        #expect(reloaded.pollInterval == 30)
    }

    @Test func guardPatternsReclassifyImmediately() async {
        let p = pr(state: .blocked, checks: [check("build"), check("needs-rebase", .failed)])
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(prs: [p]), config: config, views: SampleData.views))
        await s.refresh()
        #expect(s.pullRequests.first?.info.status.kind == .ciFailed)
        s.setGuardCheckPatterns(["needs-rebase"])
        #expect(s.pullRequests.first?.info.status.kind == .blockedByRequiredCheck)
    }
}
