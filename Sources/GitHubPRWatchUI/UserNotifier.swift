import AppKit
import GitHubPRWatchCore
@preconcurrency import UserNotifications

/// Posts banners through `UNUserNotificationCenter` and opens the PR when one is clicked.
/// Requires running from the app bundle: `UNUserNotificationCenter` needs a bundle identifier.
///
/// - One banner per planned item; banners for the same PR share a thread, so they group.
/// - Shown even while the app is frontmost, unless `quietWhileFrontmost` is on, in which
///   case they go straight to Notification Center.
/// - Permission is asked only from `requestAuthorization()`, which the UI calls from an
///   explicit button.
@MainActor
public final class UserNotifier: NSObject, Notifier {
    private let center: UNUserNotificationCenter
    private var quietWhileFrontmost = false
    /// Opens the app's main window. Set by the app once a scene can open windows; summary
    /// banners fall back to their URL while it is `nil`.
    public var openApp: (@MainActor () -> Void)?

    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        // Set the delegate before launch finishes, so a click that launches the app is seen.
        center.delegate = self
    }

    public func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func deliver(_ banners: [NotificationContent], options: DeliveryOptions) {
        quietWhileFrontmost = options.quietWhileFrontmost
        for text in banners {
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.subtitle = text.subtitle
            content.body = text.body
            content.threadIdentifier = text.threadID
            content.sound = options.sound ? .default : nil
            content.userInfo = [UserInfoKey.url: text.url.absoluteString, UserInfoKey.opensApp: text.opensApp]
            let request = UNNotificationRequest(identifier: text.identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error { NSLog("GitHub PR Watch: couldn't post a notification: %@", error.localizedDescription) }
            }
        }
    }

    fileprivate func handleClick(url: URL?, opensApp: Bool) {
        if opensApp, let openApp {
            openApp()
            return
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    fileprivate var presentationOptions: UNNotificationPresentationOptions {
        quietWhileFrontmost ? [.list] : [.banner, .list, .sound]
    }

    /// Opens System Settings › Notifications, on this app's page where macOS supports it.
    public static func openSystemNotificationSettings() {
        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate enum UserInfoKey {
        static let url = "url"
        static let opensApp = "opensApp"
    }

    fileprivate nonisolated static func parse(_ userInfo: [AnyHashable: Any]) -> (URL?, Bool) {
        let url = (userInfo[UserInfoKey.url] as? String).flatMap(URL.init(string:))
        return (url, userInfo[UserInfoKey.opensApp] as? Bool ?? false)
    }
}

extension UserNotifier: UNUserNotificationCenterDelegate {
    /// Called only while the app is frontmost. Banners show anyway, unless the user asked
    /// for quiet.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { self.presentationOptions }
    }

    /// Clicking a banner opens the PR in the browser (a summary opens the app).
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let (url, opensApp) = Self.parse(response.notification.request.content.userInfo)
        await MainActor.run { self.handleClick(url: url, opensApp: opensApp) }
    }
}
