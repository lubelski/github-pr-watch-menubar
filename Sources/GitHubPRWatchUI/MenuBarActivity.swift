import Foundation
import GitHubPRWatchCore
import Observation

/// Routes each poll's events: a short label next to the menu bar glyph for a few seconds,
/// and planned banners through the notifier, both following the user's settings.
@MainActor
@Observable
public final class MenuBarActivity {
    /// Shown next to the glyph, such as `#1293 ready to merge`. `nil` most of the time.
    public private(set) var transientLabel: String?

    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    /// Plans `events`, shows the label, and posts banners, as `settings` allow.
    public func handle(_ events: [PREvent], settings: NotificationSettings, notifier: any Notifier) {
        let plan = NotificationPlanner.plan(events)
        guard !plan.isEmpty else { return }
        if settings.showMenuBarLabel, let label = NotificationWording.menuBarLabel(for: plan) {
            show(label)
        }
        if settings.bannersEnabled {
            notifier.deliver(plan.contents, options: DeliveryOptions(settings))
        }
    }

    /// Shows `label` for `duration` seconds. A newer label replaces it and restarts the clock.
    public func show(_ label: String, for duration: TimeInterval = NotificationSettings.menuBarLabelDuration) {
        transientLabel = label
        clearTask?.cancel()
        let sleep = self.sleep
        clearTask = Task { [weak self] in
            do { try await sleep(duration) } catch { return }
            self?.transientLabel = nil
        }
    }

    public func clear() {
        clearTask?.cancel()
        transientLabel = nil
    }
}
