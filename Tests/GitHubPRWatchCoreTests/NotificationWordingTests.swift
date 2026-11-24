import Foundation
import Testing
@testable import GitHubPRWatchCore

/// The banner wording from Figma section 5.
@Suite struct NotificationWordingTests {
    func content(_ kind: EventKind, _ p: PullRequest, view: String = "Mine", _ detail: EventDetail = .init()) -> NotificationContent {
        NotificationWording.content(for: PREvent(kind: kind, pr: p, viewID: UUID(), viewName: view, occurredAt: t0, detail: detail))
    }

    var api1293: PullRequest {
        PullRequest(id: "X", repo: "acme/api", number: 1293, title: "Backfill invoice currency column", author: "jlin-agent", reviewDecision: .approved)
    }

    @Test func readyToMerge() {
        let c = content(.ciReady, api1293, view: "Agent PRs", EventDetail(ciDuration: 52 * 60))
        #expect(c.title == "Ready to merge: api #1293")
        #expect(c.subtitle == "Agent PRs")
        #expect(c.body == "Backfill invoice currency column. CI passed in 52m and it is approved. Nothing else will merge it, so merge it yourself.")
        #expect(c.url.absoluteString == "https://github.com/acme/api/pull/1293")
        #expect(c.threadID == "acme/api#1293")
    }

    @Test func ciFailed() {
        let p = PullRequest(id: "X", repo: "acme/web", number: 4821, title: "Migrate billing settings to new form kit", author: me)
        let c = content(.ciFailed, p, EventDetail(failingChecks: ["e2e-chrome", "lint"], totalChecks: 18, ciDuration: 34 * 60))
        #expect(c.title == "CI failed: e2e-chrome, lint")
        #expect(c.body == "web #4821 Migrate billing settings to new form kit. 2 of 18 checks failed after 34m.")
        let many = content(.ciFailed, p, EventDetail(failingChecks: ["a", "b", "c", "d"]))
        #expect(many.title == "CI failed: a, b +2 more")
    }

    @Test func blockedByGuard() {
        let p = PullRequest(id: "X", repo: "acme/api", number: 1284, title: "Rate limit export endpoint per org", author: me)
        let c = content(.ciBlocked, p, EventDetail(blockReason: .requiredCheck(names: ["required-commit"])))
        #expect(c.title == "Blocked by required-commit")
        #expect(c.body == "api #1284 Rate limit export endpoint per org. CI passed, but the guard wants a rebase onto main.")
        #expect(content(.ciBlocked, p, EventDetail(blockReason: .behindBase(base: "main"))).title == "Blocked: behind main")
        #expect(content(.ciBlocked, p, EventDetail(blockReason: .branchProtection)).title == "Blocked: api #1284")
    }

    @Test func droppedFromQueue() {
        let p = PullRequest(id: "X", repo: "acme/web", number: 4809, title: "Fix flaky date picker test in Safari", author: "jlin-agent")
        let c = content(.droppedFromMergeQueue, p, view: "Agent PRs", EventDetail(queuePosition: 2, queueLength: 6, reason: "MERGE_CONFLICT"))
        #expect(c.title == "Dropped from queue: web #4809")
        #expect(c.body == "Fix flaky date picker test in Safari. Removed at position 2 of 6: merge conflict.")
        #expect(content(.droppedFromMergeQueue, p).body == "Fix flaky date picker test in Safari. Removed.")
    }

    @Test func reviewRequested() {
        let p = PullRequest(
            id: "X", repo: "acme/web", number: 4835, title: "Dark mode tokens for charts", author: "apark", headSHA: "h",
            checks: CheckSummary(headSHA: "h", rollup: nil, checks: [check("ci", .running)])
        )
        let c = content(.reviewRequested, p, view: "Needs my review", EventDetail(actor: "apark"))
        #expect(c.title == "apark requested your review")
        #expect(c.subtitle == "Needs my review")
        #expect(c.body == "web #4835 Dark mode tokens for charts · CI running")
    }

    @Test func newInView() {
        let p = PullRequest(id: "X", repo: "acme/api", number: 1295, title: "Trace sampling config per service", author: "tbrandt")
        let c = content(.newMatch, p, view: "Watchlist")
        #expect(c.title == "New in Watchlist: api #1295")
        #expect(c.body == "tbrandt opened Trace sampling config per service. Not a draft.")
    }

    @Test func otherKinds() {
        let p = PullRequest(id: "X", repo: "acme/web", number: 7, title: "T", author: me)
        #expect(content(.enteredMergeQueue, p, EventDetail(queuePosition: 3, queueLength: 7)).body == "T. Position 3 of 7.")
        #expect(content(.approved, p, EventDetail(actor: "apark")).title == "Approved: web #7")
        #expect(content(.changesRequested, p, EventDetail(actor: "srivera")).title == "srivera requested changes")
        #expect(content(.changesRequested, p).title == "Changes requested: web #7")
        #expect(content(.ciPassed, p, EventDetail(ciDuration: 600)).body == "T. CI passed in 10m.")
    }

    @Test func everyKindHasWording() {
        let p = PullRequest(id: "X", repo: "acme/web", number: 7, title: "T", author: me)
        for kind in EventKind.allCases {
            let c = content(kind, p)
            #expect(!c.title.isEmpty && !c.body.isEmpty, "\(kind)")
        }
    }
}
