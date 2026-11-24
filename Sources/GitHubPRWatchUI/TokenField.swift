import GitHubPRWatchCore
import SwiftUI

/// A token input for a rule row's list values: logins (with a "me" token), repos, labels,
/// or branches. Type and press Return, or paste a comma, space or newline separated list.
/// Backspace in the empty input removes the last token. Tab takes the first suggestion.
/// Part of the view editor.
struct TokenField: View {
    @Binding var row: RuleRowDraft
    /// Known values for this field, most likely first.
    let suggestions: [String]
    let focus: FocusState<UUID?>.Binding
    var isInvalid = false

    @State private var input = ""

    private var isFocused: Bool { focus.wrappedValue == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 4, lineSpacing: 4, stretchLast: true) {
                if row.includesMe {
                    TokenChip(text: "me", isMe: true) { row.includesMe = false }
                }
                ForEach(row.values, id: \.self) { value in
                    TokenChip(text: value) { row.values.removeAll { $0 == value } }
                }
                TextField("", text: $input, prompt: Text(row.values.isEmpty && !row.includesMe ? row.field.placeholder : ""))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(minWidth: 90, idealWidth: 90)
                    .focused(focus, equals: row.id)
                    .onSubmit { commit(all: true) }
                    .onKeyPress(.delete) {
                        guard input.isEmpty else { return .ignored }
                        row.removeLastToken()
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard !input.isEmpty, let first = matching.first else { return .ignored }
                        add([first])
                        return .handled
                    }
                    .onChange(of: input) { old, new in
                        if new.contains(where: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
                            commit(all: TokenInput.endsWithSeparator(new))
                        } else if new.count > old.count + 1, matching.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) {
                            // A completion or a pasted single known value.
                            commit(all: true)
                        }
                    }
                    .accessibilityLabel("\(row.field.title) values")
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(minWidth: 220, maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isInvalid ? Color.red : (isFocused ? Color.accentColor : Color(nsColor: .separatorColor)), lineWidth: isInvalid || isFocused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { focus.wrappedValue = row.id }

            if showsSuggestions {
                SuggestionStrip(items: Array(matching.prefix(6)), offerMe: offerMe) { add([$0]) }
            }
        }
    }

    /// Suggestions show while the field is focused, or while a people field is still empty.
    private var showsSuggestions: Bool {
        (isFocused || (row.field.takesPeople && row.isMissingValue)) && (!matching.isEmpty || offerMe)
    }

    private var offerMe: Bool {
        row.field.takesPeople && !row.includesMe && (input.isEmpty || "me".hasPrefix(input.lowercased()))
    }

    private var matching: [String] {
        let chosen = Set(row.values.map { $0.lowercased() })
        let needle = input.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let open = suggestions.filter { !chosen.contains($0.lowercased()) }
        guard !needle.isEmpty else { return open }
        let prefix = open.filter { $0.lowercased().hasPrefix(needle) }
        let contains = open.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
        return prefix + contains
    }

    private func add(_ tokens: [String]) {
        row.addTokens(tokens)
        input = ""
        focus.wrappedValue = row.id
    }

    /// Commits finished tokens. With `all`, the last fragment too.
    private func commit(all: Bool) {
        var tokens = TokenInput.split(input)
        var rest = ""
        if !all, let last = tokens.popLast() { rest = last }
        row.addTokens(tokens)
        input = rest
    }
}

/// One token. The "me" token is tinted so it reads as "whoever is signed in".
struct TokenChip: View {
    let text: String
    var isMe = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            if isMe { Image(systemName: "person.fill").imageScale(.small) }
            Text(text).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(text)")
        }
        .font(.callout)
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(isMe ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15))
        )
        .foregroundStyle(isMe ? Color.accentColor : Color.primary)
    }
}

/// Clickable suggestions under a token field, so a list of logins seen in the current PRs
/// can be built with a few clicks.
struct SuggestionStrip: View {
    let items: [String]
    let offerMe: Bool
    let onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 3) {
            Text("Add:").font(.caption).foregroundStyle(.secondary)
            if offerMe { suggestion("me") }
            ForEach(items, id: \.self) { suggestion($0) }
        }
    }

    private func suggestion(_ value: String) -> some View {
        Button {
            onPick(value)
        } label: {
            Text(value)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Add \(value)")
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    /// The last child takes the rest of its line, as a token field's text input does.
    var stretchLast = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                // The last item on a line (the text input) takes the rest of the line.
                let isLastOverall = stretchLast && index == subviews.count - 1
                let width = isLastOverall ? max(size.width, bounds.maxX - x) : size.width
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
