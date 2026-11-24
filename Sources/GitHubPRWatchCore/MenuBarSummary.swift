import Foundation

/// What the menu bar glyph shows.
public enum MenuBarIndicator: Sendable, Equatable {
    /// Not signed in, setup unfinished, or GitHub rejected the sign-in. Dimmed.
    case signedOut
    /// Can't reach GitHub, or polls keep failing. Dimmed.
    case offline
    /// Nothing needs you. The plain glyph.
    case calm
    /// At least one PR is your move. The glyph gets a filled badge.
    case needsYou(Int)

    public static func make(isSignedIn: Bool, needsOnboarding: Bool, connection: PRStore.ConnectionState, yourMoveCount: Int) -> MenuBarIndicator {
        guard isSignedIn, !needsOnboarding else { return .signedOut }
        switch connection {
        case .tokenRejected: return .signedOut
        case .offline, .failed: return .offline
        case .idle, .upToDate, .rateLimited, .secondaryRateLimited: break
        }
        return yourMoveCount > 0 ? .needsYou(yourMoveCount) : .calm
    }

    /// Spoken by VoiceOver and shown as the tooltip.
    public var accessibilityText: String {
        switch self {
        case .signedOut: "GitHub PR Watch, not signed in"
        case .offline: "GitHub PR Watch, offline"
        case .calm: "GitHub PR Watch, nothing needs you"
        case .needsYou(let count): "GitHub PR Watch, \(count) \(count == 1 ? "pull request needs" : "pull requests need") you"
        }
    }
}

/// Text and ordering for the menubar popover.
public enum MenuBarSummary {
    /// `3 in CI, 1 in queue, 2 in review`, for the collapsed Waiting row. Empty when nothing waits.
    public static func waitingSummary(_ prs: [ClassifiedPR]) -> String {
        var ci = 0, queue = 0, review = 0, draft = 0, other = 0
        for item in prs {
            switch item.info.lane {
            case .ciRunning: ci += 1
            case .inMergeQueue: queue += 1
            case .yourMove: continue
            case .waiting:
                switch item.info.status.kind {
                case .waitingOnReview: review += 1
                case .draft: draft += 1
                default: other += 1
                }
            }
        }
        let parts: [(Int, String)] = [
            (ci, "in CI"), (queue, "in queue"), (review, "in review"),
            (draft, draft == 1 ? "draft" : "drafts"), (other, "on others"),
        ]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    /// The calm state's sentence about what is in flight.
    public static func calmSentence(waiting: [ClassifiedPR], bannersOn: Bool) -> String {
        guard !waiting.isEmpty else { return "No open pull requests in your menu bar views." }
        let noun = waiting.count == 1 ? "pull request is" : "pull requests are"
        var text = "\(waiting.count) \(noun) in flight: \(waitingSummary(waiting))."
        if bannersOn { text += " You'll get a banner the moment one needs you." }
        return text
    }

    /// "Your move" with the most recent change on top: an event this session counts, else
    /// GitHub's `updatedAt`.
    public static func yourMoveOrder(_ prs: [ClassifiedPR], recentEvents: [PREvent]) -> [ClassifiedPR] {
        var lastEvent: [String: Date] = [:]
        for event in recentEvents { lastEvent[event.pr.id] = max(lastEvent[event.pr.id] ?? .distantPast, event.occurredAt) }
        return prs.filter { $0.info.lane == .yourMove }.sorted {
            max(lastEvent[$0.id] ?? .distantPast, $0.pr.updatedAt) > max(lastEvent[$1.id] ?? .distantPast, $1.pr.updatedAt)
        }
    }

    /// PRs with an event in the last `window` seconds, for the "Just now" tag.
    public static func justChanged(_ recentEvents: [PREvent], now: Date, window: TimeInterval = 180) -> Set<String> {
        Set(recentEvents.filter { now.timeIntervalSince($0.occurredAt) <= window }.map(\.pr.id))
    }

    /// The CI-running headline at `now`, so the elapsed time stays live between polls:
    /// `CI running · 23m 10s`. `nil` when the PR isn't running CI.
    public static func liveCIHeadline(_ item: ClassifiedPR, now: Date) -> String? {
        guard case .ciRunning = item.info.status,
              let start = item.pr.currentChecks?.checks.compactMap(\.startedAt).min() else { return nil }
        return "CI running · \(elapsed(now.timeIntervalSince(start)))"
    }

    /// `45s`, `23m 10s`, `1h 5m`: seconds only while under an hour.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return Formatting.duration(TimeInterval(s))
    }
}
