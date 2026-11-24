import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct ChangeBadgeTests {
    func event(_ id: String, at m: Double, _ kind: EventKind = .ciReady) -> PREvent {
        PREvent(kind: kind, pr: pr(id, number: Int(id.dropFirst()) ?? 1), viewID: BuiltInViews.mineID, viewName: "Mine", occurredAt: minutes(m))
    }

    func classified(_ ids: [String]) -> [ClassifiedPR] {
        ids.map { id in
            let p = pr(id, number: Int(id.dropFirst()) ?? 1)
            return ClassifiedPR(pr: p, info: PRClassifier.classify(p, viewer: me, context: ClassificationContext(now: t0)))
        }
    }

    @Test func startsClear() {
        let badge = ChangeBadge()
        #expect(!badge.isOn)
        #expect(badge.recentIDs.isEmpty)
    }

    @Test func eventsTurnItOnAndLookingClearsIt() {
        var badge = ChangeBadge()
        badge.record([])
        #expect(!badge.isOn)
        badge.record([event("P1", at: -2)])
        #expect(badge.isOn)
        badge.markSeen()
        #expect(!badge.isOn)
        // Looking again with nothing new changes nothing.
        badge.markSeen()
        #expect(!badge.isOn)
        badge.record([event("P2", at: -1, .changesRequested)])
        #expect(badge.isOn)
    }

    @Test func recentChangesSurviveTheLookUntilANewerBatch() {
        var badge = ChangeBadge()
        badge.record([event("P1", at: -5), event("P2", at: -2)])
        badge.markSeen()
        // Opening the popover clears the badge but still lists what changed.
        #expect(badge.recentIDs == ["P2", "P1"])
        badge.markSeen()
        #expect(badge.recentIDs == ["P2", "P1"])
        // A newer batch, before it's seen: both batches, newest first.
        badge.record([event("P3", at: -1)])
        #expect(badge.recentIDs == ["P3", "P2", "P1"])
        // Once seen, only the newer batch stays.
        badge.markSeen()
        #expect(badge.recentIDs == ["P3"])
    }

    @Test func aPRKeepsItsNewestEvent() {
        var badge = ChangeBadge()
        badge.record([event("P1", at: -1), event("P2", at: -3), event("P1", at: -9)])
        #expect(badge.unseen["P1"] == minutes(-1))
        #expect(badge.recentIDs == ["P1", "P2"])
    }

    @Test func recentChangesSkipsPRsNoLongerShownThenCaps() {
        var badge = ChangeBadge()
        badge.record((1...8).map { event("P\($0)", at: Double($0) - 10) })
        let shown = classified(["P1", "P2", "P3", "P4", "P5", "P6", "P7"]) // P8 merged
        let recent = badge.recentChanges(in: shown)
        #expect(recent.map(\.id) == ["P7", "P6", "P5", "P4", "P3"])
        #expect(ChangeBadge.recentLimit == 5)
        #expect(badge.recentChanges(in: shown, limit: 2).map(\.id) == ["P7", "P6"])
    }
}
