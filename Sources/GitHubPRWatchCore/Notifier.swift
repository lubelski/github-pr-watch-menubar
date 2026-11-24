import Foundation

public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// Delivers banners. The app uses `UserNotifier` (UNUserNotificationCenter); tests and
/// renders use `RecordingNotifier`. Wording comes from `NotificationWording`, and which
/// banners a burst of events becomes comes from `NotificationPlanner`.
@MainActor
public protocol Notifier: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt. Only call from an explicit user action, never at launch.
    func requestAuthorization() async -> Bool
    /// Posts each banner as it is. Callers plan the batch first.
    func deliver(_ banners: [NotificationContent], options: DeliveryOptions)
}

extension Notifier {
    /// Plans the events with the default policy, then delivers them.
    public func post(_ events: [PREvent], options: DeliveryOptions = .init()) {
        deliver(NotificationPlanner.plan(events).contents, options: options)
    }
}

/// Remembers what it was asked to post.
@MainActor
public final class RecordingNotifier: Notifier {
    public private(set) var posted: [NotificationContent] = []
    public private(set) var lastOptions: DeliveryOptions?
    public var status: NotificationAuthorization

    public init(status: NotificationAuthorization = .notDetermined) {
        self.status = status
    }

    public func authorization() async -> NotificationAuthorization { status }

    public func requestAuthorization() async -> Bool {
        status = .authorized
        return true
    }

    public func deliver(_ banners: [NotificationContent], options: DeliveryOptions) {
        posted += banners
        lastOptions = options
    }
}
