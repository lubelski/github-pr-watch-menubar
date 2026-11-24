import Foundation

/// The text of one banner. The title carries the one fact, the subtitle names the view
/// whose rule fired, and the body says which PR and why (Figma section 5).
public struct NotificationContent: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var body: String
    /// Opened when the banner is clicked.
    public var url: URL
    /// Groups banners for the same PR in Notification Center.
    public var threadID: String
    public var identifier: String
    /// A summary banner: a click opens the app's window instead of `url`, when it can.
    public var opensApp: Bool = false
}

public enum NotificationWording {
    public static func content(for event: PREvent) -> NotificationContent {
        let pr = event.pr
        let d = event.detail
        let ref = pr.shortRef
        let title: String
        var body: String

        switch event.kind {
        case .ciReady:
            title = "Ready to merge: \(ref)"
            body = "\(pr.title). CI passed\(inDuration(d))"
            body += pr.reviewDecision == .approved ? " and it is approved." : "."
            if !pr.autoMergeEnabled { body += " Nothing else will merge it, so merge it yourself." }
        case .ciFailed:
            title = "CI failed: \(Formatting.names(d.failingChecks))"
            body = "\(ref) \(pr.title)."
            if let total = d.totalChecks {
                body += " \(d.failingChecks.count) of \(total) checks failed"
                body += d.ciDuration.map { " after \(Formatting.duration($0))." } ?? "."
            }
        case .ciBlocked:
            switch d.blockReason {
            case .requiredCheck(let names):
                title = "Blocked by \(Formatting.names(names))"
                body = "\(ref) \(pr.title). CI passed, but the guard wants a rebase onto \(pr.baseRef)."
            case .behindBase(let base):
                title = "Blocked: behind \(base)"
                body = "\(ref) \(pr.title). CI passed, but the branch must be updated with \(base)."
            case .branchProtection, nil:
                title = "Blocked: \(ref)"
                body = "\(pr.title). CI passed, but branch protection still blocks the merge."
            }
        case .ciPassed:
            title = "CI passed: \(ref)"
            body = "\(pr.title). CI passed\(inDuration(d))."
        case .enteredMergeQueue:
            title = "In merge queue: \(ref)"
            body = "\(pr.title)."
            if let position = d.queuePosition {
                body += d.queueLength.map { " Position \(position) of \($0)." } ?? " Position \(position)."
            }
        case .droppedFromMergeQueue:
            title = "Dropped from queue: \(ref)"
            body = "\(pr.title). Removed"
            if let position = d.queuePosition {
                body += d.queueLength.map { " at position \(position) of \($0)" } ?? " at position \(position)"
            }
            body += d.reason.map { ": \(Formatting.humanize($0))." } ?? "."
        case .approved:
            title = "Approved: \(ref)"
            body = "\(pr.title)." + (d.actor.map { " Approved by \($0)." } ?? "")
        case .changesRequested:
            title = d.actor.map { "\($0) requested changes" } ?? "Changes requested: \(ref)"
            body = d.actor == nil ? "\(pr.title)." : "\(ref) \(pr.title)."
        case .reviewRequested:
            title = "\(d.actor ?? pr.author ?? "Someone") requested your review"
            body = "\(ref) \(pr.title)"
            if let status = statusSuffix(pr) { body += " · \(status)" }
        case .newMatch:
            title = "New in \(event.viewName): \(ref)"
            body = "\(pr.author ?? "Someone") opened \(pr.title)."
            if !pr.isDraft { body += " Not a draft." }
        }

        return NotificationContent(
            title: title, subtitle: event.viewName, body: body, url: pr.url,
            threadID: "\(pr.repo)#\(pr.number)", identifier: event.id
        )
    }

    private static func inDuration(_ d: EventDetail) -> String {
        d.ciDuration.map { " in \(Formatting.duration($0))" } ?? ""
    }

    private static func statusSuffix(_ pr: PullRequest) -> String? {
        guard let checks = pr.currentChecks, !checks.running.isEmpty else { return nil }
        return "CI running"
    }
}
