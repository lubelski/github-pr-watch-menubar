import Foundation

/// The sections of Settings, in sidebar order.
///
/// It is called a tab for history: the popover remembers which one to open under
/// `storageKey`, and that key and the raw values stay as they were.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case account, repos, notifications, views, advanced

    /// Where the selected section is remembered, so the popover can open a given one.
    public static let storageKey = "settings.selectedTab"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .account: "Account"
        case .repos: "Repos"
        case .notifications: "Notifications"
        case .views: "Views"
        case .advanced: "Advanced"
        }
    }

    /// The SF Symbol beside the title in the sidebar.
    public var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .repos: "book.closed"
        case .notifications: "bell.badge"
        case .views: "line.3.horizontal.decrease.circle"
        case .advanced: "gearshape.2"
        }
    }
}
