import Foundation

/// The name an agent gives the conversation running in a pane.
///
/// Claude Code writes its session name to the terminal title, ahead of a status glyph, and writes it
/// again when `/rename` changes the name. That title is the whole channel: there is no command that
/// asks a running agent what its conversation is called.
///
/// The title arrives as terminal bytes, which any program in the pane can write, so what a tab shows
/// is trimmed to a plain short name and nothing else.
public enum AgentSessionTitle {
    /// Long enough for the sentence-shaped topic titles agents generate, short enough that a tab
    /// label can never carry a payload.
    public static let maximumLength = 128

    /// Agents put a status glyph in front of the name. The name is the part a tab wants.
    private static let decoration = CharacterSet.symbols.union(.whitespacesAndNewlines)

    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = Array(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        while let first = scalars.first, decoration.contains(first) {
            scalars.removeFirst()
        }
        let name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(maximumLength))
    }
}
