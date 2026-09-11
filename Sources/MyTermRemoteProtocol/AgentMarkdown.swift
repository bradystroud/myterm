import Foundation

/// One block of an agent's message, split out so a device can lay it out.
///
/// Agents write markdown, and a phone shows what they wrote as prose. SwiftUI reads inline
/// markdown from a literal but never from a value, and it knows nothing of blocks either way, so
/// the split into blocks lives here, where it can be tested, and the inline styling stays with the
/// view. Text inside a block still carries its inline markdown.
public enum AgentMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(language: String?, String)
}

public enum AgentMarkdown {
    /// Splits a message into blocks. A malformed message is still shown: an unclosed fence runs to
    /// the end, and anything unrecognised is a paragraph.
    public static func blocks(in text: String) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var code: [String]?
        var codeLanguage: String?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets = []
            }
            if !numbered.isEmpty {
                blocks.append(.numbered(numbered))
                numbered = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: " ")))
                quote = []
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var openCode = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, openCode.joined(separator: "\n")))
                    code = nil
                    codeLanguage = nil
                } else {
                    openCode.append(line)
                    code = openCode
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                code = []
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            if let heading = heading(in: trimmed) {
                flush()
                blocks.append(heading)
                continue
            }

            if let item = listItem(in: trimmed, markers: ["- ", "* ", "+ "]) {
                if !paragraph.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
                bullets.append(item)
                continue
            }

            if let item = numberedItem(in: trimmed) {
                if !paragraph.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush() }
                numbered.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }

            // A line under a list item that is indented continues that item.
            if line.hasPrefix("  "), let last = bullets.popLast() {
                bullets.append(last + " " + trimmed)
                continue
            }
            if line.hasPrefix("  "), let last = numbered.popLast() {
                numbered.append(last + " " + trimmed)
                continue
            }

            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(trimmed)
        }

        if let openCode = code {
            blocks.append(.code(language: codeLanguage, openCode.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(in line: String) -> AgentMarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(in line: String, markers: [String]) -> String? {
        for marker in markers where line.hasPrefix(marker) {
            return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(in line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }
}
