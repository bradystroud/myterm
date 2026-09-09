import Foundation
import XCTest
@testable import MyTermCore

final class AgentSessionTitleTests: XCTestCase {
    func testTheStatusGlyphAnAgentWritesIsNotPartOfTheName() {
        XCTAssertEqual(AgentSessionTitle.sanitized("✳ Rename the tabs"), "Rename the tabs")
        XCTAssertEqual(AgentSessionTitle.sanitized("  ✻  Rename the tabs  "), "Rename the tabs")
    }

    func testANameKeepsThePunctuationItWasGiven() {
        XCTAssertEqual(AgentSessionTitle.sanitized("#28 import workspaces"), "#28 import workspaces")
        XCTAssertEqual(AgentSessionTitle.sanitized("[wip] caret"), "[wip] caret")
    }

    func testATitleThatSaysNothingIsNoName() {
        XCTAssertNil(AgentSessionTitle.sanitized(nil))
        XCTAssertNil(AgentSessionTitle.sanitized(""))
        XCTAssertNil(AgentSessionTitle.sanitized("   "))
        // Claude Code blanks the title on its way out of a conversation it could not open.
        XCTAssertNil(AgentSessionTitle.sanitized("✳ "))
    }

    func testATabLabelCannotCarryAPayload() {
        let long = String(repeating: "a", count: AgentSessionTitle.maximumLength + 40)
        XCTAssertEqual(AgentSessionTitle.sanitized(long)?.count, AgentSessionTitle.maximumLength)

        let smuggled = "name\u{1B}]0;other\u{07}\nsecond line"
        XCTAssertEqual(AgentSessionTitle.sanitized(smuggled), "name]0;othersecond line")
    }

    func testAResumedConversationCarriesBackTheNameTheUserGaveTheTab() throws {
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "abc-123"))

        XCTAssertEqual(
            AgentSessionResume.command(for: handle),
            "claude --resume 'abc-123'"
        )
        XCTAssertEqual(
            AgentSessionResume.command(for: handle, name: "Left pane"),
            "claude --resume 'abc-123' --name 'Left pane'"
        )
        XCTAssertEqual(
            AgentSessionResume.command(for: handle, name: "it's mine"),
            "claude --resume 'abc-123' --name 'it'\\''s mine'"
        )
        XCTAssertEqual(
            AgentSessionResume.command(for: handle, name: "   "),
            "claude --resume 'abc-123'"
        )
    }
}
