import AppKit
import GitHubPRWatchCore
import SwiftUI

/// Settings, Debugging, always the last section: the last poll, the rate limit, the sign-in
/// method, and the build, with Refresh Now, Copy Diagnostics, and Show Data Folder.
///
/// Everything here comes from `DiagnosticsReport`, which holds no token, login, repo name, or
/// pull request, so what Copy Diagnostics copies is safe to paste into an issue.
struct DebuggingSettings: View {
    let store: PRStore
    let build: BuildInfo
    @State private var copied = false

    var body: some View {
        let report = DiagnosticsReport(store: store, build: build)
        Form {
            Section {
                HStack {
                    Text("For finding out why something went wrong. Copy Diagnostics leaves out tokens, your login, repo names and pull requests.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DiagnosticsReport(store: store, build: build).plainText(), forType: .string)
                        copied = true
                    }
                    Button("Show Data Folder", action: Self.showDataFolder)
                }
            }
            Section("Polling") {
                LabeledContent("Status") {
                    HStack {
                        ConnectionStatusView(store: store)
                        Button("Refresh Now") { store.refreshNow() }
                            .disabled(store.isRefreshing || store.viewer == nil)
                    }
                }
                LabeledContent("Last poll", value: Self.time(report.lastPollStarted, none: "None since launch"))
                LabeledContent("Result") {
                    Text(DiagnosticsReport.describe(report.connection))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Last successful poll", value: Self.time(report.lastUpdated, none: "None since launch"))
                LabeledContent("Rate limit") {
                    if let limit = report.rateLimit {
                        Text("\(limit.remaining.formatted()) of \(limit.limit.formatted()) points left · resets \(limit.resetAt.formatted(date: .omitted, time: .shortened))")
                            .monospacedDigit()
                    } else {
                        Text("Not known yet").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Watching", value: [
                    Self.count(report.watchedRepos, "repo"), Self.count(report.pullRequests, "open pull request"),
                    Self.count(report.views, "view"),
                ].joined(separator: ", "))
            }
            Section("Sign-in") {
                LabeledContent("Signed in", value: report.signedIn ? "Yes" : "No")
                LabeledContent("Method") {
                    Text(DiagnosticsReport.describe(report.authMethod)).multilineTextAlignment(.trailing)
                }
                LabeledContent("GitHub CLI found", value: report.cliInstalled ? "Yes" : "No")
                LabeledContent("Team review requests") {
                    Text(DiagnosticsReport.describe(report.teamAccess)).multilineTextAlignment(.trailing)
                }
            }
            Section("Build") {
                LabeledContent("Version") { Text(build.versionAndBuild).textSelection(.enabled) }
                LabeledContent("Commit") {
                    Text(build.commit).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Bundle identifier") { Text(build.bundleIdentifier).textSelection(.enabled) }
                LabeledContent("Signing", value: build.signing)
                LabeledContent("Updates", value: build.updates ? "From the latest GitHub Release" : "None, not a release build")
                LabeledContent("Data folder") {
                    Text(report.dataFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("System", value: report.system)
            }
        }
        .formStyle(.grouped)
        .onChange(of: report.lastPollStarted) { copied = false }
    }

    static func showDataFolder() {
        let folder = JSONFileStore<AppConfig>.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    static func time(_ date: Date?, none: String) -> String {
        guard let date else { return none }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .standard)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
