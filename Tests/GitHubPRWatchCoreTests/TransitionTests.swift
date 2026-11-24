import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct TransitionTests {
    let detector = TransitionDetector()
    let everything = SavedView(name: "Everything", rule: FilterRule(match: .all, []), notify: Set(EventKind.allCases))

    /// Runs the detector over a sequence of polls, one minute apart, and returns each poll's events.
    func run(_ polls: [[PullRequest]], views: [SavedView]? = nil, start: TransitionSnapshot? = nil) -> [[PREvent]] {
        var snapshot = start
        var result: [[PREvent]] = []
        for (i, current) in polls.enumerated() {
            let (events, next) = detector.detect(previous: snapshot, current: current, viewer: me, views: views ?? [everything], now: minutes(Double(i)))
            result.append(events)
            snapshot = next
        }
        return result
    }

    func kinds(_ events: [PREvent]) -> [EventKind] { events.map(\.kind) }

    // MARK: Baseline

    @Test func firstFetchIsABaseline() {
        let polls = run([[pr(checks: [check("ci", .failed)]), pr("PR_2", reviewRequests: [.user(me)])]])
        #expect(polls[0].isEmpty)
    }

    @Test func noChangeNoEvents() {
        let p = pr(checks: [check("ci")])
        let polls = run([[p], [p], [p]])
        #expect(polls.allSatisfy { $0.isEmpty })
    }

    @Test func relaunchWithPersistedSnapshotDoesNotRenotify() throws {
        let store = InMemoryDocumentStore<TransitionSnapshot>()
        let running = pr(checks: [check("ci", .running)])
        let passed = pr(checks: [check("ci")])
        let (_, s1) = detector.detect(previous: nil, current: [running], viewer: me, views: [everything], now: t0)
        try store.save(s1)
        let (e2, s2) = detector.detect(previous: try store.load(), current: [passed], viewer: me, views: [everything], now: minutes(1))
        #expect(kinds(e2) == [.ciReady])
        try store.save(s2)
        // Relaunch: a fresh detector reads the saved snapshot and sees nothing new.
        let (e3, _) = TransitionDetector().detect(previous: try store.load(), current: [passed], viewer: me, views: [everything], now: minutes(2))
        #expect(e3.isEmpty)
    }

    @Test func snapshotSurvivesJSON() throws {
        let p = pr(reviewRequests: [.team("acme/x")], queue: MergeQueueEntry(position: 1), checks: [check("ci")])
        let (_, s) = detector.detect(previous: nil, current: [p], viewer: me, views: BuiltInViews.all, now: t0)
        let data = try JSONCoding.encoder.encode(s)
        #expect(try JSONCoding.decoder.decode(TransitionSnapshot.self, from: data) == s)
    }

    @Test func staleSnapshotIsABaseline() {
        let (_, s) = detector.detect(previous: nil, current: [pr(checks: [check("ci", .running)])], viewer: me, views: [everything], now: t0)
        let (events, _) = detector.detect(previous: s, current: [pr(checks: [check("ci")])], viewer: me, views: [everything], now: t0.addingTimeInterval(7 * 3600))
        #expect(events.isEmpty)
    }

    @Test func otherViewersSnapshotIsABaseline() {
        let (_, s) = detector.detect(previous: nil, current: [pr(checks: [check("ci", .running)])], viewer: "apark", views: [everything], now: t0)
        let (events, _) = detector.detect(previous: s, current: [pr(checks: [check("ci")])], viewer: me, views: [everything], now: minutes(1))
        #expect(events.isEmpty)
    }

    // MARK: CI finished

    @Test func ciFinishedGreenAndReady() {
        let polls = run([[pr(checks: [check("ci", .running, start: -50)])], [pr(checks: [check("ci", start: -50, end: 0)])]])
        #expect(kinds(polls[1]) == [.ciReady])
        #expect(polls[1][0].detail.ciDuration.map { abs($0 - 3000) < 0.001 } == true)
        #expect(polls[1][0].detail.totalChecks == 1)
    }

    @Test func ciFinishedGreenButBehind() {
        let polls = run([[pr(state: .behind, checks: [check("ci", .running)])], [pr(state: .behind, checks: [check("ci")])]])
        #expect(kinds(polls[1]) == [.ciBlocked])
        #expect(polls[1][0].detail.blockReason == .behindBase(base: "main"))
    }

    @Test func ciFinishedGreenButGuardFailing() {
        let before = pr(state: .blocked, checks: [check("build", .running), check("required-commit", .failed)])
        let after = pr(state: .blocked, checks: [check("build"), check("required-commit", .failed)])
        let polls = run([[before], [after]])
        #expect(kinds(polls[1]) == [.ciBlocked])
        #expect(polls[1][0].detail.blockReason == .requiredCheck(names: ["required-commit"]))
    }

    @Test func ciFinishedFailedNamesChecks() {
        let before = pr(checks: [check("e2e-chrome", .running), check("lint", .failed), check("build")])
        let after = pr(checks: [check("e2e-chrome", .failed), check("lint", .failed), check("build")])
        let polls = run([[before], [after]])
        #expect(kinds(polls[1]) == [.ciFailed])
        #expect(polls[1][0].detail.failingChecks == ["e2e-chrome", "lint"])
        #expect(polls[1][0].detail.totalChecks == 3)
    }

    @Test func ciNotFinishedWhileSomethingRuns() {
        let polls = run([[pr(checks: [check("a", .running), check("b", .running)])], [pr(checks: [check("a", .failed), check("b", .running)])]])
        #expect(polls[1].isEmpty)
    }

    @Test func ciPassedButWaitingOnReview() {
        let polls = run([
            [pr(decision: .reviewRequired, state: .blocked, checks: [check("ci", .running)])],
            [pr(decision: .reviewRequired, state: .blocked, checks: [check("ci")])],
        ])
        #expect(kinds(polls[1]) == [.ciPassed])
    }

    @Test func newHeadThatFinishedBetweenPollsCounts() {
        let polls = run([[pr(head: "h1", checks: [check("ci", .failed)])], [pr(head: "h2", checks: [check("ci")])]])
        #expect(kinds(polls[1]) == [.ciReady])
    }

    @Test func rerunOnSameHeadNotifiesAgain() {
        let polls = run([
            [pr(checks: [check("ci", .failed)])],
            [pr(checks: [check("ci", .running)])],
            [pr(checks: [check("ci")])],
        ])
        #expect(polls[1].isEmpty)
        #expect(kinds(polls[2]) == [.ciReady])
    }

    @Test func noCIEventWithoutEarlierDetail() {
        // The PR had no check detail before (it matched no view), so we can't say CI "finished".
        let polls = run([[pr()], [pr(checks: [check("ci")])]])
        #expect(polls[1].isEmpty)
    }

    @Test func noCIEventWithZeroChecks() {
        let polls = run([[pr(checks: [check("ci", .running)])], [pr(head: "h2", checks: [])]])
        #expect(polls[1].isEmpty)
    }

    // MARK: Merge queue

    @Test func enteredMergeQueue() {
        let polls = run([[pr()], [pr(queue: MergeQueueEntry(position: 2, queueLength: 6))]])
        #expect(kinds(polls[1]) == [.enteredMergeQueue])
        #expect(polls[1][0].detail.queuePosition == 3)
        #expect(polls[1][0].detail.queueLength == 6)
    }

    @Test func droppedFromMergeQueueWhileOpen() {
        let removal = MergeQueueRemoval(reason: "MERGE_CONFLICT", at: minutes(1))
        let polls = run([
            [pr(queue: MergeQueueEntry(position: 1, queueLength: 6))],
            [pr(mergeable: .conflicting, state: .dirty, checks: [], removal: removal)],
        ])
        #expect(kinds(polls[1]) == [.droppedFromMergeQueue])
        #expect(polls[1][0].detail.queuePosition == 2)
        #expect(polls[1][0].detail.reason == "MERGE_CONFLICT")
    }

    @Test func mergedOrClosedPRNeverEmitsDropped() {
        // The PR left the open set: merged by the queue, or closed.
        let polls = run([[pr(queue: MergeQueueEntry(position: 0)), pr("PR_2", number: 2)], [pr("PR_2", number: 2)]])
        #expect(polls[1].isEmpty)
    }

    @Test func mergedPRThatComesBackDoesNotEmitDropped() {
        // Gone for a poll (closed), then reopened without a queue entry: no queue history carried.
        let polls = run([[pr(queue: MergeQueueEntry(position: 0))], [], [pr()]])
        #expect(polls[1].isEmpty)
        #expect(!kinds(polls[2]).contains(.droppedFromMergeQueue))
        #expect(kinds(polls[2]) == [.newMatch])
    }

    @Test func queueDropIsRecordedForTheClassifierAndClearedLater() {
        let detector = TransitionDetector()
        let views = [everything]
        let (_, s1) = detector.detect(previous: nil, current: [pr(queue: MergeQueueEntry(position: 0))], viewer: me, views: views, now: t0)
        let (_, s2) = detector.detect(previous: s1, current: [pr()], viewer: me, views: views, now: minutes(1))
        #expect(s2.queueDrops["PR_1"]?.headSHA == "h1")
        #expect(s2.queueDrops["PR_1"]?.position == 1)
        // Still out of the queue, same head: kept.
        let (_, s3) = detector.detect(previous: s2, current: [pr()], viewer: me, views: views, now: minutes(2))
        #expect(s3.queueDrops["PR_1"] != nil)
        // A new commit clears it.
        let (_, s4) = detector.detect(previous: s3, current: [pr(head: "h2")], viewer: me, views: views, now: minutes(3))
        #expect(s4.queueDrops["PR_1"] == nil)
        // Re-entering the queue clears it.
        let (_, s5) = detector.detect(previous: s3, current: [pr(queue: MergeQueueEntry(position: 0))], viewer: me, views: views, now: minutes(3))
        #expect(s5.queueDrops["PR_1"] == nil)
        // Closing clears it.
        let (_, s6) = detector.detect(previous: s3, current: [], viewer: me, views: views, now: minutes(3))
        #expect(s6.queueDrops.isEmpty)
    }

    // MARK: Reviews

    @Test func approved() {
        let polls = run([
            [pr(decision: .reviewRequired)],
            [pr(latestReviews: [Review(author: "apark", state: .approved)], decision: .approved)],
            [pr(latestReviews: [Review(author: "apark", state: .approved)], decision: .approved)],
        ])
        #expect(kinds(polls[1]) == [.approved])
        #expect(polls[1][0].detail.actor == "apark")
        #expect(polls[2].isEmpty)
    }

    @Test func changesRequestedByEachNewReviewer() {
        let polls = run([
            [pr(decision: .reviewRequired)],
            [pr(latestReviews: [Review(author: "srivera", state: .changesRequested)], decision: .changesRequested)],
            [pr(latestReviews: [Review(author: "srivera", state: .changesRequested), Review(author: "apark", state: .changesRequested)], decision: .changesRequested)],
            [pr(latestReviews: [Review(author: "srivera", state: .changesRequested), Review(author: "apark", state: .changesRequested)], decision: .changesRequested)],
        ])
        #expect(kinds(polls[1]) == [.changesRequested])
        #expect(polls[1][0].detail.actor == "srivera")
        #expect(kinds(polls[2]) == [.changesRequested])
        #expect(polls[2][0].detail.actor == "apark")
        #expect(polls[3].isEmpty)
    }

    @Test func reviewRequestedFromMe() {
        let polls = run([
            [pr(author: "apark", decision: .reviewRequired)],
            [pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired)],
            [pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired)],
        ])
        #expect(kinds(polls[1]) == [.reviewRequested])
        #expect(polls[1][0].detail.actor == "apark")
        #expect(polls[2].isEmpty)
    }

    @Test func newPRWithReviewRequestFromMe() {
        let polls = run([[], [pr(author: "apark", reviewRequests: [.user(me)])]], views: [BuiltInViews.needsMyReview])
        #expect(kinds(polls[1]) == [.reviewRequested])
        #expect(polls[1][0].viewName == "Needs my review")
    }

    // MARK: Views

    @Test func newMatchForAView() {
        let watch = BuiltInViews.watchlist(["tbrandt"])
        let polls = run([[pr()], [pr(), pr("PR_2", number: 2, author: "tbrandt")], [pr(), pr("PR_2", number: 2, author: "tbrandt")]], views: [watch])
        #expect(kinds(polls[1]) == [.newMatch])
        #expect(polls[1][0].pr.id == "PR_2")
        #expect(polls[1][0].viewID == BuiltInViews.watchlistID)
        #expect(polls[2].isEmpty)
    }

    @Test func existingPRThatStartsMatchingIsNew() {
        let view = SavedView(name: "QA", rule: FilterRule(match: .all, [.predicate(.label(["qa"]))]), notify: [.newMatch])
        let polls = run([[pr()], [pr(labels: ["qa"])]], views: [view])
        #expect(kinds(polls[1]) == [.newMatch])
    }

    @Test func editingAViewRuleIsABaselineForThatView() {
        let detector = TransitionDetector()
        var view = BuiltInViews.watchlist(["tbrandt"])
        let prs = [pr(author: "tbrandt"), pr("PR_2", number: 2, author: "nhaddad")]
        let (_, s1) = detector.detect(previous: nil, current: prs, viewer: me, views: [view], now: t0)
        view.rule = BuiltInViews.watchlist(["tbrandt", "nhaddad"]).rule
        let (events, s2) = detector.detect(previous: s1, current: prs, viewer: me, views: [view], now: minutes(1))
        #expect(events.isEmpty)
        let (later, _) = detector.detect(previous: s2, current: prs + [pr("PR_3", number: 3, author: "nhaddad")], viewer: me, views: [view], now: minutes(2))
        #expect(kinds(later) == [.newMatch])
    }

    @Test func newViewIsABaseline() {
        let detector = TransitionDetector()
        let (_, s1) = detector.detect(previous: nil, current: [pr(author: "tbrandt")], viewer: me, views: [], now: t0)
        let (events, _) = detector.detect(previous: s1, current: [pr(author: "tbrandt")], viewer: me, views: [BuiltInViews.watchlist(["tbrandt"])], now: minutes(1))
        #expect(events.isEmpty)
    }

    @Test func eventsGoToTheFirstMatchingViewThatWantsThem() {
        let quiet = SavedView(name: "Quiet", rule: FilterRule(match: .all, []), notify: [])
        let mine = BuiltInViews.mine
        let agents = BuiltInViews.agentPRs(["jlin-agent"])
        let before = pr(author: "jlin-agent", assignees: [me], checks: [check("ci", .running)])
        let after = pr(author: "jlin-agent", assignees: [me], checks: [check("ci")])
        let polls = run([[before], [after]], views: [quiet, agents, mine])
        #expect(polls[1].count == 1)
        #expect(polls[1][0].viewName == "Agent PRs")
    }

    @Test func noEventWhenNoViewWantsIt() {
        let quiet = SavedView(name: "Quiet", rule: FilterRule(match: .all, []), notify: [.newMatch])
        let polls = run([[pr(checks: [check("ci", .running)])], [pr(checks: [check("ci")])]], views: [quiet])
        #expect(polls[1].isEmpty)
    }

    @Test func noEventForPRsOutsideEveryView() {
        let polls = run([[pr(author: "apark", checks: [check("ci", .running)])], [pr(author: "apark", checks: [check("ci")])]], views: [BuiltInViews.mine])
        #expect(polls[1].isEmpty)
    }

    @Test func severalEventsInOnePoll() {
        let before = pr(decision: .reviewRequired, checks: [check("ci", .running)])
        let after = pr(latestReviews: [Review(author: "apark", state: .approved)], decision: .approved, queue: MergeQueueEntry(position: 0), checks: [check("ci")])
        let polls = run([[before], [after]])
        #expect(Set(kinds(polls[1])) == [.enteredMergeQueue, .ciPassed, .approved])
    }

    @Test func eventIDsAreUnique() {
        let polls = run([[pr(decision: .reviewRequired, checks: [check("ci", .running)])], [pr(checks: [check("ci")])]])
        let ids = polls[1].map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
