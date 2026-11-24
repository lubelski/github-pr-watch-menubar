import AppKit
import GitHubPRWatchCore
import SwiftUI

/// One PR. Shared by the window, the popover and anything else that lists PRs.
///
/// - `.card` (the lanes, Figma row 1B): `acme/web #4821 · author`, age on the right; the
///   title on up to two lines; then the status symbol and sentence (row 2A), with a progress
///   bar while CI runs. Running time ticks live.
/// - `.compact` (the popover): symbol, title, status and short ref.
///
/// Clicking opens the PR in the browser. The context menu opens it, copies the link, and
/// opens a failing check's details page.
public struct PRRowView: View {
    public enum Style { case card, compact }

    let item: ClassifiedPR
    let style: Style
    let viewer: String?
    let isSelected: Bool
    let justFinishedAt: Date?
    let onOpen: (() -> Void)?
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// - Parameters:
    ///   - viewer: the signed-in login, so the card can say "you" instead of it.
    ///   - isSelected: draws the keyboard selection ring.
    ///   - justFinishedAt: when CI just finished, to outline the card with a "Just now" pill.
    ///   - onOpen: called before the PR opens in the browser.
    public init(
        _ item: ClassifiedPR, style: Style = .card, viewer: String? = nil, isSelected: Bool = false,
        justFinishedAt: Date? = nil, onOpen: (() -> Void)? = nil
    ) {
        self.item = item
        self.style = style
        self.viewer = viewer
        self.isSelected = isSelected
        self.justFinishedAt = justFinishedAt
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: open) {
            Group {
                switch style {
                case .card: card
                case .compact: compact
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.pr.url.absoluteString)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the pull request in your browser")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func open() {
        onOpen?()
        openURL(item.pr.url)
    }

    // MARK: Card

    private var card: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 4) {
                metaRow(now: context.date)
                Text(item.pr.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                statusRow(now: context.date)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private func metaRow(now: Date) -> some View {
        HStack(spacing: 5) {
            Text(item.pr.fullRef)
                .lineLimit(1)
                .layoutPriority(1)
            if let author = item.pr.author {
                Text("·").accessibilityHidden(true)
                Initials(login: author)
                Text(isViewer(author) ? "you" : author)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if justFinishedAt != nil {
                Text("Just now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            } else {
                Text(Formatting.duration(now.timeIntervalSince(LaneBoard.changedAt(item.pr))))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func statusRow(now: Date) -> some View {
        let tint = StatusStyle.tint(for: item.info.status.kind)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                StatusSymbol(item.info.status.kind)
                Text(LaneBoard.liveHeadline(item, now: now))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            if let progress = LaneBoard.progress(item) {
                // Drawn by hand: the system bar turns gray in an inactive window, and this
                // one should keep the status tint.
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .scaleEffect(x: max(0.04, Double(progress.finished) / Double(progress.total)), anchor: .leading)
                    }
                    .frame(height: 4)
                    .padding(.vertical, 3)
                    .accessibilityHidden(true)
            }
            if !item.info.detail.isEmpty {
                Text(item.info.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let highlighted = justFinishedAt != nil
        return shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                shape.strokeBorder(
                    highlighted || isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: highlighted || isSelected ? 2 : 1
                )
            }
            .overlay {
                // A soft glow that ripples out a few times when the card arrives. Off with Reduce Motion.
                if highlighted && !reduceMotion {
                    shape.strokeBorder(Color.accentColor.opacity(pulse ? 0 : 0.5), lineWidth: pulse ? 8 : 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.2).repeatCount(3, autoreverses: false)) { pulse = true }
                        }
                }
            }
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    // MARK: Compact

    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusSymbol(item.info.status.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.pr.title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(item.info.headline).foregroundStyle(StatusStyle.tint(for: item.info.status.kind)).lineLimit(1)
                    Text("· \(item.pr.shortRef)").foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Menu and accessibility

    @ViewBuilder private var menu: some View {
        Button("Open in Browser", action: open)
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.pr.url.absoluteString, forType: .string)
        }
        let failing = LaneBoard.failingCheckLinks(item)
        if !failing.isEmpty {
            Divider()
            ForEach(failing.prefix(5), id: \.name) { link in
                Button("Open Failing Check “\(link.name)”") { openURL(link.url) }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(item.pr.title), \(item.pr.fullRef)"]
        if let author = item.pr.author { parts.append("by \(isViewer(author) ? "you" : author)") }
        if justFinishedAt != nil { parts.append("CI just finished") }
        let headline = LaneBoard.liveHeadline(item, now: .now)
        parts.append(item.info.detail.isEmpty ? headline : "\(headline). \(item.info.detail)")
        return parts.joined(separator: ". ")
    }

    private func isViewer(_ login: String) -> Bool {
        viewer.map { login.caseInsensitiveCompare($0) == .orderedSame } ?? false
    }
}

/// A small initials circle for the card's author. Never loads anything.
private struct Initials: View {
    let login: String

    var body: some View {
        Text(login.prefix(2).uppercased())
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Self.color(for: login).gradient))
            .accessibilityHidden(true)
    }

    /// A stable color per login, so the same person always looks the same.
    static func color(for login: String) -> Color {
        let palette: [Color] = [.indigo, .purple, .pink, .teal, .orange, .blue, .green, .brown]
        let sum = login.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}
