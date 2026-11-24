import Foundation

/// What the menu bar glyph shows.
public enum MenuBarIndicator: Sendable, Equatable {
    /// Not signed in, setup unfinished, or GitHub rejected the sign-in. Dimmed.
    case signedOut
    /// Can't reach GitHub, or polls keep failing. Dimmed.
    case offline
    /// Nothing changed since you last looked. The plain glyph.
    case calm
    /// Something changed since you last looked (`ChangeBadge`). The glyph gets a filled badge.
    case changed

    public static func make(isSignedIn: Bool, needsOnboarding: Bool, connection: PRStore.ConnectionState, hasChanges: Bool) -> MenuBarIndicator {
        guard isSignedIn, !needsOnboarding else { return .signedOut }
        switch connection {
        case .tokenRejected: return .signedOut
        case .offline, .failed: return .offline
        case .idle, .upToDate, .rateLimited, .secondaryRateLimited: break
        }
        return hasChanges ? .changed : .calm
    }

    /// Spoken by VoiceOver and shown as the tooltip.
    public var accessibilityText: String {
        switch self {
        case .signedOut: "GitHub PR Watch, not signed in"
        case .offline: "GitHub PR Watch, offline"
        case .calm: "GitHub PR Watch, no changes since you last looked"
        case .changed: "GitHub PR Watch, pull requests changed since you last looked"
        }
    }
}

/// Text and grouping for the menubar popover.
public enum MenuBarSummary {
    /// Lane groups that start expanded in the popover. The rest start collapsed.
    public static let expandedByDefault: Set<Lane> = [.failing, .readyToMerge]

    /// The popover's lane groups: only lanes with PRs, in lane order.
    public static func groups(_ prs: [ClassifiedPR]) -> [PRStore.LaneGroup] {
        LaneBoard.lanes(prs).filter { !$0.pullRequests.isEmpty }
    }

    /// The sentence under "No open pull requests", when the menu bar views are empty.
    public static func emptySentence(bannersOn: Bool) -> String {
        var text = "Nothing open matches your menu bar views."
        if bannersOn { text += " You'll get a banner when one changes." }
        return text
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
