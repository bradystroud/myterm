import AppKit
import SwiftTerm
import XCTest
import MyTermCore
@testable import MyTermPlatform

@MainActor
final class AgentActivityTerminalTests: XCTestCase {
    func testTheTerminalReportsTheEscapeSequenceAHookWrites() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reports: [AgentActivityReport] = []
        view.onAgentActivity = { reports.append($0) }

        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=finished\u{1B}\\")
        XCTAssertEqual(reports, [AgentActivityReport(agent: "claude", activity: .finished)])

        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);agent=claude;event=awaiting_input\u{07}")
        XCTAssertEqual(reports.last, AgentActivityReport(agent: "claude", activity: .awaitingInput))
    }

    func testOrdinaryOutputAndOtherEscapesAreNotReports() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var reportCount = 0
        view.onAgentActivity = { _ in reportCount += 1 }

        view.feed("agent=claude;event=finished\n")
        view.feed("\u{1B}]0;a window title\u{07}")
        view.feed("\u{1B}]\(AgentActivityMarker.oscCode);nothing useful\u{07}")
        XCTAssertEqual(reportCount, 0)
    }

    func testTheTerminalReportsTheTitleAnAgentWrites() {
        let view = MyTermLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let delegate = TitleRecordingDelegate()
        view.processDelegate = delegate

        // What Claude Code writes when its conversation is named.
        view.feed("\u{1B}]0;✳ Rename the tabs\u{07}")
        XCTAssertEqual(delegate.titles, ["✳ Rename the tabs"])
    }
}

/// Records what the terminal reports as its title, the way `SwiftTermTerminalSession` does.
@MainActor
private final class TitleRecordingDelegate: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    var titles: [String] = []

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        titles.append(title)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

private extension MyTermLocalProcessTerminalView {
    /// Pushes bytes through the same path the process output takes.
    func feed(_ text: String) {
        dataReceived(slice: ArraySlice(Array(text.utf8)))
    }
}
