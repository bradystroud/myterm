import Foundation
import XCTest
@testable import MyTermCore

final class AgentNotificationInboxTests: XCTestCase {
    private let workspaceID = WorkspaceID()
    private let tabGroupID = TabGroupID()

    private func record(
        _ inbox: inout AgentNotificationInbox,
        _ activity: AgentActivity,
        tabID: TabID,
        isTabVisible: Bool = false,
        at seconds: TimeInterval = 0
    ) {
        inbox.record(
            activity,
            workspaceID: workspaceID,
            tabGroupID: tabGroupID,
            tabID: tabID,
            isTabVisible: isTabVisible,
            date: Date(timeIntervalSince1970: seconds)
        )
    }

    func testAFinishedAgentInAHiddenTabIsFiled() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .finished, tabID: tabID)

        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.activity(forTab: tabID), .finished)
        XCTAssertTrue(inbox.containsTab(in: [tabID]))
    }

    func testAnAgentInTheTabInFrontOfTheUserIsFiledAlreadyRead() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .finished, tabID: tabID, isTabVisible: true, at: 10)
        record(&inbox, .awaitingInput, tabID: tabID, isTabVisible: true, at: 20)

        XCTAssertTrue(inbox.isEmpty, "the user has already seen it, so the bell stays quiet")
        XCTAssertNil(inbox.activity(forTab: tabID))
        XCTAssertEqual(inbox.history.map(\.activity), [.awaitingInput, .finished], "but the history is complete")
        XCTAssertEqual(inbox.history.map(\.isRead), [true, true])
    }

    func testTheNewestEntryComesFirst() {
        var inbox = AgentNotificationInbox()
        let first = TabID()
        let second = TabID()

        record(&inbox, .finished, tabID: first, at: 10)
        record(&inbox, .finished, tabID: second, at: 20)

        XCTAssertEqual(inbox.items.map(\.tabID), [second, first])
    }

    func testOneTabKeepsOneRowAndTheLatestTime() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .finished, tabID: tabID, at: 10)
        record(&inbox, .finished, tabID: tabID, at: 40)

        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.items.first?.date, Date(timeIntervalSince1970: 40))
        XCTAssertEqual(inbox.history.count, 1, "an entry nobody read is superseded, not kept")
    }

    func testATabThatNeedsTheUserAgainIsANewEntryAndTheReadOneStays() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .finished, tabID: tabID, at: 10)
        inbox.markRead(tabID: tabID)
        record(&inbox, .awaitingInput, tabID: tabID, at: 40)

        XCTAssertEqual(inbox.items.map(\.date), [Date(timeIntervalSince1970: 40)])
        XCTAssertEqual(inbox.activity(forTab: tabID), .awaitingInput)
        XCTAssertEqual(inbox.history.map(\.isRead), [false, true])
        XCTAssertEqual(inbox.history.map(\.date), [Date(timeIntervalSince1970: 40), Date(timeIntervalSince1970: 10)])
    }

    func testAQuestionOutranksAFinishedTurn() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .awaitingInput, tabID: tabID, at: 10)
        record(&inbox, .finished, tabID: tabID, at: 20)

        XCTAssertEqual(inbox.activity(forTab: tabID), .awaitingInput, "A question still needs an answer")
        XCTAssertEqual(inbox.items.first?.date, Date(timeIntervalSince1970: 10))

        record(&inbox, .awaitingInput, tabID: tabID, at: 30)
        XCTAssertEqual(inbox.count, 1)
    }

    func testAnAgentThatStartsWorkingAgainTakesItsRowBack() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .awaitingInput, tabID: tabID, at: 10)
        record(&inbox, .working, tabID: tabID)
        XCTAssertTrue(inbox.isEmpty)

        record(&inbox, .finished, tabID: tabID, at: 20)
        record(&inbox, .exited, tabID: tabID)
        XCTAssertTrue(inbox.isEmpty)

        record(&inbox, .finished, tabID: tabID, at: 30)
        record(&inbox, .ready, tabID: tabID)
        XCTAssertTrue(inbox.isEmpty)

        XCTAssertEqual(inbox.history.map(\.isRead), [true, true, true], "what happened stays on record, read")
    }

    func testReadingReadsOnlyTheTabsThatWereRead() {
        var inbox = AgentNotificationInbox()
        let read = TabID()
        let unread = TabID()
        record(&inbox, .finished, tabID: read, at: 10)
        record(&inbox, .finished, tabID: unread, at: 20)

        XCTAssertTrue(inbox.markRead(tabID: read))
        XCTAssertFalse(inbox.markRead(tabID: read), "A tab with nothing waiting has nothing to read")
        XCTAssertEqual(inbox.items.map(\.tabID), [unread])
        XCTAssertNil(inbox.activity(forTab: read))
        XCTAssertFalse(inbox.containsTab(in: [read]))

        inbox.markRead(tabIDs: [unread])
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(inbox.history.map(\.tabID), [unread, read], "reading keeps the entry as history")
    }

    func testClearingReadsTheWholeBacklog() {
        var inbox = AgentNotificationInbox()
        record(&inbox, .finished, tabID: TabID())
        record(&inbox, .awaitingInput, tabID: TabID())

        inbox.markAllRead()

        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(inbox.count, 0)
        XCTAssertEqual(inbox.history.count, 2)
    }

    func testTheHistoryForgetsTheOldestReadEntriesFirst() {
        var inbox = AgentNotificationInbox()
        let question = TabID()
        record(&inbox, .awaitingInput, tabID: question, at: 0)
        for second in 1...AgentNotificationInbox.capacity {
            let tabID = TabID()
            record(&inbox, .finished, tabID: tabID, at: TimeInterval(second))
            inbox.markRead(tabID: tabID)
        }

        XCTAssertEqual(inbox.history.count, AgentNotificationInbox.capacity)
        XCTAssertEqual(inbox.history.last?.tabID, question, "the oldest entry is the one still waiting, so it stays")
        XCTAssertEqual(inbox.history.first?.date, Date(timeIntervalSince1970: TimeInterval(AgentNotificationInbox.capacity)))
        XCTAssertFalse(inbox.history.contains { $0.date == Date(timeIntervalSince1970: 1) }, "the oldest read entry went")
    }

    func testTheInboxSurvivesEncoding() throws {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()
        record(&inbox, .finished, tabID: tabID, at: 10)
        inbox.markRead(tabID: tabID)
        record(&inbox, .awaitingInput, tabID: TabID(), at: 20)

        let decoded = try JSONDecoder().decode(AgentNotificationInbox.self, from: JSONEncoder().encode(inbox))

        XCTAssertEqual(decoded, inbox)
    }

    func testAFiledEntryRemembersWhereItPointsTo() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()
        record(&inbox, .awaitingInput, tabID: tabID, at: 5)

        let entry = inbox.items.first
        XCTAssertEqual(entry?.tabID, tabID)
        XCTAssertEqual(entry?.workspaceID, workspaceID)
        XCTAssertEqual(entry?.tabGroupID, tabGroupID)
        XCTAssertEqual(entry?.activity, .awaitingInput)
        XCTAssertEqual(entry?.date, Date(timeIntervalSince1970: 5))
    }
}
