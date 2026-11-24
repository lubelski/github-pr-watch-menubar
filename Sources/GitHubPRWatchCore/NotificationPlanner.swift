import Foundation

/// What one poll's events turn into: a few banners, and at most one summary for the rest.
public struct NotificationPlan: Sendable, Equatable {
    /// One event per PR, most important first, each shown as its own banner.
    public var banners: [PREvent]
    /// One event per PR that didn't get its own banner, folded into `summary`.
    public var summarized: [PREvent]
    /// "4 more pull requests changed", when anything was folded.
    public var summary: NotificationContent?

    /// Every banner to post, in order.
    public var contents: [NotificationContent] {
        banners.map(NotificationWording.content(for:)) + (summary.map { [$0] } ?? [])
    }

    /// The single most important event in the batch, for the menu bar label.
    public var headline: PREvent? { banners.first ?? summarized.first }

    /// How many PRs the batch covers.
    public var pullRequestCount: Int { banners.count + summarized.count }

    public var isEmpty: Bool { banners.isEmpty && summarized.isEmpty }
}

/// Turns a burst of events into a calm set of banners.
///
/// Policy:
/// 1. A PR with several events in one poll keeps only its most important one (`priority`).
/// 2. PRs are ordered by that event's importance; ties keep the order they came in.
/// 3. Up to `maxBanners` PRs get their own banner. When there are more, the first
///    `maxBanners - 1` get banners and the rest go into one summary banner, so a poll never
///    posts more than `maxBanners` banners.
public enum NotificationPlanner {
    public static let defaultMaxBanners = 3

    /// Lower is more important. Things that need you now come first.
    public static func priority(_ kind: EventKind) -> Int {
        switch kind {
        case .ciFailed: 0
        case .droppedFromMergeQueue: 1
        case .changesRequested: 2
        case .ciReady: 3
        case .reviewRequested: 4
        case .ciBlocked: 5
        case .approved: 6
        case .enteredMergeQueue: 7
        case .ciPassed: 8
        case .newMatch: 9
        }
    }

    /// One event per PR, the most important, ordered by importance (stable).
    public static func mostImportantPerPR(_ events: [PREvent]) -> [PREvent] {
        var best: [String: (index: Int, event: PREvent)] = [:]
        for (index, event) in events.enumerated() {
            if let current = best[event.pr.id], priority(current.event.kind) <= priority(event.kind) { continue }
            best[event.pr.id] = (best[event.pr.id]?.index ?? index, event)
        }
        return best.values
            .sorted { (priority($0.event.kind), $0.index) < (priority($1.event.kind), $1.index) }
            .map(\.event)
    }

    public static func plan(_ events: [PREvent], maxBanners: Int = defaultMaxBanners) -> NotificationPlan {
        let perPR = mostImportantPerPR(events)
        let cap = max(1, maxBanners)
        guard perPR.count > cap else { return NotificationPlan(banners: perPR, summarized: [], summary: nil) }
        let shown = Array(perPR.prefix(cap - 1))
        let rest = Array(perPR.dropFirst(cap - 1))
        return NotificationPlan(banners: shown, summarized: rest, summary: summary(for: rest, afterBanners: !shown.isEmpty))
    }

    /// The summary banner: `4 more pull requests changed`, with a short line per PR.
    public static func summary(for events: [PREvent], afterBanners: Bool) -> NotificationContent {
        let count = events.count
        let noun = count == 1 ? "pull request" : "pull requests"
        let title = afterBanners ? "\(count) more \(noun) changed" : "\(count) \(noun) changed"
        let labels = events.map { NotificationWording.shortLabel(for: $0, includeRepo: true) }
        var views: [String] = []
        for event in events where !views.contains(event.viewName) { views.append(event.viewName) }
        let stamp = events.map(\.occurredAt).max().map { Int($0.timeIntervalSince1970) } ?? 0
        return NotificationContent(
            title: title,
            subtitle: Formatting.names(views, limit: 3),
            body: Formatting.names(labels, limit: 3) + ".",
            url: summaryURL,
            threadID: "summary",
            identifier: "summary|\(stamp)|\(events.map(\.pr.id).sorted().joined(separator: ","))",
            opensApp: true
        )
    }

    /// Where a summary click goes when the app can't open its own window.
    public static let summaryURL = URL(string: "https://github.com/pulls")!
}

extension NotificationWording {
    /// A few words for the menu bar label and the summary banner, such as
    /// `#1293 ready to merge` or `api #1293 ready to merge`.
    public static func shortLabel(for event: PREvent, includeRepo: Bool = false) -> String {
        let ref = includeRepo ? event.pr.shortRef : "#\(event.pr.number)"
        let what: String = switch event.kind {
        case .ciReady: "ready to merge"
        case .ciFailed: "CI failed"
        case .ciBlocked: "CI passed, blocked"
        case .ciPassed: "CI passed"
        case .enteredMergeQueue: "in merge queue"
        case .droppedFromMergeQueue: "dropped from queue"
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .reviewRequested: "review requested"
        case .newMatch: "new in \(event.viewName)"
        }
        return "\(ref) \(what)"
    }

    /// The menu bar label for a whole batch: the most important event, plus how many other
    /// PRs changed. `nil` for an empty batch.
    public static func menuBarLabel(for plan: NotificationPlan) -> String? {
        guard let headline = plan.headline else { return nil }
        let others = plan.pullRequestCount - 1
        return shortLabel(for: headline) + (others > 0 ? " +\(others)" : "")
    }
}
