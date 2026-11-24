import AppKit
import GitHubPRWatchCore
@preconcurrency import UserNotifications

/// Posts events as native banners and opens the PR when one is clicked.
/// Requires running from the app bundle: `UNUserNotificationCenter` needs a bundle identifier.
@MainActor
public final class UserNotifier: NSObject, Notifier {
    private let center: UNUserNotificationCenter

    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
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

    public func post(_ events: [PREvent]) {
        for event in events {
            let text = NotificationWording.content(for: event)
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.subtitle = text.subtitle
            content.body = text.body
            content.threadIdentifier = text.threadID
            content.sound = .default
            content.userInfo = ["url": text.url.absoluteString]
            let request = UNNotificationRequest(identifier: text.identifier, content: content, trigger: nil)
            center.add(request)
        }
    }
}

extension UserNotifier: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is frontmost.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Clicking a banner opens the PR.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
