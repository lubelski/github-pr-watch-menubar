import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct QueueDropDebouncerTests {
    let view = UUID()

    func drop(_ p: PullRequest) -> PREvent {
        PREvent(kind: .droppedFromMergeQueue, pr: p, viewID: view, viewName: "Mine", occurredAt: t0, detail: EventDetail(queuePosition: 2))
    }

    @Test func dropWaitsOnePollThenNotifiesWhenStillOut() {
        var d = QueueDropDebouncer()
        let out = pr("A")
        #expect(d.process([drop(out)], current: [out]).isEmpty)
        #expect(d.pending.keys.sorted() == ["A"])
        let released = d.process([], current: [out])
        #expect(released.map(\.kind) == [.droppedFromMergeQueue])
        #expect(released.first?.detail.queuePosition == 2)
        #expect(d.pending.isEmpty)
    }

    @Test func mergedPRNeverNotifies() {
        var d = QueueDropDebouncer()
        _ = d.process([drop(pr("A"))], current: [pr("A")])
        // Next poll: the PR is gone (merged or closed).
        #expect(d.process([], current: []).isEmpty)
        #expect(d.pending.isEmpty)
    }

    @Test func backInQueueNeverNotifies() {
        var d = QueueDropDebouncer()
        _ = d.process([drop(pr("A"))], current: [pr("A")])
        let back = pr("A", queue: MergeQueueEntry(position: 0))
        let enter = PREvent(kind: .enteredMergeQueue, pr: back, viewID: view, viewName: "Mine", occurredAt: t0)
        #expect(d.process([enter], current: [back]).map(\.kind) == [.enteredMergeQueue])
    }

    @Test func newHeadCommitCancelsTheDrop() {
        var d = QueueDropDebouncer()
        _ = d.process([drop(pr("A", head: "h1"))], current: [pr("A", head: "h1")])
        #expect(d.process([], current: [pr("A", head: "h2")]).isEmpty)
    }

    @Test func failedRepoKeepsTheDropPending() {
        var d = QueueDropDebouncer()
        let out = pr("A", repo: "acme/web")
        _ = d.process([drop(out)], current: [out])
        #expect(d.process([], current: [out], failedRepos: ["ACME/web"]).isEmpty)
        #expect(d.pending.keys.sorted() == ["A"])
        #expect(d.process([], current: [out]).map(\.kind) == [.droppedFromMergeQueue])
    }

    @Test func otherEventsPassStraightThrough() {
        var d = QueueDropDebouncer()
        let p = pr("A")
        let ready = PREvent(kind: .ciReady, pr: p, viewID: view, viewName: "Mine", occurredAt: t0)
        #expect(d.process([ready], current: [p]) == [ready])
    }

    @Test func releasedEventCarriesTheCurrentPR() {
        var d = QueueDropDebouncer()
        _ = d.process([drop(pr("A", labels: []))], current: [pr("A")])
        let now = pr("A", labels: ["urgent"])
        #expect(d.process([], current: [now]).first?.pr.labels == ["urgent"])
    }

    @Test func resetClearsPending() {
        var d = QueueDropDebouncer()
        _ = d.process([drop(pr("A"))], current: [pr("A")])
        d.reset()
        #expect(d.process([], current: [pr("A")]).isEmpty)
    }
}
