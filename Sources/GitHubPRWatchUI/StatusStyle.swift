import GitHubPRWatchCore
import SwiftUI

/// The symbol and tint for each status. The symbol's shape carries the state; the tint only
/// reinforces it, so rows still read in grayscale and for color-blind users.
public enum StatusStyle {
    public static func symbol(for kind: PRStatus.Kind) -> String {
        switch kind {
        case .draft: "circle.dashed"
        case .inMergeQueue: "arrow.triangle.merge"
        case .droppedFromMergeQueue: "exclamationmark.triangle.fill"
        case .reviewRequestedFromYou: "eye.circle.fill"
        case .mergeConflicts: "exclamationmark.octagon.fill"
        case .ciFailed: "xmark.circle.fill"
        case .ciRunning: "arrow.trianglehead.2.clockwise.rotate.90.circle"
        case .changesRequested: "text.bubble.fill"
        case .blockedBehindBase, .blockedByRequiredCheck, .blockedByBranchProtection: "minus.circle.fill"
        case .waitingOnReview: "clock"
        case .checkingMergeability: "ellipsis.circle"
        case .readyToMerge: "checkmark.circle.fill"
        }
    }

    public static func tint(for kind: PRStatus.Kind) -> Color {
        switch kind {
        case .draft, .waitingOnReview, .checkingMergeability: .secondary
        case .inMergeQueue: .purple
        case .droppedFromMergeQueue, .ciFailed, .mergeConflicts: .red
        case .reviewRequestedFromYou, .ciRunning: .blue
        case .changesRequested, .blockedBehindBase, .blockedByRequiredCheck, .blockedByBranchProtection: .orange
        case .readyToMerge: .green
        }
    }

    public static func symbol(for lane: Lane) -> String {
        switch lane {
        case .yourMove: "hand.point.right"
        case .ciRunning: "arrow.trianglehead.2.clockwise.rotate.90"
        case .inMergeQueue: "arrow.triangle.merge"
        case .waiting: "clock"
        }
    }
}

/// The status symbol for a PR.
public struct StatusSymbol: View {
    let kind: PRStatus.Kind

    public init(_ kind: PRStatus.Kind) {
        self.kind = kind
    }

    public var body: some View {
        Image(systemName: StatusStyle.symbol(for: kind))
            .foregroundStyle(StatusStyle.tint(for: kind))
            .accessibilityHidden(true)
    }
}
