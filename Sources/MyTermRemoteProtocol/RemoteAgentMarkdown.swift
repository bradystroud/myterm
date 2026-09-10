import Foundation

/// One piece of an agent's message, ready to be laid out.
///
/// Agents write markdown. SwiftUI's `Text` parses markdown only from a literal or from an
/// `AttributedString`, so a message handed over as a plain `String` shows its own backticks and
/// asterisks. Worse, `AttributedString` flattens block structure: parse a whole message at once and
/// the lists, headings, and paragraph breaks arrive as one run of text.
///
/// So the block structure is worked out here, and each block's inline formatting is left to
/// `AttributedString` where it does the right thing.
public enum RemoteAgentTextBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(number: Int, text: String)
    /// A fenced block. Never markdown: it is code or output, and its own characters are the content.
    case code(language: String?, text: String)
}

public enum RemoteAgentMarkdown {
    /// Splits a message into blocks, in order.
    ///
    /// Deliberately small. This reads the markdown agents actually write — fences, headings, and
    /// the two kinds of list — and treats everything else as a paragraph. A full parser would carry
    /// far more surface than a phone screen needs, and every case it added would be one more way to
    /// render a message differently from how its author wrote it.
    public static func blocks(of text: String) -> [RemoteAgentTextBlock] {
        var blocks: [RemoteAgentTextBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var codeLanguage: String?

        func endParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            guard !joined.isEmpty else { return }
            blocks.append(.paragraph(joined))
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if var open = code {
                    // A fence with nothing in it still closed a block, and an empty one is noise.
                    if !open.isEmpty || codeLanguage != nil {
                        while open.last?.isEmpty == true { open.removeLast() }
                        blocks.append(.code(language: codeLanguage, text: open.joined(separator: "\n")))
                    }
                    code = nil
                    codeLanguage = nil
                } else {
                    endParagraph()
                    code = []
                    let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = name.isEmpty ? nil : name
                }
                continue
            }

            if code != nil {
                // Inside a fence the original line survives untouched, indentation included.
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                endParagraph()
                continue
            }

            if let heading = heading(in: trimmed) {
                endParagraph()
                blocks.append(heading)
                continue
            }

            if let item = listItem(in: trimmed) {
                endParagraph()
                blocks.append(item)
                continue
            }

            paragraph.append(line)
        }

        // A message can end mid-fence, because the file is tailed while the agent is still writing.
        if let open = code, !open.isEmpty {
            blocks.append(.code(language: codeLanguage, text: open.joined(separator: "\n")))
        }
        endParagraph()
        return blocks
    }

    private static func heading(in line: String) -> RemoteAgentTextBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        // "#hashtag" is not a heading. The space is what makes it one.
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return .heading(level: hashes.count, text: title)
    }

    private static func listItem(in line: String) -> RemoteAgentTextBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .bullet(text)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .numbered(number: number, text: text)
    }
}
