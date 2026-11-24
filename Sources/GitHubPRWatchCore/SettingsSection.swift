import Foundation

/// The sections of Settings, in sidebar order. A new section goes above Experiments:
/// Experiments is second to last and Debugging is always last, as in the owner's other apps.
///
/// It is called a tab for history: the popover remembers which one to open under
/// `storageKey`, and that key and the raw values stay as they were.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case account, repos, notifications, views, advanced, experiments, debugging

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
        case .experiments: "Experiments"
        case .debugging: "Debugging"
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
        case .experiments: "flask"
        case .debugging: "ladybug"
        }
    }
}
