import Foundation
import MyTermRemoteProtocol
import XCTest

@testable import MyTermRemoteHost

/// The reader turns an agent's own record into the messages a device shows.
///
/// The fixtures here are the shapes a real transcript actually holds, taken from a live Claude Code
/// session: a person's message as a bare string, an assistant turn mixing thinking with a tool
/// request, and a result that is sometimes a string and sometimes a list carrying an image.
final class AgentTranscriptReaderTests: XCTestCase {
    private let reader = AgentTranscriptReader()

    // MARK: - Turns

    func testAPersonsMessageIsABareStringRatherThanBlocks() {
        let line = """
        {"type":"user","uuid":"u1","timestamp":"2026-09-07T04:42:39.983Z",\
        "message":{"role":"user","content":"fix the build"}}
        """
        let entry = reader.entry(from: line)
        XCTAssertEqual(entry?.role, .user)
        XCTAssertEqual(entry?.blocks, [.text("fix the build")])
    }

    func testAnAssistantTurnKeepsThinkingApartFromWhatItSaid() {
        let line = """
        {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[\
        {"type":"thinking","thinking":"weighing it up","signature":"x"},\
        {"type":"text","text":"Done."}]}}
        """
        XCTAssertEqual(reader.entry(from: line)?.blocks, [.thinking("weighing it up"), .text("Done.")])
    }

    func testATimestampWithFractionalSecondsIsRead() {
        let line = """
        {"type":"user","uuid":"u1","timestamp":"2026-09-07T04:42:39.983Z",\
        "message":{"role":"user","content":"hi"}}
        """
        XCTAssertNotNil(reader.entry(from: line)?.timestamp)
    }

    func testALineThatIsNotPartOfTheConversationIsSkipped() {
        XCTAssertNil(reader.entry(from: #"{"type":"file-history-snapshot","messageId":"m"}"#))
        XCTAssertNil(reader.entry(from: #"{"type":"cost-state","totalCostUSD":1}"#))
        XCTAssertNil(reader.entry(from: "not json at all"))
        XCTAssertNil(reader.entry(from: ""))
    }

    func testAnEntryWithoutAnIdentifierIsSkipped() {
        // Without the agent's own identifier a device cannot tell a repeat from a new turn.
        let line = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
        XCTAssertNil(reader.entry(from: line))
    }

    // MARK: - Tools

    func testAToolRequestSaysWhatItWillDoRatherThanOnlyItsName() {
        let line = """
        {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[\
        {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf build",\
        "description":"Clean the build"}}]}}
        """
        guard case .toolUse(let use)? = reader.entry(from: line)?.blocks.first else {
            return XCTFail("expected a tool request")
        }
        XCTAssertEqual(use.name, "Bash")
        // The command, not the description: what it does beats what it says it does.
        XCTAssertEqual(use.summary, "rm -rf build")
        XCTAssertTrue(use.detail.contains("command: rm -rf build"))
        XCTAssertTrue(use.detail.contains("description: Clean the build"))
    }

    func testASummaryPrefersTheSubjectKeyTheToolActuallyUses() {
        XCTAssertEqual(
            AgentTranscriptReader.summary(ofToolNamed: "Read", input: ["file_path": "/tmp/a.txt"]),
            "/tmp/a.txt"
        )
        XCTAssertEqual(
            AgentTranscriptReader.summary(ofToolNamed: "Grep", input: ["pattern": "TODO"]),
            "TODO"
        )
    }

    func testDelegatingToAnotherAgentIsSummarisedByItsDescriptionNotItsBrief() {
        // The real shape of an Agent call. `prompt` is the whole brief sent to the other agent and
        // runs to hundreds of words; `description` is the one line a person would recognise.
        let summary = AgentTranscriptReader.summary(ofToolNamed: "Agent", input: [
            "description": "Find ASF Audits theme tokens",
            "prompt": String(repeating: "a very long brief ", count: 50),
            "subagent_type": "Explore",
        ])
        XCTAssertEqual(summary, "Find ASF Audits theme tokens")
    }

    func testACommandStillOutranksItsOwnDescription() {
        // What it does beats what it says it does, and reordering for Agent must not cost this.
        let summary = AgentTranscriptReader.summary(ofToolNamed: "Bash", input: [
            "command": "rm -rf build",
            "description": "Clean the build",
        ])
        XCTAssertEqual(summary, "rm -rf build")
    }

    func testASummaryFallsBackToTheRenderedInputForAnUnknownTool() {
        let summary = AgentTranscriptReader.summary(ofToolNamed: "Odd", input: ["shape": "square"])
        XCTAssertEqual(summary, "shape: square")
    }

    func testASummaryIsOneLine() {
        let summary = AgentTranscriptReader.summary(ofToolNamed: "Bash", input: ["command": "a\nb\nc"])
        XCTAssertFalse(summary.contains("\n"))
    }

    func testAResultCarriesItsTextAndWhetherItFailed() {
        let line = """
        {"type":"user","uuid":"u1","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"no such file"}]}}
        """
        guard case .toolResult(let result)? = reader.entry(from: line)?.blocks.first else {
            return XCTFail("expected a result")
        }
        XCTAssertEqual(result.toolUseID, "t1")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "no such file")
    }

    func testAResultThatMixesTextWithAnImageSaysAnImageWasThere() {
        // The bytes stay on the Mac. Saying so explains the gap without spending the payload.
        let line = """
        {"type":"user","uuid":"u1","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"t1","content":[\
        {"type":"text","text":"here"},{"type":"image","source":{"data":"AAAA"}}]}]}}
        """
        guard case .toolResult(let result)? = reader.entry(from: line)?.blocks.first else {
            return XCTFail("expected a result")
        }
        XCTAssertEqual(result.text, "here\n[image]")
        XCTAssertFalse(result.text.contains("AAAA"), "image bytes must not reach a device")
    }

    // MARK: - A request nobody has answered

    func testTheLastRequestWithNoAnswerIsMarkedPending() {
        // This is what a permission prompt looks like from the file's side, and it is the whole
        // reason someone opens this screen when they are away from the desk.
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        guard case .toolUse(let use)? = conversation.entries.last?.blocks.first else {
            return XCTFail("expected a tool request")
        }
        XCTAssertTrue(use.isPending)
    }

    func testARequestThatWasAnsweredIsNotPending() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a b c"}]}}"#,
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        for entry in conversation.entries {
            for block in entry.blocks {
                if case .toolUse(let use) = block {
                    XCTAssertFalse(use.isPending)
                }
            }
        }
    }

    // MARK: - Teammates

    func testDelegatingToAnotherAgentIsMarkedAsATeammateWithItsRole() {
        let line = """
        {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[\
        {"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Find theme tokens",\
        "prompt":"a long brief","subagent_type":"Explore"}}]}}
        """
        guard case .toolUse(let use)? = reader.entry(from: line)?.blocks.first else {
            return XCTFail("expected a tool request")
        }
        XCTAssertEqual(use.teammate, RemoteAgentTeammate(kind: .delegated, role: "Explore"))
        XCTAssertEqual(use.summary, "Find theme tokens")
    }

    func testAMessageToARunningAgentIsMarkedWithWhoItIsFor() {
        let line = """
        {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[\
        {"type":"tool_use","id":"t1","name":"SendMessage","input":{"to":"reviewer",\
        "message":"take another look at the migration"}}]}}
        """
        guard case .toolUse(let use)? = reader.entry(from: line)?.blocks.first else {
            return XCTFail("expected a tool request")
        }
        XCTAssertEqual(use.teammate, RemoteAgentTeammate(kind: .message, addressee: "reviewer"))
    }

    func testAMessageIsSummarisedByWhatWasSaid() {
        // Not by the rendered input, which repeats the addressee the card already names.
        let summary = AgentTranscriptReader.summary(ofToolNamed: "SendMessage", input: [
            "to": "reviewer",
            "message": "Two queries endpoints still use the legacy path. Is that deliberate?",
        ])
        XCTAssertEqual(summary, "Two queries endpoints still use the legacy path. Is that deliberate?")
    }

    func testAnOrdinaryToolIsNotATeammate() {
        // A wrench for Bash and a teammate for Agent. Showing a teammate where there is none would
        // be worse than showing none at all.
        XCTAssertNil(AgentTranscriptReader.teammate(ofToolNamed: "Bash", input: ["command": "ls"]))
        XCTAssertNil(AgentTranscriptReader.teammate(ofToolNamed: "Read", input: ["file_path": "/a"]))
    }

    func testADelegationWithNoNamedRoleIsStillATeammate() {
        let teammate = AgentTranscriptReader.teammate(ofToolNamed: "Agent", input: ["prompt": "go"])
        XCTAssertEqual(teammate, RemoteAgentTeammate(kind: .delegated, role: nil))
    }

    // MARK: - Caps

    func testALongResultIsCutAndSaysSo() {
        let huge = String(repeating: "x", count: RemoteAgentLimits.maximumBlockCharacters + 500)
        let line = """
        {"type":"user","uuid":"u1","message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"t1","content":"\(huge)"}]}}
        """
        guard case .toolResult(let result)? = reader.entry(from: line)?.blocks.first else {
            return XCTFail("expected a result")
        }
        XCTAssertTrue(result.isTruncated)
        XCTAssertLessThanOrEqual(result.text.count, RemoteAgentLimits.maximumBlockCharacters + 1)
    }

    func testABacklogPastTheCapDropsTheOldestAndSaysSo() {
        // Each block is cut to `maximumBlockCharacters` first, so the backlog cap is reached by the
        // number of entries rather than by the size of any one of them.
        let perEntry = RemoteAgentLimits.maximumBlockCharacters
        let count = (RemoteAgentLimits.maximumBacklogCharacters / perEntry) + 20
        let body = String(repeating: "y", count: perEntry + 500)
        let lines = (0..<count).map { index in
            """
            {"type":"assistant","uuid":"a\(index)","message":{"role":"assistant",\
            "content":[{"type":"text","text":"\(body)"}]}}
            """
        }
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertTrue(conversation.isTruncated)
        XCTAssertLessThan(conversation.entries.count, count)
        // The end of a conversation is what someone away from their desk came to read.
        XCTAssertEqual(conversation.entries.last?.id, "a\(count - 1)")
    }

    func testACappedBacklogAlwaysKeepsAtLeastTheLastEntry() {
        // One entry larger than the whole cap must still arrive, or the screen shows nothing.
        let body = String(repeating: "z", count: RemoteAgentLimits.maximumBacklogCharacters + 1_000)
        let line = """
        {"type":"assistant","uuid":"only","message":{"role":"assistant",\
        "content":[{"type":"text","text":"\(body)"}]}}
        """
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: [line])
        XCTAssertEqual(conversation.entries.count, 1)
    }

    // MARK: - The conversation's name

    func testTheAgentsOwnNameForTheConversationIsUsed() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"spike-proof.txt file creation","sessionId":"s"}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}"#,
        ]
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)
        XCTAssertEqual(conversation.title, "spike-proof.txt file creation")
    }

    // MARK: - Finding the file

    func testATranscriptIsFoundByItsSessionIdentifierAlone() throws {
        // The pane's directory moves as the person works, so rebuilding the agent's own directory
        // name is not reliable. The identifier is unique, so the file is found by name.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripts-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-someone-code")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = "87d84ef0-4227-42d8-92e3-3dafcf13979f"
        let file = project.appendingPathComponent("\(session).jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)

        let found = AgentTranscriptReader.transcriptURL(sessionID: session, projectsDirectory: root)
        // Resolved on both sides: the temporary directory is reached through a symlink, so the raw
        // paths differ by a /private prefix that says nothing about whether the file was found.
        XCTAssertEqual(
            found?.resolvingSymlinksInPath(),
            file.resolvingSymlinksInPath()
        )
        XCTAssertNil(
            AgentTranscriptReader.transcriptURL(sessionID: UUID().uuidString, projectsDirectory: root)
        )
    }

    func testASessionIdentifierThatCouldNameAnotherFileIsRefused() {
        // The identifier arrives as terminal bytes, and this one builds a path out of it.
        XCTAssertFalse(AgentTranscriptReader.isSafeSessionID("../../.ssh/id_rsa"))
        XCTAssertFalse(AgentTranscriptReader.isSafeSessionID("a/b"))
        XCTAssertFalse(AgentTranscriptReader.isSafeSessionID(""))
        XCTAssertFalse(AgentTranscriptReader.isSafeSessionID(String(repeating: "a", count: 65)))
        XCTAssertTrue(AgentTranscriptReader.isSafeSessionID("87d84ef0-4227-42d8-92e3-3dafcf13979f"))
    }

    // MARK: - A real session

    func testARealTranscriptProjectsToAReadableConversation() throws {
        // Captured from a live Claude Code session that hit a permission prompt, so this holds the
        // shapes the agent actually writes rather than the ones this test would like it to.
        let lines = Self.realSessionLines
        let conversation = reader.conversation(tabID: "tab", agent: "claude", lines: lines)

        XCTAssertEqual(conversation.title, "spike-proof.txt file creation")
        XCTAssertFalse(conversation.entries.isEmpty)

        let blocks = conversation.entries.flatMap(\.blocks)
        let names: [String] = blocks.compactMap {
            if case .toolUse(let use) = $0 { return use.name } else { return nil }
        }
        XCTAssertEqual(names, ["Bash"])

        let summaries: [String] = blocks.compactMap {
            if case .toolUse(let use) = $0 { return use.summary } else { return nil }
        }
        XCTAssertEqual(summaries.first, #"touch spike-proof.txt && echo "OK" > spike-proof.txt && cat spike-proof.txt"#)

        let results: [String] = blocks.compactMap {
            if case .toolResult(let result) = $0 { return result.text } else { return nil }
        }
        XCTAssertEqual(results, ["OK"])
    }

    private static let realSessionLines = [
        #"{"type":"ai-title","aiTitle":"spike-proof.txt file creation","sessionId":"87d84ef0"}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-07T10:10:00.123Z","message":{"role":"assistant","content":[{"type":"tool_use","caller":"x","id":"t1","name":"Bash","input":{"command":"touch spike-proof.txt && echo \"OK\" > spike-proof.txt && cat spike-proof.txt","description":"Create spike-proof.txt with OK"}}]}}"#,
        #"{"type":"user","uuid":"u1","timestamp":"2026-09-07T10:10:04.456Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"OK"}]}}"#,
        #"{"type":"assistant","uuid":"a2","timestamp":"2026-09-07T10:10:05.789Z","message":{"role":"assistant","content":[{"type":"text","text":"Done. The file `spike-proof.txt` exists and contains `OK`."}]}}"#,
        #"{"type":"cost-state","sessionId":"87d84ef0","totalCostUSD":0.28}"#,
    ]
}
