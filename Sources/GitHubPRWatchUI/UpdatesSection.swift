import GitHubPRWatchCore
import SwiftUI

/// The version and the updater's controls, at the end of Settings, Advanced. The same
/// controls the owner's other apps keep in General: an Update automatically switch and Check
/// for Updates…, beside the version and build number. A build without a feed says so instead.
struct UpdatesSection: View {
    let updater: any AppUpdating
    let build: BuildInfo
    /// Read from the updater when the section appears. Sparkle keeps it in its own preferences.
    @State private var updatesAutomatically: Bool

    init(updater: any AppUpdating, build: BuildInfo) {
        self.updater = updater
        self.build = build
        _updatesAutomatically = State(initialValue: updater.updatesAutomatically)
    }

    var body: some View {
        Section {
            if updater.isAvailable {
                Toggle("Update automatically", isOn: Binding(
                    get: { updatesAutomatically },
                    set: {
                        updater.updatesAutomatically = $0
                        updatesAutomatically = $0
                    }
                ))
            }
            LabeledContent("Version") {
                HStack {
                    Text(build.versionAndBuild).textSelection(.enabled)
                    if updater.isAvailable {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                    }
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(updater.isAvailable
                 ? "Checks about once a day, downloads a newer release, and relaunches into it. While a window is open, a sign-in is under way, or a poll is running, the relaunch waits until it ends. Check for Updates is also in the app menu. \(AppInfo.name) only reads from GitHub; it never writes."
                 : "This build does not update itself. Only a release build does. \(AppInfo.name) only reads from GitHub; it never writes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { updatesAutomatically = updater.updatesAutomatically }
    }
}
