import AppKit
import GitHubPRWatchCore
import GitHubPRWatchUI
import os
import Sparkle

private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "updates")

/// Keeps the app up to date with Sparkle. The only file that imports Sparkle.
///
/// Only a release build updates itself. `scripts/release.sh` writes the feed address and the
/// public signing key into Info.plist. A build without them, such as one from
/// `scripts/bundle.sh` alone, has no updater, so a development copy is never replaced.
@MainActor
final class AppUpdater: AppUpdating {
    /// Whether this build can update itself.
    let isAvailable: Bool

    private let controller: SPUStandardUpdaterController?
    private let delegate: Delegate
    private var resignObserver: (any NSObjectProtocol)?

    /// `info` is the bundle's Info.plist. `activity` says what the app is doing, to decide
    /// whether it may quit and relaunch now.
    init(
        info: [String: Any]? = Bundle.main.infoDictionary,
        activity: @escaping @MainActor () -> AppUpdates.Activity
    ) {
        delegate = Delegate(activity: activity)
        guard AppUpdates.hasFeed(info) else {
            isAvailable = false
            controller = nil
            return
        }
        isAvailable = true
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil
        )
        // Leaving the app is the usual moment it goes idle, so try a held update then.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.installPendingUpdate() }
        }
    }

    /// False while a check is already running.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Whether Sparkle looks for, downloads, and installs updates without asking.
    var updatesAutomatically: Bool {
        get {
            guard let updater = controller?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Checks now and shows Sparkle's own windows with the result.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Installs an update that was held back because the app was in use.
    func installPendingUpdate() {
        delegate.installPendingUpdate()
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        private let activity: @MainActor () -> AppUpdates.Activity
        private var pendingInstall: (() -> Void)?
        /// Looks again now and then while an update waits, for changes that call nothing,
        /// such as a poll finishing or a window closing.
        private var retry: Timer?

        init(activity: @escaping @MainActor () -> AppUpdates.Activity) {
            self.activity = activity
        }

        /// Sparkle normally installs a downloaded update when the app quits. A menu bar app
        /// stays open for weeks, so install and relaunch as soon as the update is ready. A
        /// relaunch would close a window the person is using, with a view being edited or a
        /// token being typed, cut off a sign-in, or drop a poll halfway, so while any of those
        /// is going on the install waits until it is over.
        func updater(
            _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            // Sparkle calls its delegate on the main thread.
            MainActor.assumeIsolated {
                if AppUpdates.mayRelaunch(activity()) {
                    immediateInstallHandler()
                } else {
                    log.notice("An update is ready and waits: \(String(describing: AppUpdates.wait(for: self.activity())), privacy: .public)")
                    pendingInstall = immediateInstallHandler
                    scheduleRetry()
                }
            }
            return true
        }

        @MainActor
        func installPendingUpdate() {
            guard let install = pendingInstall, AppUpdates.mayRelaunch(activity()) else { return }
            pendingInstall = nil
            retry?.invalidate()
            retry = nil
            install()
        }

        @MainActor
        private func scheduleRetry() {
            guard retry == nil else { return }
            retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installPendingUpdate() }
            }
        }
    }
}

extension AppUpdates.Activity {
    /// What the app is doing now.
    @MainActor
    static func current(_ store: PRStore) -> AppUpdates.Activity {
        let signingIn = switch store.auth {
        case .signingIn, .awaitingDeviceApproval: true
        case .signedOut, .signedIn: false
        }
        // The main window and Settings are titled windows. The menu bar popover makes the app
        // active while it is open.
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        return AppUpdates.Activity(polling: store.isRefreshing, signingIn: signingIn, inUse: NSApp.isActive || windowOpen)
    }
}
