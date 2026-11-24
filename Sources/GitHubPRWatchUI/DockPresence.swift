import AppKit
import SwiftUI

/// The app lives in the menu bar (LSUIElement, an accessory app). While the main window is
/// open it becomes a regular app, so it has a Dock icon and shows in Command-Tab.
struct DockPresence: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Windowless renders run with `.prohibited` and must stay that way.
                guard NSApp.activationPolicy() != .prohibited else { return }
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear {
                guard NSApp.activationPolicy() != .prohibited else { return }
                NSApp.setActivationPolicy(.accessory)
            }
    }
}

extension View {
    func showsDockIconWhileOpen() -> some View { modifier(DockPresence()) }
}
