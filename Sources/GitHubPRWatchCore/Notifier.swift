import Foundation

public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// Delivers events as banners. The app uses `UserNotifier` (UNUserNotificationCenter);
/// tests and renders use `RecordingNotifier`. Wording comes from `NotificationWording`.
@MainActor
public protocol Notifier: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt. Only call from an explicit user action, never at launch.
    func requestAuthorization() async -> Bool
    func post(_ events: [PREvent])
}

/// Remembers what it was asked to post.
@MainActor
public final class RecordingNotifier: Notifier {
    public private(set) var posted: [NotificationContent] = []
    public var status: NotificationAuthorization

    public init(status: NotificationAuthorization = .notDetermined) {
        self.status = status
    }

    public func authorization() async -> NotificationAuthorization { status }

    public func requestAuthorization() async -> Bool {
        status = .authorized
        return true
    }

    public func post(_ events: [PREvent]) {
        posted += events.map(NotificationWording.content(for:))
    }
}
