import AppKit
import GitHubPRWatchCore
import SwiftUI

/// The menu bar item (Figma row 3B): the app's pull request mark, which stays calm until
/// something needs you, then gains a filled badge. Offline or signed out, it dims. Right
/// after an event a short label such as `#1293 ready to merge` sits next to it for a few
/// seconds.
///
/// Everything is drawn into one template image, so the menu bar tints it for light and
/// dark menu bars, and the badge changes the shape, not only the color.
public struct MenuBarLabel: View {
    let indicator: MenuBarIndicator
    let transientLabel: String?

    public init(indicator: MenuBarIndicator, transientLabel: String? = nil) {
        self.indicator = indicator
        self.transientLabel = transientLabel
    }

    public var body: some View {
        Image(nsImage: Self.image(indicator: indicator, label: transientLabel))
            .accessibilityLabel(accessibilityText)
            .help(accessibilityText)
    }

    private var accessibilityText: String {
        [indicator.accessibilityText, transientLabel].compactMap { $0 }.joined(separator: ". ")
    }

    /// The menu bar image for a state. `MenuBarIcon` draws it.
    public static func image(indicator: MenuBarIndicator, label: String? = nil) -> NSImage {
        let look: MenuBarIcon.Look = switch indicator {
        case .signedOut, .offline: .dimmed
        case .calm: .calm
        case .needsYou: .badged
        }
        let image = MenuBarIcon.image(look, label: label)
        image.accessibilityDescription = indicator.accessibilityText
        return image
    }
}

/// The menu bar item wired to the app: reads the store and the activity, and lets summary
/// banners open the main window.
public struct MenuBarItemLabel: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        let store = services.store
        let indicator = MenuBarIndicator.make(
            isSignedIn: store.viewer != nil, needsOnboarding: store.needsOnboarding,
            connection: store.connection, yourMoveCount: store.yourMoveCount
        )
        MenuBarLabel(indicator: indicator, transientLabel: services.activity.transientLabel)
            .task {
                services.registerWindowOpener {
                    openWindow(id: AppInfo.mainWindowID)
                    NSApp.activate()
                }
            }
    }
}
