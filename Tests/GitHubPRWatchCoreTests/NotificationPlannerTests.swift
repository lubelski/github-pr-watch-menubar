import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct NotificationPlannerTests {
    let view = UUID()

    func event(_ kind: EventKind, _ id: String, number: Int = 1, repo: String = "acme/web", view name: String = "Mine") -> PREvent {
        PREvent(kind: kind, pr: pr(id, repo: repo, number: number), viewID: view, viewName: name, occurredAt: t0)
    }

    @Test func fewEventsEachGetABanner() {
        let plan = NotificationPlanner.plan([event(.ciReady, "A"), event(.ciFailed, "B")])
        #expect(plan.banners.map(\.pr.id) == ["B", "A"])
        #expect(plan.summary == nil)
        #expect(plan.contents.count == 2)
    }

    @Test func exactlyTheCapIsNotSummarized() {
        let plan = NotificationPlanner.plan([event(.ciReady, "A"), event(.ciReady, "B"), event(.ciReady, "C")], maxBanners: 3)
        #expect(plan.banners.count == 3)
        #expect(plan.summary == nil)
    }

    @Test func burstIsCappedWithOneSummary() {
        let events = (1...6).map { event(.ciReady, "PR_\($0)", number: 1290 + $0) }
        let plan = NotificationPlanner.plan(events, maxBanners: 3)
        #expect(plan.banners.map(\.pr.id) == ["PR_1", "PR_2"])
        #expect(plan.summarized.map(\.pr.id) == ["PR_3", "PR_4", "PR_5", "PR_6"])
        #expect(plan.contents.count == 3)
        let summary = try! #require(plan.summary)
        #expect(summary.title == "4 more pull requests changed")
        #expect(summary.body == "web #1293 ready to merge, web #1294 ready to merge, web #1295 ready to merge +1 more.")
        #expect(summary.subtitle == "Mine")
        #expect(summary.opensApp)
        #expect(summary.threadID == "summary")
        #expect(plan.pullRequestCount == 6)
    }

    @Test func mostImportantEventsWinTheBannerSlots() {
        let events = [
            event(.newMatch, "A"), event(.approved, "B"), event(.ciPassed, "C"), event(.ciFailed, "D"),
        ]
        let plan = NotificationPlanner.plan(events, maxBanners: 3)
        #expect(plan.banners.map(\.kind) == [.ciFailed, .approved])
        #expect(plan.summarized.map(\.kind) == [.ciPassed, .newMatch])
    }

    @Test func onePRKeepsOnlyItsMostImportantEvent() {
        let events = [event(.approved, "A"), event(.ciReady, "A"), event(.enteredMergeQueue, "A"), event(.newMatch, "B")]
        let plan = NotificationPlanner.plan(events)
        #expect(plan.banners.map(\.kind) == [.ciReady, .newMatch])
        #expect(plan.banners.map(\.pr.id) == ["A", "B"])
    }

    @Test func tiesKeepArrivalOrder() {
        let events = [event(.ciFailed, "Z"), event(.ciFailed, "A"), event(.ciFailed, "M")]
        #expect(NotificationPlanner.mostImportantPerPR(events).map(\.pr.id) == ["Z", "A", "M"])
    }

    @Test func capOfOneIsOnlyASummary() {
        let plan = NotificationPlanner.plan([event(.ciReady, "A"), event(.ciReady, "B")], maxBanners: 1)
        #expect(plan.banners.isEmpty)
        #expect(plan.summary?.title == "2 pull requests changed")
        #expect(plan.headline?.pr.id == "A")
    }

    @Test func summaryNamesEachView() {
        let events = [
            event(.ciFailed, "A", view: "Mine"), event(.ciFailed, "B", view: "Agent PRs"),
            event(.ciFailed, "C", view: "Mine"), event(.ciFailed, "D", view: "Watchlist"),
        ]
        let plan = NotificationPlanner.plan(events, maxBanners: 2)
        #expect(plan.summary?.subtitle == "Agent PRs, Mine, Watchlist")
        #expect(plan.summary?.title == "3 more pull requests changed")
    }

    @Test func emptyBatch() {
        let plan = NotificationPlanner.plan([])
        #expect(plan.isEmpty)
        #expect(plan.contents.isEmpty)
        #expect(NotificationWording.menuBarLabel(for: plan) == nil)
    }

    @Test func shortLabels() {
        #expect(NotificationWording.shortLabel(for: event(.ciReady, "A", number: 1293)) == "#1293 ready to merge")
        #expect(NotificationWording.shortLabel(for: event(.ciFailed, "A", number: 4821), includeRepo: true) == "web #4821 CI failed")
        #expect(NotificationWording.shortLabel(for: event(.newMatch, "A", number: 1295, view: "Watchlist")) == "#1295 new in Watchlist")
        for kind in EventKind.allCases {
            #expect(!NotificationWording.shortLabel(for: event(kind, "A")).isEmpty)
        }
    }

    @Test func menuBarLabelCountsOtherPRs() {
        let one = NotificationPlanner.plan([event(.ciReady, "A", number: 1293)])
        #expect(NotificationWording.menuBarLabel(for: one) == "#1293 ready to merge")
        let many = NotificationPlanner.plan([event(.ciReady, "A", number: 1293), event(.ciFailed, "B", number: 4821), event(.approved, "A", number: 1293)])
        #expect(NotificationWording.menuBarLabel(for: many) == "#4821 CI failed +1")
    }

    @MainActor @Test func recordingNotifierReceivesPlannedBanners() {
        let notifier = RecordingNotifier()
        let events = (1...5).map { event(.ciReady, "PR_\($0)", number: $0) }
        notifier.post(events, options: DeliveryOptions(sound: false))
        #expect(notifier.posted.count == 3)
        #expect(notifier.posted.last?.title == "3 more pull requests changed")
        #expect(notifier.lastOptions?.sound == false)
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"playSound": false}"#.utf8))
        #expect(decoded == NotificationSettings(playSound: false))
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"watchedRepos":[],"onboardingComplete":true,"pollInterval":60,"guardCheckPatterns":[]}"#.utf8))
        #expect(config.notifications == nil)
    }
}
