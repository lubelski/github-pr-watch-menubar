import Foundation

/// The pure logic behind the main window's five lanes: what fills them, in what order, which
/// cards are highlighted because CI just finished, search, and keyboard movement between cards.
/// The SwiftUI view only draws what this returns.
public enum LaneBoard {
    /// How long a PR whose CI just finished stays highlighted, in whatever lane it landed in.
    public static let justFinishedWindow: TimeInterval = 15 * 60
    /// How long the "finished, moved to <lane>" note stays in the CI running lane.
    public static let movedNoteWindow: TimeInterval = 90

    /// Events that mean "CI finished on this PR".
    public static let ciFinishedKinds: Set<EventKind> = [.ciReady, .ciBlocked, .ciFailed, .ciPassed]

    // MARK: Just finished

    /// PR IDs whose CI finished within `window` before `now`, with when it finished. An event
    /// counts only while the PR is still on the head commit it was about, so a new push
    /// clears the highlight. Events from the future (clock skew) count as just now.
    public static func justFinished(
        events: [PREvent], current: [ClassifiedPR], now: Date, window: TimeInterval = justFinishedWindow
    ) -> [String: Date] {
        let heads = Dictionary(current.map { ($0.pr.id, $0.pr.headSHA) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Date] = [:]
        for event in events where ciFinishedKinds.contains(event.kind) {
            guard heads[event.pr.id] == event.pr.headSHA else { continue }
            guard now.timeIntervalSince(event.occurredAt) <= window else { continue }
            let at = min(event.occurredAt, now)
            result[event.pr.id] = max(result[event.pr.id] ?? at, at)
        }
        return result
    }

    /// A PR that just left the CI running lane, for the short note left behind. `lane` is
    /// where it went.
    public struct MovedNote: Identifiable, Equatable, Sendable {
        public var prID: String
        public var shortRef: String
        public var lane: Lane
        public var at: Date
        public var id: String { prID }

        /// `moved to Failing`.
        public var destinationText: String { "moved to \(lane.title)" }
    }

    /// Notes for PRs whose CI finished within `window` and that have left CI running.
    public static func movedNotes(
        justFinished: [String: Date], board: [ClassifiedPR], now: Date, window: TimeInterval = movedNoteWindow
    ) -> [MovedNote] {
        board
            .filter { $0.info.lane != .ciRunning }
            .compactMap { item in
                guard let at = justFinished[item.pr.id], now.timeIntervalSince(at) <= window else { return nil }
                return MovedNote(prID: item.pr.id, shortRef: "#\(item.pr.number)", lane: item.info.lane, at: at)
            }
            .sorted { $0.at > $1.at }
    }

    // MARK: Lanes and order

    /// The five lanes, always all five and in order, each sorted by `sorted(_:in:justFinished:)`.
    public static func lanes(_ prs: [ClassifiedPR], justFinished: [String: Date] = [:]) -> [PRStore.LaneGroup] {
        Lane.allCases.map { lane in
            PRStore.LaneGroup(lane: lane, pullRequests: sorted(prs.filter { $0.info.lane == lane }, in: lane, justFinished: justFinished))
        }
    }

    /// Order within a lane.
    ///
    /// - **CI running**: longest running first, since it is closest to finishing. PRs without
    ///   a start time (queued) go last.
    /// - **Merge queue**: by queue position, front of the queue first.
    /// - **Failing, In review, Ready to merge**: PRs whose CI just finished first, newest finish
    ///   first, so the highlighted cards are on top. Then most recently changed (`changedAt`)
    ///   first. In review puts drafts after everything else, since they fold into a group.
    ///
    /// Ties fall back to repo and number, so the order is stable between polls.
    public static func sorted(_ prs: [ClassifiedPR], in lane: Lane, justFinished: [String: Date] = [:]) -> [ClassifiedPR] {
        func tiebreak(_ a: ClassifiedPR, _ b: ClassifiedPR) -> Bool {
            (a.pr.repo, a.pr.number) < (b.pr.repo, b.pr.number)
        }
        switch lane {
        case .ciRunning:
            return prs.sorted { a, b in
                let sa = runningSince(a.pr), sb = runningSince(b.pr)
                switch (sa, sb) {
                case let (sa?, sb?) where sa != sb: return sa < sb
                case (.some, nil): return true
                case (nil, .some): return false
                default: return tiebreak(a, b)
                }
            }
        case .mergeQueue:
            return prs.sorted { a, b in
                let pa = a.pr.mergeQueueEntry?.position ?? .max, pb = b.pr.mergeQueueEntry?.position ?? .max
                return pa != pb ? pa < pb : tiebreak(a, b)
            }
        case .failing, .inReview, .readyToMerge:
            return prs.sorted { a, b in
                if a.pr.isDraft != b.pr.isDraft { return !a.pr.isDraft }
                let fa = justFinished[a.pr.id], fb = justFinished[b.pr.id]
                if (fa != nil) != (fb != nil) { return fa != nil }
                if let fa, let fb, fa != fb { return fa > fb }
                let ca = changedAt(a.pr), cb = changedAt(b.pr)
                return ca != cb ? ca > cb : tiebreak(a, b)
            }
        }
    }

    /// When the PR last changed: its `updatedAt`, or the last check finish if later (a check
    /// finishing doesn't always bump `updatedAt`).
    public static func changedAt(_ pr: PullRequest) -> Date {
        let lastCheck = pr.currentChecks?.checks.compactMap(\.completedAt).max()
        return max(pr.updatedAt, lastCheck ?? .distantPast)
    }

    // MARK: CI running

    /// When CI started on the current head commit: the earliest check start.
    public static func runningSince(_ pr: PullRequest) -> Date? {
        guard let checks = pr.currentChecks, !checks.running.isEmpty else { return nil }
        return checks.checks.compactMap(\.startedAt).min()
    }

    /// The first status line, recomputed for `now` so running time ticks without a refetch:
    /// `CI running · 23m`. Every other status keeps the classifier's headline.
    public static func liveHeadline(_ item: ClassifiedPR, now: Date) -> String {
        guard item.info.status.kind == .ciRunning, let start = runningSince(item.pr) else { return item.info.headline }
        return "CI running · \(Formatting.duration(now.timeIntervalSince(start)))"
    }

    /// Finished and total checks for a running PR, or nil when there is nothing to show.
    public static func progress(_ item: ClassifiedPR) -> (finished: Int, total: Int)? {
        guard case .ciRunning(_, let finished, let total) = item.info.status, total > 0 else { return nil }
        return (finished, total)
    }

    // MARK: Failing checks

    /// Failing checks on the current head that have a details page, for "Open failing check".
    public static func failingCheckLinks(_ item: ClassifiedPR) -> [(name: String, url: URL)] {
        guard case .ciFailed(let failing, _) = item.info.status, let checks = item.pr.currentChecks else { return [] }
        let names = Set(failing)
        return checks.failing.compactMap { check in
            guard names.contains(check.name), let url = check.detailsURL else { return nil }
            return (check.name, url)
        }
    }

    // MARK: Search

    /// Whether the card matches a search. Every word of the query must appear, case- and
    /// diacritic-insensitively, in the title, the repo, the author, or the number (`4821`,
    /// `#4821`, or `web #4821`). An empty query matches everything.
    public static func matches(_ item: ClassifiedPR, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let pr = item.pr
        let haystack = [pr.title, pr.repo, pr.author ?? "", "#\(pr.number)"]
        return words.allSatisfy { word in
            if word.hasPrefix("#"), word.count > 1 { return "#\(pr.number)".hasPrefix(word) }
            if word.allSatisfy(\.isNumber), String(pr.number).hasPrefix(word) { return true }
            return haystack.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: Keyboard

    public enum Direction: Sendable { case up, down, left, right }

    /// The card to select after an arrow key. `columns` are the card IDs of each lane, in
    /// lane order. Up and down stay in the lane and stop at the ends. Left and right go to
    /// the nearest non-empty lane that way, keeping the row where possible. With nothing
    /// selected (or a selection that vanished), any arrow selects the first card.
    public static func move(_ selection: String?, _ direction: Direction, columns: [[String]]) -> String? {
        let first = columns.lazy.compactMap(\.first).first
        guard let selection,
              let col = columns.firstIndex(where: { $0.contains(selection) }),
              let row = columns[col].firstIndex(of: selection)
        else { return first }

        switch direction {
        case .up: return columns[col][max(0, row - 1)]
        case .down: return columns[col][min(columns[col].count - 1, row + 1)]
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var next = col + step
            while columns.indices.contains(next) {
                if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                next += step
            }
            return selection
        }
    }
}

// MARK: - Which PRs fill the lanes

extension PRStore {
    /// The "All views" choice in the view picker: every PR that matches at least one view.
    /// Not a real view, so it never collides with a saved view's ID.
    public static let allViewsID = UUID(uuidString: "A11A11A1-0000-4000-8000-000000000000")!

    /// The PRs for a picker choice: one view, or every view for `allViewsID`.
    public func boardPullRequests(for viewID: UUID?) -> [ClassifiedPR] {
        guard viewID == Self.allViewsID else { return pullRequests(in: viewID) }
        guard let context = filterContext else { return [] }
        return pullRequests.filter { item in views.contains { $0.matches(item.pr, in: context) } }
    }

    /// How many open PRs the choice holds, drafts left out, for the picker's counts.
    public func openCount(for viewID: UUID?) -> Int {
        boardPullRequests(for: viewID).filter { !$0.pr.isDraft }.count
    }
}
