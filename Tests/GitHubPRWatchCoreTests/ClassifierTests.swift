import Foundation
import Testing
@testable import GitHubPRWatchCore

/// One test per row of the decision table in `PRClassifier`: the status, the card's text,
/// and the lane. Then the precedence between lanes, pair by pair, and that the lane never
/// depends on who is looking.
@Suite struct ClassifierTests {
    let ctx = ClassificationContext(now: t0)

    func classify(_ p: PullRequest, viewer: String = me, context: ClassificationContext? = nil) -> StatusInfo {
        PRClassifier.classify(p, viewer: viewer, context: context ?? ctx)
    }

    @Test func row1Draft() {
        let info = classify(pr(draft: true, checks: [check("ci", .failed)]))
        #expect(info.status == .draft)
        #expect(info.lane == .inReview)
        #expect(info.headline == "Draft")
        // A review request doesn't change a draft's card.
        #expect(classify(pr(author: "apark", reviewRequests: [.user(me)], draft: true)).status == .draft)
    }

    @Test func row2InMergeQueue() {
        let entry = MergeQueueEntry(position: 2, state: .awaitingChecks, estimatedTimeToMerge: 720, queueLength: 7)
        let info = classify(pr(queue: entry, checks: [check("ci", .running)]))
        #expect(info.status.kind == .inMergeQueue)
        #expect(info.lane == .mergeQueue)
        #expect(info.headline == "In merge queue · 3 of 7")
        #expect(info.detail == "Merging in ~12m")
    }

    @Test func row2QueueWithoutLength() {
        let info = classify(pr(queue: MergeQueueEntry(position: 0)))
        #expect(info.headline == "In merge queue · position 1")
    }

    @Test func row3DroppedFromQueue() {
        let drop = QueueDrop(at: minutes(-9), headSHA: "h1", position: 2, reason: "MERGE_CONFLICT")
        let context = ClassificationContext(now: t0, queueDrops: ["PR_1": drop])
        let info = classify(pr(), context: context)
        #expect(info.status == .droppedFromMergeQueue(reason: "MERGE_CONFLICT", at: minutes(-9)))
        #expect(info.lane == .failing)
        #expect(info.headline == "Dropped from merge queue")
        #expect(info.detail == "Merge conflict · 9m ago")
    }

    @Test func row3DropIgnoredAfterNewCommit() {
        let drop = QueueDrop(at: minutes(-9), headSHA: "old")
        let info = classify(pr(), context: ClassificationContext(now: t0, queueDrops: ["PR_1": drop]))
        #expect(info.status.kind == .readyToMerge)
        #expect(info.lane == .readyToMerge)
    }

    @Test func row4ReviewRequestedFromViewerKeepsTheFactualLane() {
        let p = pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired, state: .blocked)
        let info = classify(p)
        #expect(info.status == .reviewRequestedFromYou(author: "apark"))
        #expect(info.headline == "Review requested from you")
        #expect(info.lane == .inReview)
        // The lane is what rows 5–14 say, whoever is looking.
        let running = pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired, state: .blocked, checks: [check("ci", .running)])
        #expect(classify(running).status.kind == .reviewRequestedFromYou)
        #expect(classify(running).lane == .ciRunning)
        #expect(classify(running, viewer: "apark").status.kind == .ciRunning)
        #expect(classify(running, viewer: "apark").lane == .ciRunning)
    }

    @Test func row4TeamRequestCountsOnlyWithTeams() {
        let p = pr(author: "apark", reviewRequests: [.team("acme/platform")], decision: .reviewRequired, state: .blocked)
        #expect(classify(p).status.kind == .waitingOnReview)
        let withTeams = ClassificationContext(now: t0, viewerTeams: ["acme/platform"])
        #expect(classify(p, context: withTeams).status.kind == .reviewRequestedFromYou)
        #expect(classify(p, context: withTeams).lane == .inReview)
    }

    @Test func row5MergeConflicts() {
        let info = classify(pr(mergeable: .conflicting, state: .dirty, checks: [check("ci", .failed)]))
        #expect(info.status == .mergeConflicts(base: "main"))
        #expect(info.lane == .failing)
        #expect(info.headline == "Merge conflicts with main")
    }

    @Test func row6CIFailedNamesTwoThenCounts() {
        let one = classify(pr(state: .unstable, checks: [check("lint", .failed), check("build")]))
        #expect(one.status == .ciFailed(failing: ["lint"], total: 2))
        #expect(one.headline == "Check failed: lint")
        #expect(one.lane == .failing)

        let two = classify(pr(checks: [check("e2e-chrome", .failed, start: -36, end: -2), check("lint", .failed, start: -36, end: -30)]))
        #expect(two.headline == "2 checks failed: e2e-chrome, lint")
        #expect(two.detail == "Finished 2m ago · ran 34m")

        let four = classify(pr(checks: [check("a", .failed), check("b", .failed), check("c", .failed), check("d", .failed)]))
        #expect(four.headline == "4 checks failed: a, b +2")
    }

    @Test func row6CheckDetailForOldHeadIsIgnored() {
        let info = classify(pr(checks: [check("lint", .failed)], checksHead: "old"))
        #expect(info.status.kind == .readyToMerge)
    }

    @Test func row7CIRunningWithElapsed() {
        let info = classify(pr(author: "apark", assignees: [me], checks: [check("build", start: -23, end: -18), check("e2e", .running, start: -23)]))
        #expect(info.status == .ciRunning(elapsed: 23 * 60, finished: 1, total: 2))
        #expect(info.lane == .ciRunning)
        #expect(info.headline == "CI running · 23m")
        #expect(info.detail == "1 of 2 checks done")
    }

    @Test func row8ChangesRequested() {
        let review = Review(author: "srivera", state: .changesRequested, submittedAt: minutes(-60))
        let info = classify(pr(latestReviews: [review], decision: .changesRequested, state: .blocked, checks: [check("ci")]))
        #expect(info.status == .changesRequested(by: ["srivera"]))
        #expect(info.lane == .inReview)
        #expect(info.headline == "Changes requested by srivera")
        #expect(info.detail == "1h ago")
    }

    @Test func row9GuardCheckBlocks() {
        let info = classify(pr(state: .blocked, checks: [check("build"), check("required-commit", .failed, required: true)]))
        #expect(info.status == .greenBlocked(.requiredCheck(names: ["required-commit"])))
        #expect(info.lane == .failing)
        #expect(info.headline == "CI passed · blocked by required-commit")
        #expect(info.detail == "Needs a rebase onto main")
    }

    @Test func row9GuardPatternsAreConfigurable() {
        let p = pr(state: .blocked, checks: [check("freshness-guard", .failed)])
        #expect(classify(p).status.kind == .ciFailed)
        let context = ClassificationContext(now: t0, guardCheckPatterns: ["freshness"])
        #expect(classify(p, context: context).status.kind == .blockedByRequiredCheck)
    }

    @Test func row9GuardPlusRealFailureIsAFailure() {
        let info = classify(pr(checks: [check("required-commit", .failed), check("lint", .failed)]))
        #expect(info.status == .ciFailed(failing: ["lint"], total: 2))
        #expect(info.lane == .failing)
    }

    @Test func row10BehindBase() {
        let info = classify(pr(state: .behind, checks: [check("ci")]))
        #expect(info.status == .greenBlocked(.behindBase(base: "main")))
        #expect(info.headline == "CI passed · blocked: behind main")
        #expect(info.lane == .failing)
    }

    @Test func row11WaitingOnReview() {
        let info = classify(pr(reviewRequests: [.user("nhaddad"), .team("acme/platform")], decision: .reviewRequired, state: .blocked))
        #expect(info.status == .waitingOnReview(reviewers: ["nhaddad", "acme/platform"]))
        #expect(info.lane == .inReview)
        #expect(info.detail == "nhaddad, acme/platform")
        #expect(classify(pr(decision: .reviewRequired, state: .blocked)).detail == "No reviewer requested yet")
    }

    @Test func row12CheckingMergeability() {
        let info = classify(pr(mergeable: .unknown, state: .unknown))
        #expect(info.status == .checkingMergeability)
        #expect(info.lane == .inReview)
    }

    @Test func row13BranchProtection() {
        let info = classify(pr(state: .blocked, checks: [check("ci")]))
        #expect(info.status == .greenBlocked(.branchProtection))
        #expect(info.lane == .failing)
        #expect(info.headline == "CI passed · blocked by branch protection")
    }

    @Test func row14ReadyToMerge() {
        let info = classify(pr(checks: [check("build", end: -6)]))
        #expect(info.status == .readyToMerge(autoMerge: false))
        #expect(info.lane == .readyToMerge)
        #expect(info.headline == "Ready to merge")
        #expect(info.detail == "CI passed 6m ago · approved · no merge queue")
        #expect(info.sentence == "Ready to merge. CI passed 6m ago · approved · no merge queue.")
        // No review required and no checks: nothing blocks it.
        #expect(classify(pr(decision: nil)).lane == .readyToMerge)
    }

    @Test func row14AutoMergeStalled() {
        let info = classify(pr(autoMerge: true))
        #expect(info.status == .readyToMerge(autoMerge: true))
        #expect(info.detail.contains("auto-merge is on"))
    }

    // MARK: Precedence between lanes

    @Test func mergeQueueBeatsEverything() {
        let queue = MergeQueueEntry(position: 0)
        #expect(classify(pr(queue: queue, checks: [check("ci", .running)])).lane == .mergeQueue)
        #expect(classify(pr(queue: queue, checks: [check("ci", .failed)])).lane == .mergeQueue)
        #expect(classify(pr(decision: .reviewRequired, queue: queue)).lane == .mergeQueue)
    }

    @Test func hardFailureBeatsCIRunning() {
        // GitHub's own rollup reports a failed check as failed while others still run, and
        // the card names the failure, so the PR is Failing.
        let failed = classify(pr(checks: [check("lint", .failed), check("e2e", .running)]))
        #expect(failed.status.kind == .ciFailed)
        #expect(failed.lane == .failing)
        let conflicts = classify(pr(mergeable: .conflicting, checks: [check("e2e", .running)]))
        #expect(conflicts.lane == .failing)
    }

    @Test func ciRunningBeatsChangesRequestedAndSoftBlocks() {
        let running = [check("e2e", .running)]
        #expect(classify(pr(decision: .changesRequested, checks: running)).lane == .ciRunning)
        #expect(classify(pr(decision: .reviewRequired, state: .blocked, checks: running)).lane == .ciRunning)
        #expect(classify(pr(state: .behind, checks: running)).lane == .ciRunning)
        #expect(classify(pr(checks: running + [check("required-commit", .failed)])).lane == .ciRunning)
    }

    @Test func failedChecksBeatReview() {
        #expect(classify(pr(decision: .reviewRequired, state: .blocked, checks: [check("lint", .failed)])).lane == .failing)
        #expect(classify(pr(decision: .changesRequested, checks: [check("lint", .failed)])).lane == .failing)
    }

    @Test func changesRequestedBeatsSoftBlocks() {
        #expect(classify(pr(decision: .changesRequested, state: .behind)).lane == .inReview)
        #expect(classify(pr(decision: .changesRequested, checks: [check("required-commit", .failed)])).lane == .inReview)
    }

    @Test func softBlocksBeatWaitingOnReview() {
        #expect(classify(pr(decision: .reviewRequired, state: .behind)).lane == .failing)
        #expect(classify(pr(decision: .reviewRequired, checks: [check("required-commit", .failed)])).lane == .failing)
    }

    @Test func waitingOnReviewBeatsBranchProtection() {
        // GitHub reports BLOCKED while a required review is missing; the review is the fact.
        #expect(classify(pr(decision: .reviewRequired, state: .blocked)).lane == .inReview)
        #expect(classify(pr(decision: .approved, state: .blocked)).lane == .failing)
    }

    @Test func laneNeverDependsOnTheViewer() {
        let prs = [
            pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired, state: .blocked),
            pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired, state: .blocked, checks: [check("lint", .failed)]),
            pr(author: "apark", assignees: [me], state: .behind),
            pr(author: me, decision: .changesRequested),
            pr(author: "jlin-agent"),
        ]
        for p in prs {
            let lanes = Set([me, "apark", "jlin-agent", "nobody"].map { classify(p, viewer: $0).lane })
            #expect(lanes.count == 1)
            #expect(lanes.first == PRClassifier.classify(p, context: ctx).lane)
        }
    }

    @Test func viewerFreeClassifySkipsRow4() {
        let p = pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired, state: .blocked)
        #expect(PRClassifier.classify(p, context: ctx).status.kind == .waitingOnReview)
    }

    @Test func everyStatusKindHasATest() {
        // Keeps the table and the tests in step: a new kind needs a row above.
        #expect(PRStatus.Kind.allCases.count == 14)
    }

    @Test func formatting() {
        #expect(Formatting.duration(45) == "45s")
        #expect(Formatting.duration(23 * 60) == "23m")
        #expect(Formatting.duration(65 * 60) == "1h 5m")
        #expect(Formatting.duration(120 * 60) == "2h")
        #expect(Formatting.duration(72 * 3600) == "3d")
        #expect(Formatting.ago(minutes(-0.5), now: t0) == "now")
        #expect(Formatting.ago(minutes(-2), now: t0) == "2m ago")
        #expect(Formatting.names(["a", "b", "c"]) == "a, b +1 more")
    }
}
