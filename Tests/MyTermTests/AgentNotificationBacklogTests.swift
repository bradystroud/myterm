import Foundation
import XCTest
import MyTermCore
import MyTermRemoteProtocol
@testable import MyTerm

/// The bell's backlog, fed by the same hook event as the cook.
@MainActor
final class AgentNotificationBacklogTests: XCTestCase {
    func testTheBacklogListsTheWaitingTabWithItsWorkspaceAndTabNames() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)

        let item = try XCTUnwrap(model.agentNotificationItems.first)
        XCTAssertEqual(model.agentNotificationCount, 1)
        XCTAssertEqual(item.id, tabID)
        XCTAssertEqual(item.activity, .awaitingInput)
        XCTAssertEqual(item.workspaceTitle, workspace.displayTitle)
        XCTAssertEqual(item.tabTitle, "Terminal")
        XCTAssertTrue(model.needsAgentAttention(workspaceID: workspace.id))
    }

    func testTheTabInFrontOfTheUserIsNotFiled() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)

        XCTAssertTrue(model.agentNotificationItems.isEmpty)
    }

    func testTheSelectedTabIsFiledWhileTheAppIsBehindAnother() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        harness.isApplicationActive = false

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: group.selectedTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        harness.isApplicationActive = true
        model.markVisibleTabsAsRead()
        XCTAssertTrue(model.agentNotificationItems.isEmpty, "Coming back to the app reads the tab on screen")
    }

    func testOpeningANotificationGoesToItsTabAndReadsIt() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        let item = try XCTUnwrap(model.agentNotificationItems.first)

        model.openAgentNotification(item)

        XCTAssertEqual(model.store.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(model.selectedWorkspace.orderedGroups.first?.selectedTabID, firstTabID)
        XCTAssertTrue(model.agentNotificationItems.isEmpty)
        XCTAssertNil(model.agentAttention(forTab: firstTabID), "The cook goes with the entry")
    }

    func testClearingEmptiesTheBacklogAndRetiresTheCooks() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)
        XCTAssertFalse(model.agentNotificationItems.isEmpty)
        XCTAssertEqual(model.agentAttention(forTab: tabID), .finished)

        model.clearAgentNotifications()

        XCTAssertTrue(model.agentNotificationItems.isEmpty)
        XCTAssertNil(model.agentAttention(forTab: tabID))
        XCTAssertFalse(model.needsAgentAttention(workspaceID: workspace.id))
    }

    func testTheBacklogDropsAnEntryWhoseTabIsGone() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        XCTAssertEqual(model.agentNotificationCount, 1)

        model.closeTab(firstTabID)

        XCTAssertTrue(model.agentNotificationItems.isEmpty)
    }

    func testTheNewestNotificationComesFirst() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)

        XCTAssertEqual(model.agentNotificationItems.map(\.id), [secondTabID, firstTabID])
    }

    // MARK: - What a device receives

    func testADeviceReceivesTheBacklogInTheBellsOrderWithItsNames() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let firstTabID = group.selectedTabID
        model.createTerminalTab()
        let secondTabID = try XCTUnwrap(model.selectedWorkspace.orderedGroups.first?.selectedTabID)
        model.createWorkspace()

        harness.record(.finished, workspaceID: workspace.id, tabGroupID: group.id, tabID: firstTabID)
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: secondTabID)

        let entries = try XCTUnwrap(model.remoteNotifications()).entries
        XCTAssertEqual(entries.map(\.tabID), [secondTabID.description, firstTabID.description])
        XCTAssertEqual(entries.map(\.activity), [.awaitingInput, .finished])
        XCTAssertEqual(entries.map(\.workspaceID), [workspace.id.description, workspace.id.description])
        XCTAssertEqual(entries.map(\.workspaceTitle), [workspace.displayTitle, workspace.displayTitle])
        XCTAssertEqual(entries.map(\.tabTitle), ["Terminal", "Terminal"])
        XCTAssertEqual(entries.map(\.date), model.agentNotificationItems.map(\.date))
    }

    func testTheBacklogADeviceReceivesNeverCarriesTheConversationIdentifier() throws {
        let harness = try makeHarness()
        let model = harness.model
        let workspace = model.selectedWorkspace
        let group = try XCTUnwrap(workspace.orderedGroups.first)
        let tabID = group.selectedTabID
        let handle = try XCTUnwrap(AgentSessionHandle(agent: "claude", sessionID: "secret-id-42"))
        try model.store.updateTerminalAgentSession(
            workspaceID: workspace.id,
            tabGroupID: group.id,
            tabID: tabID,
            agentSession: handle
        )
        model.createWorkspace()
        harness.record(.awaitingInput, workspaceID: workspace.id, tabGroupID: group.id, tabID: tabID)

        let encoded = try JSONEncoder().encode(
            RemoteControlMessage.notifications(try XCTUnwrap(model.remoteNotifications()))
        )
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(tabID.description), "precondition: the entry is in the message")
        XCTAssertFalse(text.contains("secret-id-42"))
    }

    private func makeHarness() throws -> AgentTestHarness {
        try AgentTestHarness { directory in
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
