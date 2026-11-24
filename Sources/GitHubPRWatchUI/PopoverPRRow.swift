import GitHubPRWatchCore
import SwiftUI

/// One PR in the menubar popover: symbol, a one-line title, then the status sentence with
/// the repo and number. CI-running rows count up live. Clicking calls `open`.
struct PopoverPRRow: View {
    let item: ClassifiedPR
    var isNew = false
    let open: (URL) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            open(item.pr.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusSymbol(item.info.status.kind)
                    .font(.system(size: 13))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.pr.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if isNew { JustNowTag() }
                    }
                    HStack(spacing: 4) {
                        statusText
                            .foregroundStyle(StatusStyle.tint(for: item.info.status.kind))
                            .lineLimit(1)
                        Text("· \(item.pr.shortRef)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.pr.fullRef)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.pr.title), \(item.pr.fullRef). \(item.info.sentence)")
        .accessibilityHint("Opens the pull request in your browser")
    }

    @ViewBuilder private var statusText: some View {
        if case .ciRunning = item.info.status, MenuBarSummary.liveCIHeadline(item, now: .now) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MenuBarSummary.liveCIHeadline(item, now: context.date) ?? item.info.headline)
                    .monospacedDigit()
            }
        } else {
            Text(item.info.headline)
        }
    }

    private var background: Color {
        if isHovered { return Color.primary.opacity(0.08) }
        if isNew { return Color.accentColor.opacity(0.10) }
        return .clear
    }
}

/// The "Just now" capsule on a row that changed in the last few minutes.
struct JustNowTag: View {
    var body: some View {
        Text("Just now")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .fixedSize()
    }
}
