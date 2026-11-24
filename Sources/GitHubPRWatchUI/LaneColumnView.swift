import GitHubPRWatchCore
import SwiftUI

/// One lane of the main window: a header with its count, then its cards in their own scroll
/// view. Your move is tinted. The Waiting lane folds drafts into a collapsed group at the end,
/// and the CI running lane briefly notes PRs that just finished and moved to Your move.
///
/// Lanes and cards are content, so they stay plain: no glass. The header floats over the
/// lane's scroll view with the system's scroll edge effect.
struct LaneColumnView: View {
    let group: PRStore.LaneGroup
    let viewer: String?
    let selectedID: String?
    let justFinished: [String: Date]
    let movedNotes: [LaneBoard.MovedNote]
    @Binding var showDrafts: Bool
    let onOpen: (ClassifiedPR) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lane: Lane { group.lane }
    private var cards: [ClassifiedPR] { lane == .waiting ? group.pullRequests.filter { !$0.pr.isDraft } : group.pullRequests }
    private var drafts: [ClassifiedPR] { lane == .waiting ? group.pullRequests.filter(\.pr.isDraft) : [] }

    var body: some View {
        // The header is a bar over the top of the lane's scroll view, so cards scroll under it
        // and the system's soft scroll edge effect keeps it legible.
        cardList
            .safeAreaBar(edge: .top, spacing: 0) { paddedHeader }
            .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(lane == .yourMove ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.045))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.title), \(group.pullRequests.count) pull request\(group.pullRequests.count == 1 ? "" : "s")")
    }

    private var paddedHeader: some View {
        header
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private var cardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(movedNotes) { MovedNoteView(note: $0) }
                    ForEach(cards) { card($0) }
                    if group.pullRequests.isEmpty && movedNotes.isEmpty {
                        Text(Self.emptyText(lane))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                    if !drafts.isEmpty { draftsGroup }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .padding(.top, 2)
                .animation(reduceMotion ? nil : .snappy, value: group.pullRequests.map(\.id))
                .animation(reduceMotion ? nil : .snappy, value: movedNotes.map(\.id))
            }
            .scrollIndicators(.automatic)
            .onChange(of: selectedID) { _, id in
                guard let id, group.pullRequests.contains(where: { $0.id == id }) else { return }
                if reduceMotion {
                    proxy.scrollTo(id)
                } else {
                    withAnimation(.snappy) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: StatusStyle.symbol(for: lane))
                .foregroundStyle(lane == .yourMove ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(lane.title)
                .font(.headline)
                .lineLimit(1)
            Text("\(group.pullRequests.count)")
                .font(.headline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 4)
            if lane == .yourMove {
                Text("needs you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func card(_ item: ClassifiedPR) -> some View {
        PRRowView(
            item, style: .card, viewer: viewer, isSelected: selectedID == item.id,
            justFinishedAt: lane == .yourMove ? justFinished[item.id] : nil,
            onOpen: { onOpen(item) }
        )
        .id(item.id)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
    }

    private var draftsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if reduceMotion { showDrafts.toggle() } else { withAnimation(.snappy) { showDrafts.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showDrafts ? 90 : 0))
                    Text("Drafts").font(.subheadline.weight(.semibold))
                    Text("\(drafts.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .accessibilityLabel("Drafts, \(drafts.count)")
            .accessibilityValue(showDrafts ? "Expanded" : "Collapsed")
            if showDrafts {
                ForEach(drafts) { card($0) }
            }
        }
    }

    static func emptyText(_ lane: Lane) -> String {
        switch lane {
        case .yourMove: "Nothing needs you right now"
        case .ciRunning: "No CI running"
        case .inMergeQueue: "Nothing in a merge queue"
        case .waiting: "Nothing waiting on others"
        }
    }
}

/// The dashed note left in CI running for a moment after a PR's CI finished and it moved to
/// Your move, so the move is noticed.
private struct MovedNoteView: View {
    let note: LaneBoard.MovedNote

    var body: some View {
        HStack(spacing: 4) {
            Text("\(note.shortRef) finished")
            Image(systemName: "arrow.right").accessibilityHidden(true)
            Text("moved to Your move")
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(note.shortRef) finished CI and moved to Your move")
    }
}
