import XCTest
@testable import MyTermRemoteProtocol

final class AgentMarkdownTests: XCTestCase {
    func testParagraphsAreSplitOnBlankLinesAndJoinedAcrossWrappedLines() {
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "First line\nstill first.\n\nSecond **bold**."),
            [.paragraph("First line still first."), .paragraph("Second **bold**.")]
        )
    }

    func testHeadingsListsAndQuotesBecomeTheirOwnBlocks() {
        let text = """
        ## Findings

        - one
        - two
          continued
        1. first
        2. second
        > note
        """
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [
                .heading(level: 2, "Findings"),
                .bullets(["one", "two continued"]),
                .numbered(["first", "second"]),
                .quote("note"),
            ]
        )
    }

    func testAFencedBlockKeepsItsLinesAndLanguage() {
        let text = "Run:\n```bash\nmake test\n\nmake build\n```\nDone."
        XCTAssertEqual(
            AgentMarkdown.blocks(in: text),
            [.paragraph("Run:"), .code(language: "bash", "make test\n\nmake build"), .paragraph("Done.")]
        )
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(
            AgentMarkdown.blocks(in: "```\nlet x = 1"),
            [.code(language: nil, "let x = 1")]
        )
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(AgentMarkdown.blocks(in: "#hashtag"), [.paragraph("#hashtag")])
    }
}
