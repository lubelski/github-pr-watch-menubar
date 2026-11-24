import SwiftUI

/// Initials in a circle. Real avatars can come later; this never loads anything.
public struct Avatar: View {
    let login: String

    public init(login: String) {
        self.login = login
    }

    public var body: some View {
        Text(login.prefix(2).uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.indigo.gradient))
            .accessibilityHidden(true)
    }
}
