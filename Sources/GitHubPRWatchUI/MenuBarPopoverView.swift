import AppKit
import GitHubPRWatchCore
import SwiftUI

/// STUB for the menubar phase. The popover: "Your move" first, everything else under a
/// collapsed "Waiting". Reads `PRStore.menuBarPullRequests`. The menubar agent owns this file.
public struct MenuBarPopoverView: View {
    let store: PRStore
    @State private var showWaiting = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public init(store: PRStore) {
        self.store = store
    }

    public var body: some View {
        let prs = store.menuBarPullRequests
        let yourMove = prs.filter { $0.info.lane == .yourMove }
        let others = PRStore.lanes(prs).filter { $0.lane != .yourMove }.flatMap(\.pullRequests)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppInfo.name).font(.headline)
                Spacer()
                ConnectionStatusView(store: store)
            }
            if store.needsOnboarding {
                Text("Finish setting up to start watching.").foregroundStyle(.secondary)
                Button("Open Setup…", action: openMainWindow)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your move · \(yourMove.count)").font(.subheadline.weight(.semibold))
                        if yourMove.isEmpty {
                            Text("Nothing needs you right now.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                        }
                        ForEach(yourMove) { PRRowView($0, style: .compact) }
                        DisclosureGroup(isExpanded: $showWaiting) {
                            ForEach(others) { PRRowView($0, style: .compact) }
                        } label: {
                            Text("Waiting · \(others.count)").font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Button("Open Window", action: openMainWindow)
                Button("Refresh") { store.refreshNow() }.disabled(store.isRefreshing || store.needsOnboarding)
                Spacer()
                Button {
                    openSettings()
                    NSApp.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 360)
    }

    private func openMainWindow() {
        openWindow(id: AppInfo.mainWindowID)
        NSApp.activate()
    }
}
