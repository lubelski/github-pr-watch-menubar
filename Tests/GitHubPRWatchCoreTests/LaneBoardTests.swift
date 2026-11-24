import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct LaneBoardTests {
    let ctx = ClassificationContext(now: t0)

    func item(_ p: PullRequest) -> ClassifiedPR {
        ClassifiedPR(pr: p, info: PRClassifier.classify(p, viewer: me, context: ctx))
    }

    func updated(_ p: PullRequest, _ m: Double) -> PullRequest {
        var p = p
        p.updatedAt = minutes(m)
        return p
    }

    func event(_ kind: EventKind, _ p: PullRequest, at m: Double) -> PREvent {
        PREvent(kind: kind, pr: p, viewID: BuiltInViews.mineID, viewName: "Mine", occurredAt: minutes(m))
    }

    // MARK: Just finished

    @Test func ciFinishedEventHighlightsWithinWindow() {
        let a = pr("A", number: 1), b = pr("B", number: 2), c = pr("C", number: 3)
        let events = [
            event(.ciReady, a, at: -2),
            event(.ciFailed, b, at: -20), // too old
            event(.approved, c, at: -1), // not a CI event
        ]
        let result = LaneBoard.justFinished(events: events, current: [a, b, c].map(item), now: t0)
        #expect(result == ["A": minutes(-2)])
    }

    @Test func newPushClearsHighlight() {
        let old = pr("A", head: "h1")
        let now = pr("A", head: "h2")
        let result = LaneBoard.justFinished(events: [event(.ciPassed, old, at: -1)], current: [item(now)], now: t0)
        #expect(result.isEmpty)
    }

    @Test func latestFinishWinsAndWindowIsInclusive() {
        let a = pr("A")
        let events = [event(.ciFailed, a, at: -15), event(.ciReady, a, at: -3)]
        let result = LaneBoard.justFinished(events: events, current: [item(a)], now: t0)
        #expect(result["A"] == minutes(-3))
        let edge = LaneBoard.justFinished(events: [event(.ciBlocked, a, at: -15)], current: [item(a)], now: t0)
        #expect(edge["A"] == minutes(-15))
    }

    @Test func movedNoteOnlyForYourMoveAndShortWindow() {
        let ready = item(pr("A", number: 7))
        let running = item(pr("B", number: 8, checks: [check("ci", .running)]))
        let notes = LaneBoard.movedNotes(justFinished: ["A": minutes(-1), "B": minutes(-1)], board: [ready, running], now: t0)
        #expect(notes.map(\.shortRef) == ["#7"])
        #expect(LaneBoard.movedNotes(justFinished: ["A": minutes(-5)], board: [ready], now: t0).isEmpty)
    }

    // MARK: Order

    @Test func yourMoveJustFinishedFirstThenNewest() {
        let old = item(updated(pr("old", number: 1), -60))
        let new = item(updated(pr("new", number: 2), -2))
        let finished = item(updated(pr("fin", number: 3), -90))
        let sorted = LaneBoard.sorted([old, new, finished], in: .yourMove, justFinished: ["fin": minutes(-1)], now: t0)
        #expect(sorted.map(\.id) == ["fin", "new", "old"])
    }

    @Test func checkFinishCountsAsAChange() {
        // Updated long ago, but a check failed a minute ago.
        let failed = item(updated(pr("f", number: 1, checks: [check("lint", .failed, start: -30, end: -1)]), -120))
        let touched = item(updated(pr("t", number: 2), -10))
        #expect(LaneBoard.sorted([touched, failed], in: .yourMove, now: t0).map(\.id) == ["f", "t"])
    }

    @Test func ciRunningLongestFirstQueuedLast() {
        let short = item(pr("short", number: 1, checks: [check("ci", .running, start: -5)]))
        let long = item(pr("long", number: 2, checks: [check("ci", .running, start: -50)]))
        let queued = item(pr("queued", number: 3, checks: [CheckRun(name: "ci", status: .queued)]))
        let sorted = LaneBoard.sorted([queued, short, long], in: .ciRunning, now: t0)
        #expect(sorted.map(\.id) == ["long", "short", "queued"])
    }

    @Test func queueByPosition() {
        let second = item(pr("2", number: 1, queue: MergeQueueEntry(position: 1)))
        let first = item(pr("1", number: 2, queue: MergeQueueEntry(position: 0)))
        #expect(LaneBoard.sorted([second, first], in: .inMergeQueue, now: t0).map(\.id) == ["1", "2"])
    }

    @Test func waitingDraftsLast() {
        let draft = item(updated(pr("d", number: 1, draft: true), -1))
        let review = item(updated(pr("r", number: 2, decision: .reviewRequired), -100))
        #expect(LaneBoard.sorted([draft, review], in: .waiting, now: t0).map(\.id) == ["r", "d"])
    }

    @Test func tiesAreStable() {
        let b = item(pr("b", repo: "acme/web", number: 2))
        let a = item(pr("a", repo: "acme/web", number: 1))
        #expect(LaneBoard.sorted([b, a], in: .yourMove, now: t0).map(\.id) == ["a", "b"])
    }

    @Test func lanesAlwaysFourInOrder() {
        let groups = LaneBoard.lanes([item(pr("a"))], now: t0)
        #expect(groups.map(\.lane) == Lane.allCases)
        #expect(groups[0].pullRequests.count == 1)
    }

    // MARK: Live running time

    @Test func liveHeadlineTicks() {
        let running = item(pr(checks: [check("build", .passed, start: -23, end: -10), check("e2e", .running, start: -23)]))
        #expect(LaneBoard.liveHeadline(running, now: t0) == "CI running · 23m")
        #expect(LaneBoard.liveHeadline(running, now: minutes(7)) == "CI running · 30m")
        #expect(LaneBoard.progress(running)! == (1, 2))
        let ready = item(pr())
        #expect(LaneBoard.liveHeadline(ready, now: t0) == ready.info.headline)
        #expect(LaneBoard.progress(ready) == nil)
    }

    @Test func failingCheckLinksSkipGuardsAndMissingURLs() {
        let url = URL(string: "https://github.com/acme/web/actions/runs/1")!
        let checks = [
            CheckRun(name: "lint", status: .completed, conclusion: .failure, detailsURL: url),
            CheckRun(name: "e2e", status: .completed, conclusion: .failure),
            CheckRun(name: "required-commit", status: .completed, conclusion: .failure, detailsURL: url),
        ]
        let links = LaneBoard.failingCheckLinks(item(pr(checks: checks)))
        #expect(links.map(\.name) == ["lint"])
        #expect(links.first?.url == url)
        #expect(LaneBoard.failingCheckLinks(item(pr())).isEmpty)
    }

    // MARK: Search

    @Test func searchMatchesTitleNumberAuthorRepo() {
        var p = pr(repo: "acme/web", number: 4821, author: "jlin-agent")
        p.title = "Migrate billing settings"
        let i = item(p)
        for query in ["", "  ", "billing", "BILLING settings", "4821", "48", "#4821", "#48", "web #4821", "jlin", "acme/web"] {
            #expect(LaneBoard.matches(i, query: query), "\(query)")
        }
        for query in ["#21", "billing api", "rchen", "4822"] {
            #expect(!LaneBoard.matches(i, query: query), "\(query)")
        }
    }

    // MARK: Keyboard

    @Test func arrowsMoveWithinAndAcrossLanes() {
        let columns = [["a1", "a2", "a3"], [], ["c1"], ["d1", "d2"]]
        #expect(LaneBoard.move(nil, .down, columns: columns) == "a1")
        #expect(LaneBoard.move("gone", .left, columns: columns) == "a1")
        #expect(LaneBoard.move("a1", .up, columns: columns) == "a1")
        #expect(LaneBoard.move("a1", .down, columns: columns) == "a2")
        #expect(LaneBoard.move("a3", .down, columns: columns) == "a3")
        #expect(LaneBoard.move("a3", .right, columns: columns) == "c1") // skips the empty lane, clamps the row
        #expect(LaneBoard.move("c1", .right, columns: columns) == "d1")
        #expect(LaneBoard.move("d2", .right, columns: columns) == "d2")
        #expect(LaneBoard.move("d2", .left, columns: columns) == "c1")
        #expect(LaneBoard.move(nil, .down, columns: [[], []]) == nil)
    }
}

@MainActor
@Suite struct BoardSelectionTests {
    @Test func allViewsIsTheUnionOfViews() async {
        let config = AppConfig(authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api"], onboardingComplete: true)
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(), config: config, views: SampleData.views))
        await s.refresh()
        let all = Set(s.boardPullRequests(for: PRStore.allViewsID).map(\.id))
        let union = Set(s.views.flatMap { s.pullRequests(in: $0.id) }.map(\.id))
        #expect(!all.isEmpty)
        #expect(all == union)
        #expect(s.boardPullRequests(for: BuiltInViews.mineID) == s.pullRequests(in: BuiltInViews.mineID))
        #expect(s.yourMoveCount(for: BuiltInViews.mineID) == s.pullRequests(in: BuiltInViews.mineID).filter { $0.info.lane == .yourMove }.count)
        #expect(!s.views.contains { $0.id == PRStore.allViewsID })
    }
}
