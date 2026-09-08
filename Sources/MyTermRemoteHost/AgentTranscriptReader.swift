import Foundation
import MyTermRemoteProtocol

/// Reads a coding agent's own record of a conversation and projects it onto the wire types.
///
/// Claude Code appends one JSON object per line to `~/.claude/projects/<slug>/<sessionID>.jsonl`
/// while the session runs. That file is the whole reason a device can show a conversation instead
/// of a terminal: it is already structured, already separated into turns, and already says which
/// tool ran with which input.
///
/// Two rules hold this apart from a mirror:
///
/// - The file's format belongs to the agent, not to MyTerm. Every field is read defensively, and a
///   line this does not understand is skipped rather than failing the conversation.
/// - Nothing reaches a device uncapped. A transcript carries whole files and whole command
///   outputs, so every projection cuts against `RemoteAgentLimits`.
public struct AgentTranscriptReader {
    public init() {}

    // MARK: - Finding the file

    /// The transcript for a session, found by identifier alone.
    ///
    /// The agent files a session under a directory named after the working directory it started in,
    /// and MyTerm cannot reliably reconstruct that name: the pane's directory changes as the person
    /// works. The session identifier is a UUID, so searching for the file by name is both simpler
    /// and more correct than rebuilding the slug.
    public static func transcriptURL(
        sessionID: String,
        projectsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        // The identifier reaches MyTerm as terminal bytes. It is validated before it is stored, and
        // it is checked again here, because this one builds a path out of it.
        guard isSafeSessionID(sessionID) else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let name = sessionID + ".jsonl"
        for directory in entries {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// A session identifier may only name a file. Anything that could climb out of the projects
    /// directory, or name something other than a transcript, is refused.
    static func isSafeSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - Projecting

    /// Everything a device needs for one conversation, cut to the backlog cap.
    ///
    /// Entries are dropped from the front, because the end of a conversation is the part someone
    /// away from their desk opened the screen to read.
    public func conversation(
        tabID: String,
        agent: String,
        lines: [String]
    ) -> RemoteAgentConversation {
        var entries: [RemoteAgentEntry] = []
        var title: String?
        var pending = PendingTools()

        for line in lines {
            guard let object = Self.object(from: line) else { continue }
            if let name = Self.title(from: object) {
                title = name
            }
            guard let entry = Self.entry(from: object, pending: &pending) else { continue }
            entries.append(entry)
        }

        entries = Self.markPending(in: entries, pending: pending)
        let (kept, isTruncated) = Self.cutToBacklog(entries)
        return RemoteAgentConversation(
            tabID: tabID,
            title: title,
            agent: agent,
            isTruncated: isTruncated,
            entries: kept
        )
    }

    /// One line, for the tail. Returns nothing for the many lines that are not part of the
    /// conversation a person reads.
    public func entry(from line: String) -> RemoteAgentEntry? {
        guard let object = Self.object(from: line) else { return nil }
        var pending = PendingTools()
        return Self.entry(from: object, pending: &pending)
    }

    /// The name the agent gave the conversation, when a line carries one.
    public func title(from line: String) -> String? {
        guard let object = Self.object(from: line) else { return nil }
        return Self.title(from: object)
    }

    // MARK: - Lines

    private static func object(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func title(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "ai-title",
              let raw = object["aiTitle"] as? String else {
            return nil
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(RemoteAgentLimits.maximumSummaryCharacters))
    }

    /// Tool requests seen so far, and the ones that have been answered.
    ///
    /// A request with no answer is a request the agent is still stopped on, which is what a
    /// permission prompt looks like from the file's side.
    struct PendingTools {
        var requested: Set<String> = []
        var answered: Set<String> = []
        var unanswered: Set<String> { requested.subtracting(answered) }
    }

    private static func entry(from object: [String: Any], pending: inout PendingTools) -> RemoteAgentEntry? {
        guard let type = object["type"] as? String,
              let role = RemoteAgentRole(rawValue: type),
              let message = object["message"] as? [String: Any] else {
            return nil
        }
        // The identifier is the agent's own, so a device that reattaches recognises what it has.
        guard let id = object["uuid"] as? String, !id.isEmpty else { return nil }

        let blocks = self.blocks(from: message["content"], pending: &pending)
        guard !blocks.isEmpty else { return nil }

        return RemoteAgentEntry(
            id: id,
            role: role,
            timestamp: timestamp(from: object["timestamp"]),
            blocks: blocks
        )
    }

    /// The agent writes fractional seconds. A parser without that option returns nothing for every
    /// line, which silently costs every timestamp, so both shapes are tried.
    private static func timestamp(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    private static func blocks(from content: Any?, pending: inout PendingTools) -> [RemoteAgentBlock] {
        // A person's own message is a bare string rather than a list of blocks.
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(cut(trimmed, to: RemoteAgentLimits.maximumBlockCharacters).text)]
        }
        guard let list = content as? [Any] else { return [] }

        var blocks: [RemoteAgentBlock] = []
        for element in list {
            guard let block = element as? [String: Any],
                  let kind = block["type"] as? String else {
                continue
            }
            switch kind {
            case "text":
                if let text = nonEmpty(block["text"] as? String) {
                    blocks.append(.text(cut(text, to: RemoteAgentLimits.maximumBlockCharacters).text))
                }
            case "thinking":
                if let text = nonEmpty(block["thinking"] as? String) {
                    blocks.append(.thinking(cut(text, to: RemoteAgentLimits.maximumBlockCharacters).text))
                }
            case "tool_use":
                if let use = toolUse(from: block) {
                    pending.requested.insert(use.id)
                    blocks.append(.toolUse(use))
                }
            case "tool_result":
                if let result = toolResult(from: block) {
                    pending.answered.insert(result.toolUseID)
                    blocks.append(.toolResult(result))
                }
            case "image":
                blocks.append(.image)
            default:
                continue
            }
        }
        return blocks
    }

    private static func toolUse(from block: [String: Any]) -> RemoteAgentToolUse? {
        guard let id = nonEmpty(block["id"] as? String),
              let name = nonEmpty(block["name"] as? String) else {
            return nil
        }
        let input = block["input"] as? [String: Any] ?? [:]
        return RemoteAgentToolUse(
            id: id,
            name: name,
            summary: summary(ofToolNamed: name, input: input),
            detail: cut(detail(of: input), to: RemoteAgentLimits.maximumDetailCharacters).text
        )
    }

    /// The one line a collapsed row shows.
    ///
    /// Tools name the thing they act on under different keys, and the tool's own name says nothing
    /// about whether it is about to read a file or remove one. These are the keys the agents in use
    /// actually put the subject in; anything else falls back to the rendered input.
    static func summary(ofToolNamed name: String, input: [String: Any]) -> String {
        // `description` outranks `prompt`, and `prompt` comes last of all. A tool that delegates
        // work carries both: a one-line description a person wrote, and the whole brief sent to the
        // other agent. Reading the brief first fills the row with a wall of text and buries what
        // the call was for.
        let subjectKeys = ["command", "file_path", "path", "pattern", "url", "description", "prompt"]
        for key in subjectKeys {
            if let value = nonEmpty(input[key] as? String) {
                return cut(value.replacingOccurrences(of: "\n", with: " "),
                           to: RemoteAgentLimits.maximumSummaryCharacters).text
            }
        }
        return cut(detail(of: input).replacingOccurrences(of: "\n", with: " "),
                   to: RemoteAgentLimits.maximumSummaryCharacters).text
    }

    /// The whole request, rendered for a person rather than as the JSON it arrived as.
    static func detail(of input: [String: Any]) -> String {
        guard !input.isEmpty else { return "" }
        return input.keys.sorted().compactMap { key -> String? in
            guard let value = input[key] else { return nil }
            return "\(key): \(describe(value))"
        }.joined(separator: "\n")
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let list as [Any]: return list.map(describe).joined(separator: ", ")
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: data, encoding: .utf8) else {
                return String(describing: value)
            }
            return text
        }
    }

    private static func toolResult(from block: [String: Any]) -> RemoteAgentToolResult? {
        guard let toolUseID = nonEmpty(block["tool_use_id"] as? String) else { return nil }
        let isError = block["is_error"] as? Bool ?? false
        let (text, isTruncated) = cut(resultText(from: block["content"]),
                                      to: RemoteAgentLimits.maximumBlockCharacters)
        return RemoteAgentToolResult(
            toolUseID: toolUseID,
            isError: isError,
            text: text,
            isTruncated: isTruncated
        )
    }

    /// A result is a plain string, or a list mixing text with images and references. The device is
    /// told an image was there rather than being sent one.
    private static func resultText(from content: Any?) -> String {
        if let text = content as? String { return text }
        guard let list = content as? [Any] else { return "" }
        return list.compactMap { element -> String? in
            guard let block = element as? [String: Any] else { return nil }
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: - Pending requests

    /// Marks the tool requests nothing has answered.
    ///
    /// This is what turns "the agent is stopped" into "the agent is stopped on *this*". Only the
    /// last entry's requests are marked: an unanswered request further back means the conversation
    /// moved on without it, not that someone is being asked about it now.
    static func markPending(in entries: [RemoteAgentEntry], pending: PendingTools) -> [RemoteAgentEntry] {
        let unanswered = pending.unanswered
        guard !unanswered.isEmpty, var last = entries.last else { return entries }
        var result = entries
        last.blocks = last.blocks.map { block in
            guard case .toolUse(var use) = block, unanswered.contains(use.id) else { return block }
            use.isPending = true
            return .toolUse(use)
        }
        result[result.count - 1] = last
        return result
    }

    // MARK: - Cutting

    static func cutToBacklog(_ entries: [RemoteAgentEntry]) -> (entries: [RemoteAgentEntry], isTruncated: Bool) {
        var total = 0
        var kept: [RemoteAgentEntry] = []
        for entry in entries.reversed() {
            total += weight(of: entry)
            if total > RemoteAgentLimits.maximumBacklogCharacters, !kept.isEmpty {
                return (kept.reversed(), true)
            }
            kept.append(entry)
        }
        return (kept.reversed(), false)
    }

    private static func weight(of entry: RemoteAgentEntry) -> Int {
        entry.blocks.reduce(0) { total, block in
            switch block {
            case .text(let value), .thinking(let value):
                return total + value.count
            case .toolUse(let use):
                return total + use.summary.count + use.detail.count
            case .toolResult(let result):
                return total + result.text.count
            case .image:
                return total + 16
            }
        }
    }

    /// Cuts on a character boundary and says whether it cut.
    static func cut(_ text: String, to limit: Int) -> (text: String, isTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)) + "…", true)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
