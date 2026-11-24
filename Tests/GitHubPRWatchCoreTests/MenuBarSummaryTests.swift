import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct MenuBarSummaryTests {
    func classified(_ p: PullRequest) -> ClassifiedPR {
        ClassifiedPR(pr: p, info: PRClassifier.classify(p, viewer: me, context: ClassificationContext(now: t0)))
    }

    @Test func indicator() {
        typealias I = MenuBarIndicator
        #expect(I.make(isSignedIn: false, needsOnboarding: false, connection: .upToDate, yourMoveCount: 3) == .signedOut)
        #expect(I.make(isSignedIn: true, needsOnboarding: true, connection: .idle, yourMoveCount: 0) == .signedOut)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .tokenRejected, yourMoveCount: 2) == .signedOut)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .offline, yourMoveCount: 2) == .offline)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .failed("x"), yourMoveCount: 0) == .offline)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .rateLimited(until: nil), yourMoveCount: 2) == .needsYou(2))
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .upToDate, yourMoveCount: 0) == .calm)
        #expect(I.needsYou(1).accessibilityText == "GitHub PR Watch, 1 pull request needs you")
    }

    @Test func waitingSummaryCountsByKind() {
        let prs = [
            classified(pr("A", checks: [check("ci", .running)])),
            classified(pr("B", checks: [check("ci", .running)])),
            classified(pr("C", queue: MergeQueueEntry(position: 0))),
            classified(pr("D", decision: .reviewRequired, state: .blocked)),
            classified(pr("E", draft: true)),
            classified(pr("F", author: "apark")), // ready, but someone else's move
            classified(pr("G")), // your move: not counted
        ]
        #expect(MenuBarSummary.waitingSummary(prs) == "2 in CI, 1 in queue, 1 in review, 1 draft, 1 on others")
        #expect(MenuBarSummary.waitingSummary([]) == "")
    }

    @Test func calmSentence() {
        let waiting = [classified(pr("A", checks: [check("ci", .running)]))]
        #expect(MenuBarSummary.calmSentence(waiting: waiting, bannersOn: true)
            == "1 pull request is in flight: 1 in CI. You'll get a banner the moment one needs you.")
        #expect(MenuBarSummary.calmSentence(waiting: waiting, bannersOn: false) == "1 pull request is in flight: 1 in CI.")
        #expect(MenuBarSummary.calmSentence(waiting: [], bannersOn: true) == "No open pull requests in your menu bar views.")
    }

    @Test func yourMoveNewestChangeFirst() {
        let old = classified(pr("OLD"))
        let newer = classified(pr("NEW"))
        let waiting = classified(pr("W", checks: [check("ci", .running)]))
        let event = PREvent(kind: .ciReady, pr: old.pr, viewID: UUID(), viewName: "Mine", occurredAt: minutes(1))
        let order = MenuBarSummary.yourMoveOrder([newer, old, waiting], recentEvents: [event])
        #expect(order.map(\.id) == ["OLD", "NEW"])
    }

    @Test func justChangedWindow() {
        let e1 = PREvent(kind: .ciReady, pr: pr("A"), viewID: UUID(), viewName: "Mine", occurredAt: minutes(-2))
        let e2 = PREvent(kind: .ciReady, pr: pr("B"), viewID: UUID(), viewName: "Mine", occurredAt: minutes(-10))
        #expect(MenuBarSummary.justChanged([e1, e2], now: t0) == ["A"])
    }

    @Test func liveCIHeadline() {
        let running = classified(pr("A", checks: [check("ci", .running, start: -23), check("lint", start: -30, end: -25)]))
        #expect(MenuBarSummary.liveCIHeadline(running, now: t0.addingTimeInterval(10)) == "CI running · 30m 10s")
        #expect(MenuBarSummary.liveCIHeadline(classified(pr("B")), now: t0) == nil)
    }

    @Test func elapsed() {
        #expect(MenuBarSummary.elapsed(45) == "45s")
        #expect(MenuBarSummary.elapsed(23 * 60 + 10) == "23m 10s")
        #expect(MenuBarSummary.elapsed(3900) == "1h 5m")
        #expect(MenuBarSummary.elapsed(-5) == "0s")
    }
}
