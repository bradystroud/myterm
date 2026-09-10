import XCTest

@testable import MyTermRemoteProtocol

/// Agents write markdown, and a phone that shows its raw characters is showing the wrong thing.
final class RemoteAgentMarkdownTests: XCTestCase {
    func testPlainProseIsOneParagraph() {
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "Done. The file exists."),
            [.paragraph("Done. The file exists.")]
        )
    }

    func testABlankLineSeparatesParagraphs() {
        let blocks = RemoteAgentMarkdown.blocks(of: "First thing.\n\nSecond thing.")
        XCTAssertEqual(blocks, [.paragraph("First thing."), .paragraph("Second thing.")])
    }

    func testWrappedLinesStayInOneParagraph() {
        // A paragraph the agent wrapped is still a paragraph. Splitting on every newline would put
        // a gap in the middle of a sentence.
        let blocks = RemoteAgentMarkdown.blocks(of: "One sentence\nthat was wrapped.")
        XCTAssertEqual(blocks, [.paragraph("One sentence\nthat was wrapped.")])
    }

    // MARK: - Headings

    func testAHeadingIsReadWithItsLevel() {
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "## What changed"),
            [.heading(level: 2, text: "What changed")]
        )
    }

    func testAHashWithNoSpaceIsNotAHeading() {
        // "#42" and "#hashtag" are ordinary text. The space is what makes a heading.
        XCTAssertEqual(RemoteAgentMarkdown.blocks(of: "#42 is the issue"), [.paragraph("#42 is the issue")])
    }

    func testSevenHashesIsNotAHeading() {
        let text = "####### too deep"
        XCTAssertEqual(RemoteAgentMarkdown.blocks(of: text), [.paragraph(text)])
    }

    // MARK: - Lists

    func testEveryBulletMarkerIsRead() {
        for marker in ["-", "*", "+"] {
            XCTAssertEqual(
                RemoteAgentMarkdown.blocks(of: "\(marker) first\n\(marker) second"),
                [.bullet("first"), .bullet("second")],
                "marker \(marker)"
            )
        }
    }

    func testANumberedListKeepsItsNumbers() {
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "1. first\n2. second"),
            [.numbered(number: 1, text: "first"), .numbered(number: 2, text: "second")]
        )
    }

    func testADecimalInProseIsNotAListItem() {
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "3.14 is close enough"),
            [.paragraph("3.14 is close enough")]
        )
    }

    // MARK: - Fenced code

    func testAFencedBlockKeepsItsOwnCharacters() {
        // Markdown inside a fence is content, not formatting. This is the block that must never be
        // parsed: it is usually the command the person most needs to read exactly.
        let text = "Run this:\n```bash\ngit commit -m \"**not bold**\"\n```\nThen push."
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: text),
            [
                .paragraph("Run this:"),
                .code(language: "bash", text: "git commit -m \"**not bold**\""),
                .paragraph("Then push."),
            ]
        )
    }

    func testAFenceKeepsItsIndentation() {
        let text = "```\nif true {\n    return\n}\n```"
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: text),
            [.code(language: nil, text: "if true {\n    return\n}")]
        )
    }

    func testAFenceWithNoLanguageHasNone() {
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "```\nplain\n```"),
            [.code(language: nil, text: "plain")]
        )
    }

    func testAnUnclosedFenceStillArrives() {
        // The transcript is tailed, so a message can be read while the agent is still writing it.
        // Dropping the block until the closing fence lands would make output flicker in and out.
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "Here:\n```swift\nlet x = 1"),
            [.paragraph("Here:"), .code(language: "swift", text: "let x = 1")]
        )
    }

    func testAListInsideAFenceIsNotAList() {
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: "```\n- not a bullet\n# not a heading\n```"),
            [.code(language: nil, text: "- not a bullet\n# not a heading")]
        )
    }

    // MARK: - Shapes that must not crash

    func testEmptyAndBlankTextProduceNoBlocks() {
        XCTAssertTrue(RemoteAgentMarkdown.blocks(of: "").isEmpty)
        XCTAssertTrue(RemoteAgentMarkdown.blocks(of: "\n\n   \n").isEmpty)
    }

    func testAMessageThatIsOnlyAFenceMarkerProducesNoBlocks() {
        XCTAssertTrue(RemoteAgentMarkdown.blocks(of: "```").isEmpty)
    }

    func testAWholeMessageKeepsItsOrder() {
        let text = """
        ## Summary

        I changed two things.

        - the reader
        - the view

        ```swift
        let x = 1
        ```

        Done.
        """
        XCTAssertEqual(
            RemoteAgentMarkdown.blocks(of: text),
            [
                .heading(level: 2, text: "Summary"),
                .paragraph("I changed two things."),
                .bullet("the reader"),
                .bullet("the view"),
                .code(language: "swift", text: "let x = 1"),
                .paragraph("Done."),
            ]
        )
    }
}
