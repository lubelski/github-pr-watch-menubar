import GitHubPRWatchCore
import SwiftUI

/// "Updated 2m ago", or the reason polling is stuck. Shared by the window and the popover.
public struct ConnectionStatusView: View {
    let store: PRStore

    public init(store: PRStore) {
        self.store = store
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Updating…")
                } else if let message = store.connection.message {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message)
                } else if let updated = store.lastUpdated {
                    Text("Updated \(Formatting.ago(updated, now: context.date))")
                } else {
                    Text("Not updated yet")
                }
                if !store.failedRepos.isEmpty {
                    Text("· Can't read \(store.failedRepos.joined(separator: ", "))").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}
