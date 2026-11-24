import GitHubPRWatchCore
import SwiftUI

/// STUB for the filter-builder phase (Figma row 4B, smart-folder style). For now it lists
/// each view's rule as a sentence and its notification rules as checkboxes, saving through
/// `PRStore.saveView(_:)`. The filter-builder agent owns this file.
public struct ViewEditorView: View {
    let store: PRStore

    public init(store: PRStore) {
        self.store = store
    }

    public var body: some View {
        Form {
            ForEach(store.views) { view in
                Section {
                    Text(view.rule.summary.capitalizedFirstLetter)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Pinned to menubar", isOn: binding(view, \.pinnedToMenubar))
                    DisclosureGroup("Notify when") {
                        ForEach(EventKind.allCases, id: \.self) { kind in
                            Toggle(kind.title, isOn: notifyBinding(view, kind))
                        }
                    }
                } header: {
                    Label(view.name, systemImage: view.symbol)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ view: SavedView, _ keyPath: WritableKeyPath<SavedView, Bool>) -> Binding<Bool> {
        Binding(
            get: { view[keyPath: keyPath] },
            set: { var copy = view; copy[keyPath: keyPath] = $0; store.saveView(copy) }
        )
    }

    private func notifyBinding(_ view: SavedView, _ kind: EventKind) -> Binding<Bool> {
        Binding(
            get: { view.notify.contains(kind) },
            set: { on in
                var copy = view
                if on { copy.notify.insert(kind) } else { copy.notify.remove(kind) }
                store.saveView(copy)
            }
        )
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
