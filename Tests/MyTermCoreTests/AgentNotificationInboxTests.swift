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

    func testAnAgentInTheTabInFrontOfTheUserIsNeverFiled() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .finished, tabID: tabID, isTabVisible: true)
        record(&inbox, .awaitingInput, tabID: tabID, isTabVisible: true)

        XCTAssertTrue(inbox.isEmpty)
    }

    func testTheNewestEntryComesFirst() {
        var inbox = AgentNotificationInbox()
        let first = TabID()
        let second = TabID()

        record(&inbox, .finished, tabID: first, at: 10)
        record(&inbox, .finished, tabID: second, at: 20)

        XCTAssertEqual(inbox.items.map(\.id), [second, first])
    }

    func testOneTabKeepsOneRowAndTheLatestTime() {
        var inbox = AgentNotificationInbox()
        let tabID = TabID()

        record(&inbox, .finished, tabID: tabID, at: 10)
        record(&inbox, .finished, tabID: tabID, at: 40)

        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.items.first?.date, Date(timeIntervalSince1970: 40))
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

        record(&inbox, .awaitingInput, tabID: tabID)
        record(&inbox, .working, tabID: tabID)
        XCTAssertTrue(inbox.isEmpty)

        record(&inbox, .finished, tabID: tabID)
        record(&inbox, .exited, tabID: tabID)
        XCTAssertTrue(inbox.isEmpty)

        record(&inbox, .finished, tabID: tabID)
        record(&inbox, .ready, tabID: tabID)
        XCTAssertTrue(inbox.isEmpty)
    }

    func testReadingRemovesOnlyTheTabsThatWereRead() {
        var inbox = AgentNotificationInbox()
        let read = TabID()
        let unread = TabID()
        record(&inbox, .finished, tabID: read)
        record(&inbox, .finished, tabID: unread)

        XCTAssertTrue(inbox.markRead(tabID: read))
        XCTAssertFalse(inbox.markRead(tabID: read), "A tab with nothing waiting has nothing to read")
        XCTAssertEqual(inbox.items.map(\.id), [unread])

        inbox.markRead(tabIDs: [unread])
        XCTAssertTrue(inbox.isEmpty)
    }

    func testClearingEmptiesTheWholeBacklog() {
        var inbox = AgentNotificationInbox()
        record(&inbox, .finished, tabID: TabID())
        record(&inbox, .awaitingInput, tabID: TabID())

        inbox.removeAll()

        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(inbox.count, 0)
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
