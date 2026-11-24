import Foundation
import Testing
@testable import GitHubPRWatchCore

/// One test per row of the decision table in `PRClassifier`, for the owner and for someone else.
@Suite struct ClassifierTests {
    let ctx = ClassificationContext(now: t0)

    func classify(_ p: PullRequest, viewer: String = me, context: ClassificationContext? = nil) -> StatusInfo {
        PRClassifier.classify(p, viewer: viewer, context: context ?? ctx)
    }

    @Test func row1Draft() {
        let info = classify(pr(draft: true, checks: [check("ci", .failed)]))
        #expect(info.status == .draft)
        #expect(info.lane == .waiting)
        #expect(info.headline == "Draft")
    }

    @Test func row2InMergeQueue() {
        let entry = MergeQueueEntry(position: 2, state: .awaitingChecks, estimatedTimeToMerge: 720, queueLength: 7)
        let info = classify(pr(queue: entry, checks: [check("ci", .running)]))
        #expect(info.status.kind == .inMergeQueue)
        #expect(info.lane == .inMergeQueue)
        #expect(info.headline == "In merge queue · 3 of 7")
        #expect(info.detail == "Merging in ~12m")
        #expect(classify(pr(author: "apark", queue: entry)).lane == .inMergeQueue)
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
        #expect(info.lane == .yourMove)
        #expect(info.headline == "Dropped from merge queue")
        #expect(info.detail == "Merge conflict · 9m ago")
        #expect(classify(pr(author: "apark"), context: context).lane == .waiting)
    }

    @Test func row3DropIgnoredAfterNewCommit() {
        let drop = QueueDrop(at: minutes(-9), headSHA: "old")
        let info = classify(pr(), context: ClassificationContext(now: t0, queueDrops: ["PR_1": drop]))
        #expect(info.status.kind == .readyToMerge)
    }

    @Test func row4ReviewRequestedFromViewer() {
        let p = pr(author: "apark", reviewRequests: [.user(me)], decision: .reviewRequired, state: .blocked, checks: [check("ci", .running)])
        let info = classify(p)
        #expect(info.status == .reviewRequestedFromYou(author: "apark"))
        #expect(info.lane == .yourMove)
        #expect(info.headline == "Review requested from you")
        // The same PR is the author's to wait on.
        #expect(classify(p, viewer: "apark").lane == .ciRunning)
    }

    @Test func row4TeamRequestDoesNotCount() {
        let p = pr(author: "apark", reviewRequests: [.team("acme/platform")], decision: .reviewRequired, state: .blocked)
        #expect(classify(p).status.kind == .waitingOnReview)
    }

    @Test func row5MergeConflicts() {
        let info = classify(pr(mergeable: .conflicting, state: .dirty, checks: [check("ci", .failed)]))
        #expect(info.status == .mergeConflicts(base: "main"))
        #expect(info.lane == .yourMove)
        #expect(info.headline == "Merge conflicts with main")
        #expect(classify(pr(author: "apark", state: .dirty)).lane == .waiting)
    }

    @Test func row6CIFailedNamesTwoThenCounts() {
        let one = classify(pr(state: .unstable, checks: [check("lint", .failed), check("build")]))
        #expect(one.status == .ciFailed(failing: ["lint"], total: 2))
        #expect(one.headline == "Check failed: lint")
        #expect(one.lane == .yourMove)

        let two = classify(pr(checks: [check("e2e-chrome", .failed, start: -36, end: -2), check("lint", .failed, start: -36, end: -30)]))
        #expect(two.headline == "2 checks failed: e2e-chrome, lint")
        #expect(two.detail == "Finished 2m ago · ran 34m")

        let four = classify(pr(checks: [check("a", .failed), check("b", .failed), check("c", .failed), check("d", .failed)]))
        #expect(four.headline == "4 checks failed: a, b +2")
        #expect(classify(pr(author: "apark", checks: [check("a", .failed)])).lane == .waiting)
    }

    @Test func row6FailureBeatsRunning() {
        let info = classify(pr(checks: [check("lint", .failed), check("e2e", .running)]))
        #expect(info.status.kind == .ciFailed)
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
        #expect(info.lane == .yourMove)
        #expect(info.headline == "Changes requested by srivera")
        #expect(info.detail == "1h ago")
        #expect(classify(pr(author: "apark", decision: .changesRequested)).lane == .waiting)
    }

    @Test func row9GuardCheckBlocks() {
        let info = classify(pr(state: .blocked, checks: [check("build"), check("required-commit", .failed, required: true)]))
        #expect(info.status == .greenBlocked(.requiredCheck(names: ["required-commit"])))
        #expect(info.lane == .yourMove)
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
    }

    @Test func row10BehindBase() {
        let info = classify(pr(state: .behind, checks: [check("ci")]))
        #expect(info.status == .greenBlocked(.behindBase(base: "main")))
        #expect(info.headline == "CI passed · blocked: behind main")
        #expect(info.lane == .yourMove)
        #expect(classify(pr(author: "apark", state: .behind)).lane == .waiting)
    }

    @Test func row11WaitingOnReview() {
        let info = classify(pr(reviewRequests: [.user("nhaddad"), .team("acme/platform")], decision: .reviewRequired, state: .blocked))
        #expect(info.status == .waitingOnReview(reviewers: ["nhaddad", "acme/platform"]))
        #expect(info.lane == .waiting)
        #expect(info.detail == "nhaddad, acme/platform")
        #expect(classify(pr(decision: .reviewRequired, state: .blocked)).detail == "No reviewer requested yet")
    }

    @Test func row12CheckingMergeability() {
        let info = classify(pr(mergeable: .unknown, state: .unknown))
        #expect(info.status == .checkingMergeability)
        #expect(info.lane == .waiting)
    }

    @Test func row13BranchProtection() {
        let info = classify(pr(state: .blocked, checks: [check("ci")]))
        #expect(info.status == .greenBlocked(.branchProtection))
        #expect(info.lane == .yourMove)
    }

    @Test func row14ReadyToMerge() {
        let info = classify(pr(checks: [check("build", end: -6)]))
        #expect(info.status == .readyToMerge(autoMerge: false))
        #expect(info.lane == .yourMove)
        #expect(info.headline == "Ready to merge")
        #expect(info.detail == "CI passed 6m ago · approved · no merge queue")
        #expect(info.sentence == "Ready to merge. CI passed 6m ago · approved · no merge queue.")
        #expect(classify(pr(author: "apark")).lane == .waiting)
    }

    @Test func row14AutoMergeStalled() {
        let info = classify(pr(autoMerge: true))
        #expect(info.status == .readyToMerge(autoMerge: true))
        #expect(info.detail.contains("auto-merge is on"))
    }

    @Test func assigneeIsAnOwner() {
        let info = classify(pr(author: "jlin-agent", assignees: [me], state: .behind))
        #expect(info.lane == .yourMove)
    }

    @Test func loginsCompareCaseInsensitively() {
        #expect(classify(pr(author: "RChen")).lane == .yourMove)
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
