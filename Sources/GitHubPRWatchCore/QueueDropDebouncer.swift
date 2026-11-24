import Foundation

/// Holds "dropped from merge queue" events for one poll before they notify.
///
/// GitHub can briefly drop a queue entry while a merge lands, so a PR that looks dropped
/// on one poll is often merged (gone) or back in the queue on the next. A drop notifies
/// only if, on the next poll, the PR is still open, still out of the queue, and on the
/// same head commit. A pending drop whose repo failed to load waits another poll, since
/// its PR was carried over unchanged and proves nothing.
public struct QueueDropDebouncer: Sendable, Equatable {
    /// Drops seen on the last poll, by PR ID.
    public private(set) var pending: [String: PREvent] = [:]

    public init() {}

    /// Takes one poll's events and the open PRs it saw. Returns the events to deliver now:
    /// everything except new drops, plus last poll's drops that held.
    public mutating func process(_ events: [PREvent], current: [PullRequest], failedRepos: [String] = []) -> [PREvent] {
        let open = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let failed = Set(failedRepos.map { $0.lowercased() })

        var released: [PREvent] = []
        var stillPending: [String: PREvent] = [:]
        for (id, held) in pending.sorted(by: { $0.key < $1.key }) {
            if failed.contains(held.pr.repo.lowercased()) {
                stillPending[id] = held
                continue
            }
            guard let pr = open[id], pr.mergeQueueEntry == nil, pr.headSHA == held.pr.headSHA else { continue }
            var event = held
            event.pr = pr
            released.append(event)
        }

        var passed: [PREvent] = []
        for event in events {
            if event.kind == .droppedFromMergeQueue {
                stillPending[event.pr.id] = event
            } else {
                passed.append(event)
            }
        }
        pending = stillPending
        return passed + released
    }

    public mutating func reset() {
        pending = [:]
    }
}
