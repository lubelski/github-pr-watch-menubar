import GitHubPRWatchCore
import SwiftUI

/// One PR: symbol, title (up to two lines), then the fact you act on. Clicking opens the PR.
/// Shared by the window, the popover and anything else that lists PRs.
public struct PRRowView: View {
    public enum Style { case card, compact }

    let item: ClassifiedPR
    let style: Style
    @Environment(\.openURL) private var openURL

    public init(_ item: ClassifiedPR, style: Style = .card) {
        self.item = item
        self.style = style
    }

    public var body: some View {
        Button {
            openURL(item.pr.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusSymbol(item.info.status.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.pr.title)
                        .font(style == .card ? .body : .callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    statusLine
                    if style == .card {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(style == .card ? 10 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if style == .card {
                    RoundedRectangle(cornerRadius: 8).fill(.background)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.pr.url.absoluteString)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.pr.title), \(item.pr.fullRef). \(item.info.sentence)")
        .accessibilityHint("Opens the pull request in your browser")
    }

    @ViewBuilder private var statusLine: some View {
        let tint = StatusStyle.tint(for: item.info.status.kind)
        if style == .card {
            Text(item.info.headline).font(.callout).foregroundStyle(tint)
            if !item.info.detail.isEmpty {
                Text(item.info.detail).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 4) {
                Text(item.info.headline).foregroundStyle(tint).lineLimit(1)
                Text("· \(item.pr.shortRef)").foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            }
            .font(.caption)
        }
    }

    private var meta: String {
        [item.pr.fullRef, item.pr.author].compactMap { $0 }.joined(separator: " · ")
    }
}
