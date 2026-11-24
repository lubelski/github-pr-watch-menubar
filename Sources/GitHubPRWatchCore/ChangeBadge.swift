import Foundation

/// The menu bar badge: "something changed since you last looked".
///
/// It turns on when a poll delivers events, which are already only the ones the views ask to
/// be notified about, whether or not banners are on. It clears when the user looks: opens the
/// popover or brings the main window to the front. It lives in memory only, so a relaunch
/// starts clear.
///
/// The PRs it was on for stay listed under Recent changes until a newer batch arrives, so
/// opening the popover (which clears the badge) still shows what changed.
public struct ChangeBadge: Sendable, Equatable {
    /// How many PRs Recent changes lists at most.
    public static let recentLimit = 5

    /// PR ID to its newest event, for events since the last look.
    public private(set) var unseen: [String: Date] = [:]
    /// What `unseen` held at the last look that had anything in it.
    public private(set) var lastSeen: [String: Date] = [:]

    public init() {}

    /// Whether the badge shows.
    public var isOn: Bool { !unseen.isEmpty }

    /// Records a poll's events. An empty list changes nothing.
    public mutating func record(_ events: [PREvent]) {
        for event in events {
            unseen[event.pr.id] = max(unseen[event.pr.id] ?? event.occurredAt, event.occurredAt)
        }
    }

    /// The user looked. The badge clears; what it was on for moves to `lastSeen`.
    public mutating func markSeen() {
        guard !unseen.isEmpty else { return }
        lastSeen = unseen
        unseen = [:]
    }

    /// PR IDs for Recent changes: unseen and last seen, newest event first. Ties keep a
    /// stable order by ID.
    public var recentIDs: [String] {
        lastSeen.merging(unseen) { max($0, $1) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// The PRs for Recent changes, newest first, at most `limit`. PRs no longer in `prs`
    /// (closed, merged, or out of the menu bar views) are skipped before the cap.
    public func recentChanges(in prs: [ClassifiedPR], limit: Int = recentLimit) -> [ClassifiedPR] {
        let byID = Dictionary(prs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(recentIDs.compactMap { byID[$0] }.prefix(limit))
    }
}
