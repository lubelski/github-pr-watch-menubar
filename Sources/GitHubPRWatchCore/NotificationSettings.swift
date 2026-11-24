import Foundation

/// The global notification settings (Settings › Notifications). Which events notify is set
/// per view (`SavedView.notify`); these decide how they are delivered.
public struct NotificationSettings: Codable, Sendable, Equatable {
    /// The master switch for banners.
    public var bannersEnabled: Bool
    public var playSound: Bool
    /// Shows a short label such as `#1293 ready to merge` next to the menu bar glyph for
    /// `menuBarLabelDuration` seconds after an event.
    public var showMenuBarLabel: Bool
    /// While the app is frontmost, banners go to Notification Center without showing.
    public var quietWhileFrontmost: Bool

    public static let menuBarLabelDuration: TimeInterval = 8

    public init(bannersEnabled: Bool = true, playSound: Bool = true, showMenuBarLabel: Bool = true, quietWhileFrontmost: Bool = false) {
        self.bannersEnabled = bannersEnabled
        self.playSound = playSound
        self.showMenuBarLabel = showMenuBarLabel
        self.quietWhileFrontmost = quietWhileFrontmost
    }

    /// Missing keys take their defaults, so a settings file from an older build still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        bannersEnabled = try c.decodeIfPresent(Bool.self, forKey: .bannersEnabled) ?? d.bannersEnabled
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? d.playSound
        showMenuBarLabel = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarLabel) ?? d.showMenuBarLabel
        quietWhileFrontmost = try c.decodeIfPresent(Bool.self, forKey: .quietWhileFrontmost) ?? d.quietWhileFrontmost
    }
}

/// How the notifier should deliver one batch.
public struct DeliveryOptions: Sendable, Equatable {
    public var sound: Bool
    public var quietWhileFrontmost: Bool

    public init(sound: Bool = true, quietWhileFrontmost: Bool = false) {
        self.sound = sound
        self.quietWhileFrontmost = quietWhileFrontmost
    }

    public init(_ settings: NotificationSettings) {
        self.init(sound: settings.playSound, quietWhileFrontmost: settings.quietWhileFrontmost)
    }
}
