import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct MenuBarSummaryTests {
    func classified(_ p: PullRequest) -> ClassifiedPR {
        ClassifiedPR(pr: p, info: PRClassifier.classify(p, viewer: me, context: ClassificationContext(now: t0)))
    }

    @Test func indicator() {
        typealias I = MenuBarIndicator
        #expect(I.make(isSignedIn: false, needsOnboarding: false, connection: .upToDate, hasChanges: true) == .signedOut)
        #expect(I.make(isSignedIn: true, needsOnboarding: true, connection: .idle, hasChanges: false) == .signedOut)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .tokenRejected, hasChanges: true) == .signedOut)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .offline, hasChanges: true) == .offline)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .failed("x"), hasChanges: false) == .offline)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .rateLimited(until: nil), hasChanges: true) == .changed)
        #expect(I.make(isSignedIn: true, needsOnboarding: false, connection: .upToDate, hasChanges: false) == .calm)
        #expect(I.changed.accessibilityText == "GitHub PR Watch, pull requests changed since you last looked")
    }

    @Test func groupsSkipEmptyLanesInOrder() {
        let prs = [
            classified(pr("Q", queue: MergeQueueEntry(position: 0))),
            classified(pr("A", checks: [check("ci", .running)])),
            classified(pr("F", checks: [check("lint", .failed)])),
            classified(pr("D", draft: true)),
        ]
        let groups = MenuBarSummary.groups(prs)
        #expect(groups.map(\.lane) == [.ciRunning, .failing, .inReview, .mergeQueue])
        #expect(MenuBarSummary.groups([]).isEmpty)
        #expect(MenuBarSummary.expandedByDefault == [.failing, .readyToMerge])
    }

    @Test func emptySentence() {
        #expect(MenuBarSummary.emptySentence(bannersOn: true)
            == "Nothing open matches your menu bar views. You'll get a banner when one changes.")
        #expect(MenuBarSummary.emptySentence(bannersOn: false) == "Nothing open matches your menu bar views.")
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
