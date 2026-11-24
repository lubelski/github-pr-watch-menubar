import GitHubPRWatchCore
import SwiftUI

/// STUB for the lanes phase. The main window: a view picker, then four lanes by state
/// (Your move, CI running, In merge queue, Waiting on others), each scrolling on its own.
/// Reads everything from `PRStore.lanes(for:)`. The lanes agent owns this file.
public struct LanesWindowView: View {
    @Bindable var store: PRStore

    public init(store: PRStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $store.selectedViewID) {
                    ForEach(store.views) { view in
                        Label(view.name, systemImage: view.symbol).tag(Optional(view.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                ConnectionStatusView(store: store)
                Spacer()
                Button {
                    store.refreshNow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.lanes(for: store.selectedViewID)) { group in
                    LaneColumn(group: group)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 480)
    }
}

private struct LaneColumn: View {
    let group: PRStore.LaneGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: StatusStyle.symbol(for: group.lane))
                Text(group.lane.title).font(.headline)
                Text("\(group.pullRequests.count)").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(group.pullRequests) { PRRowView($0) }
                    if group.pullRequests.isEmpty {
                        Text("Nothing here").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
