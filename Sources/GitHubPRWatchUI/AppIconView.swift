import GitHubPRWatchCore
import SwiftUI

/// The app's pull request mark as a SwiftUI shape, fitted and centered in its frame.
public struct PullRequestMarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        Path(PullRequestMark.path(.large, fittedIn: rect, flipped: true))
    }
}

/// The app icon as a view, for places in the app that show it, such as the onboarding header:
/// the mark in white on the shipped design's gradient, in a rounded square. Drawn from the same
/// code as `Resources/AppIcon.icon`, without the system's glass.
public struct AppIconView: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        let gradient = AppIconDrawing.shipped.gradient
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [color(gradient.top), color(gradient.bottom)], startPoint: .top, endPoint: .bottom))
            .overlay {
                PullRequestMarkShape()
                    .fill(.white)
                    .padding(size * 0.2)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func color(_ c: [CGFloat]) -> Color {
        Color(.sRGB, red: c[0], green: c[1], blue: c[2])
    }
}
