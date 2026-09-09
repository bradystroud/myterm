@testable import MyTerm
import AppKit
import MyTermCore
import SwiftUI
import XCTest

@MainActor
final class InteractionBehaviorTests: XCTestCase {
    func testMiddleClickRequiresExactButtonWindowAndBoundsHit() {
        let bounds = NSRect(x: 0, y: 0, width: 136, height: 26)

        XCTAssertTrue(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 2,
                eventWindowNumber: 7,
                viewWindowNumber: 7,
                locationInView: NSPoint(x: 68, y: 13),
                viewBounds: bounds
            )
        )
        XCTAssertFalse(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 0,
                eventWindowNumber: 7,
                viewWindowNumber: 7,
                locationInView: NSPoint(x: 68, y: 13),
                viewBounds: bounds
            )
        )
        XCTAssertFalse(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 2,
                eventWindowNumber: 7,
                viewWindowNumber: 8,
                locationInView: NSPoint(x: 68, y: 13),
                viewBounds: bounds
            )
        )
        XCTAssertFalse(
            MiddleClickTabInteraction.shouldClose(
                buttonNumber: 2,
                eventWindowNumber: 7,
                viewWindowNumber: 7,
                locationInView: NSPoint(x: bounds.maxX, y: 13),
                viewBounds: bounds
            )
        )
    }

    func testMiddleClickMonitorLifecycleInstallsAndRemovesExactlyOnce() {
        let lifecycle = MiddleClickMonitorLifecycle()
        var installCount = 0
        var removalCount = 0

        lifecycle.start {
            installCount += 1
            return NSObject()
        }
        lifecycle.start {
            installCount += 1
            return NSObject()
        }

        XCTAssertTrue(lifecycle.isMonitoring)
        XCTAssertEqual(installCount, 1)

        lifecycle.stop { _ in removalCount += 1 }
        lifecycle.stop { _ in removalCount += 1 }

        XCTAssertFalse(lifecycle.isMonitoring)
        XCTAssertEqual(removalCount, 1)
    }

    func testWorkspaceRowDropSplitsOnRenderedMidpointAndAppendsPastTheLastSibling() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let spacer = Workspace(title: "Spacer", folderID: folderID, isPinned: true)
        let target = Workspace(title: "Target", folderID: folderID, isPinned: true)
        let workspaces = [source, spacer, target]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 19,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: target.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 20,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: target.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 21,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testWorkspaceRowDropInsertsBeforeTheNextSiblingOnTheLowerHalf() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let middle = Workspace(title: "Middle", folderID: folderID, isPinned: true)
        let last = Workspace(title: "Last", folderID: folderID, isPinned: true)
        let workspaces = [source, middle, last]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: middle,
                locationY: 21,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: last.id, edge: .bottom)
        )
    }

    func testWorkspaceRowDropRejectsSelfDrop() {
        let folderID = WorkspaceFolderID()
        let workspace = Workspace(title: "Solo", folderID: folderID, isPinned: true)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: workspace,
                target: workspace,
                locationY: 10,
                renderedHeight: 40,
                in: [workspace]
            ),
            .rejected
        )
    }

    func testWorkspaceRowDropAcceptsCrossFolderDrops() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "In A", folderID: folderA)
        let target = Workspace(title: "In B", folderID: folderB)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: [source, target]
            ),
            .insert(before: target.id, edge: .top)
        )
    }

    func testWorkspaceRowDropAcceptsCrossFolderDropsAgainstUnfiled() {
        let folderA = WorkspaceFolderID()
        let source = Workspace(title: "In A", folderID: folderA)
        let target = Workspace(title: "Unfiled", folderID: nil)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: [source, target]
            ),
            .insert(before: target.id, edge: .top)
        )
    }

    func testWorkspaceRowDropAcceptsDropsAcrossThePinnedBand() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Pinned", folderID: folderID, isPinned: true)
        let target = Workspace(title: "Unpinned", folderID: folderID, isPinned: false)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: [source, target]
            ),
            .insert(before: target.id, edge: .top)
        )
    }

    func testWorkspaceRowDropUsesTheWholeRowToMoveSourceAfterItsNextSibling() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let next = Workspace(title: "Next", folderID: folderID, isPinned: true)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: next,
                locationY: 19,
                renderedHeight: 40,
                in: [source, next]
            ),
            .insert(before: nil, edge: .bottom)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: next,
                locationY: 21,
                renderedHeight: 40,
                in: [source, next]
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testWorkspaceRowDropUsesTheWholeRowToMoveSourceBeforeItsPreviousSibling() {
        let folderID = WorkspaceFolderID()
        let previous = Workspace(title: "Previous", folderID: folderID, isPinned: true)
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: previous,
                locationY: 21,
                renderedHeight: 40,
                in: [previous, source]
            ),
            .insert(before: previous.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: previous,
                locationY: 19,
                renderedHeight: 40,
                in: [previous, source]
            ),
            .insert(before: previous.id, edge: .top)
        )
    }

    func testWorkspaceRowAcceptsSourceIgnoresLocation() {
        let folderID = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderID, isPinned: true)
        let next = Workspace(title: "Next", folderID: folderID, isPinned: true)

        // Relationship-only acceptance remains independent from the pointer location.
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: source, target: next))
    }

    func testWorkspaceRowAcceptsSourceRejectsOnlyTheRowItself() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let pinnedInA = Workspace(title: "Pinned A", folderID: folderA, isPinned: true)
        let unpinnedInA = Workspace(title: "Unpinned A", folderID: folderA, isPinned: false)
        let pinnedInB = Workspace(title: "Pinned B", folderID: folderB, isPinned: true)

        XCTAssertFalse(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: pinnedInA))
        // A row accepts a source from another folder or another pinned band, because the drop
        // refiles and repins the workspace into the row it lands beside.
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: pinnedInB))
        XCTAssertTrue(SidebarDropCalculations.workspaceRowAcceptsSource(source: pinnedInA, target: unpinnedInA))
    }

    func testWorkspaceRowDropPlacesACrossFolderSourceAtThePointerEdge() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderA, isPinned: false)
        let first = Workspace(title: "First", folderID: folderB, isPinned: false)
        let second = Workspace(title: "Second", folderID: folderB, isPinned: false)
        let workspaces = [source, first, second]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: first,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: first.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: first,
                locationY: 30,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: second.id, edge: .bottom)
        )
    }

    func testWorkspaceRowDropPlacesAnUnpinnedSourceInThePinnedBand() {
        let folderID = WorkspaceFolderID()
        let pinned = Workspace(title: "Pinned", folderID: folderID, isPinned: true)
        let source = Workspace(title: "Source", folderID: folderID, isPinned: false)
        let workspaces = [pinned, source]

        // The source sits in another band, so neither the adjacency shortcut nor the no-op check
        // applies and the pointer half alone chooses the edge.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: pinned,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: pinned.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowDrop(
                source: source,
                target: pinned,
                locationY: 30,
                renderedHeight: 40,
                in: workspaces
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testContainerAcceptsWorkspaceReflectsWhetherTheWorkspaceIsAlreadyThere() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let filed = Workspace(title: "Filed", folderID: folderA)
        let unfiled = Workspace(title: "Unfiled", folderID: nil)

        XCTAssertFalse(SidebarDropCalculations.containerAcceptsWorkspace(source: filed, folderID: folderA))
        XCTAssertTrue(SidebarDropCalculations.containerAcceptsWorkspace(source: filed, folderID: folderB))
        XCTAssertTrue(SidebarDropCalculations.containerAcceptsWorkspace(source: filed, folderID: nil))
        XCTAssertFalse(SidebarDropCalculations.containerAcceptsWorkspace(source: unfiled, folderID: nil))
    }

    func testWorkspaceRowFeedbackShowsTheEdgeThePointerSelects() {
        let folderA = WorkspaceFolderID()
        let folderB = WorkspaceFolderID()
        let source = Workspace(title: "Source", folderID: folderA, isPinned: true)
        let target = Workspace(title: "Target", folderID: folderA, isPinned: true)
        let otherFolder = Workspace(title: "Other", folderID: folderB, isPinned: true)
        let workspaces = [source, target, otherFolder]

        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(source.id),
                target: target,
                locationY: 30,
                renderedHeight: 40,
                in: workspaces
            ),
            .insertion(.bottom)
        )
        // A source from another folder now reads as an insertion rather than a refused drop.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(otherFolder.id),
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            .insertion(.top)
        )
        // The row a drag started from shows nothing, and a folder payload never lands on a row.
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .workspace(source.id),
                target: source,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            SidebarDropFeedback.none
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                .folder(folderB),
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            SidebarDropFeedback.none
        )
        XCTAssertEqual(
            SidebarDropCalculations.workspaceRowFeedback(
                nil,
                target: target,
                locationY: 10,
                renderedHeight: 40,
                in: workspaces
            ),
            SidebarDropFeedback.none
        )
    }

    func testFolderRowFeedbackSeparatesFilingFromReordering() {
        let folderA = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let folderB = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let workspace = Workspace(title: "Workspace", folderID: folderA.id)
        let folders = [folderA, folderB]

        // A workspace lands inside the folder, so the row highlights instead of showing an edge.
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .workspace(workspace.id),
                folderID: folderB.id,
                nextFolderID: nil,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            .highlight
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .workspace(workspace.id),
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            SidebarDropFeedback.none
        )
        // A folder lands beside the row, so it shows the edge the pointer selects.
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .folder(folderB.id),
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            .insertion(.top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                .folder(folderA.id),
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            SidebarDropFeedback.none
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowFeedback(
                nil,
                folderID: folderA.id,
                nextFolderID: folderB.id,
                locationY: 10,
                renderedHeight: 40,
                workspaces: [workspace],
                folders: folders
            ),
            SidebarDropFeedback.none
        )
    }

    func testContainerHighlightAcceptsOnlyPayloadsThatCanMoveThere() {
        let folderA = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let folderB = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let workspace = Workspace(title: "Workspace", folderID: folderA.id)

        XCTAssertTrue(
            SidebarDropCalculations.containerAcceptsDragItem(
                .workspace(workspace.id),
                folderID: folderB.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertFalse(
            SidebarDropCalculations.containerAcceptsDragItem(
                .workspace(workspace.id),
                folderID: folderA.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertTrue(
            SidebarDropCalculations.containerAcceptsDragItem(
                .folder(folderA.id),
                folderID: folderB.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertFalse(
            SidebarDropCalculations.containerAcceptsDragItem(
                .folder(folderA.id),
                folderID: nil,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
        XCTAssertFalse(
            SidebarDropCalculations.containerAcceptsDragItem(
                .folder(folderA.id),
                folderID: folderA.id,
                workspaces: [workspace],
                folders: [folderA, folderB]
            )
        )
    }

    func testFolderDropTargetsFirstBoundaryAndEndPositions() {
        let firstID = WorkspaceFolderID()
        let nextID = WorkspaceFolderID()

        XCTAssertEqual(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nextID,
                locationY: 0,
                renderedHeight: 40
            ),
            firstID
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nextID,
                locationY: 20,
                renderedHeight: 40
            ),
            firstID
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nextID,
                locationY: 21,
                renderedHeight: 40
            ),
            nextID
        )
        XCTAssertNil(
            SidebarDropCalculations.folderTarget(
                folderID: firstID,
                nextFolderID: nil,
                locationY: 40,
                renderedHeight: 40
            )
        )
        XCTAssertEqual(
            SidebarDropCalculations.renderedHeight(measured: 44, minimum: 30),
            44
        )
        XCTAssertEqual(
            SidebarDropCalculations.renderedHeight(measured: 0, minimum: 30),
            30
        )
    }

    func testFolderRowDropRejectsSelfDrop() {
        let id = WorkspaceFolderID()

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: id,
                folderID: id,
                nextFolderID: nil,
                locationY: 10,
                renderedHeight: 40,
                in: [WorkspaceFolder(id: id, title: "Solo")]
            ),
            .rejected
        )
    }

    func testFolderRowDropUsesTheWholeRowToMoveSourceBeforeItsPreviousSibling() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: c.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: b.id, edge: .top)
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: c.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 19,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: b.id, edge: .top)
        )
    }

    func testFolderRowDropUsesTheWholeRowToMoveSourceAfterItsNextSibling() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 19,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: c.id, edge: .bottom)
        )
        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: c.id, edge: .bottom)
        )
    }

    func testFolderRowDropInsertsBeforeTheTargetOnTheUpperHalf() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: c.id,
                folderID: a.id,
                nextFolderID: b.id,
                locationY: 19,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: a.id, edge: .top)
        )
    }

    func testFolderRowDropInsertsBeforeTheNextSiblingOnTheLowerHalf() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let c = WorkspaceFolder(id: WorkspaceFolderID(), title: "C")
        let folders = [a, b, c]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: c.id,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: c.id, edge: .bottom)
        )
    }

    func testFolderRowDropAppendsPastTheLastFolder() {
        let a = WorkspaceFolder(id: WorkspaceFolderID(), title: "A")
        let b = WorkspaceFolder(id: WorkspaceFolderID(), title: "B")
        let folders = [a, b]

        XCTAssertEqual(
            SidebarDropCalculations.folderRowDrop(
                sourceID: a.id,
                folderID: b.id,
                nextFolderID: nil,
                locationY: 21,
                renderedHeight: 40,
                in: folders
            ),
            .insert(before: nil, edge: .bottom)
        )
    }

    func testSidebarVisibleRowsKeepStableIDsAcrossFolderExpansionAndInsertions() {
        let folderID = WorkspaceFolderID()
        var folder = WorkspaceFolder(id: folderID, title: "Folder", isExpanded: false)
        let firstWorkspace = Workspace(id: WorkspaceID(), title: "First", folderID: folderID)
        let secondWorkspace = Workspace(id: WorkspaceID(), title: "Second", folderID: folderID)

        let collapsedEmpty = SidebarVisibleRows.filed(folders: [folder], workspaces: [])
        let collapsedWithFirstWorkspace = SidebarVisibleRows.filed(
            folders: [folder],
            workspaces: [firstWorkspace]
        )

        folder.isExpanded = true
        let expandedWithFirstWorkspace = SidebarVisibleRows.filed(
            folders: [folder],
            workspaces: [firstWorkspace]
        )
        let expandedWithSecondWorkspace = SidebarVisibleRows.filed(
            folders: [folder],
            workspaces: [firstWorkspace, secondWorkspace]
        )

        XCTAssertEqual(collapsedEmpty, [.folder(folderID)])
        XCTAssertEqual(collapsedWithFirstWorkspace, [.folder(folderID)])
        XCTAssertEqual(
            expandedWithFirstWorkspace,
            [.folder(folderID), .workspace(firstWorkspace.id)]
        )
        XCTAssertEqual(
            expandedWithSecondWorkspace,
            [.folder(folderID), .workspace(firstWorkspace.id), .workspace(secondWorkspace.id)]
        )
        XCTAssertEqual(
            expandedWithFirstWorkspace.map(\.id),
            expandedWithSecondWorkspace.prefix(2).map(\.id)
        )
    }

    func testSidebarDragItemsPreserveTheirIdentifiersInTypedTransferPayloads() throws {
        let workspaceID = WorkspaceID()
        let folderID = WorkspaceFolderID()

        let workspaceData = try JSONEncoder().encode(SidebarDragItem.workspace(workspaceID))
        let folderData = try JSONEncoder().encode(SidebarDragItem.folder(folderID))

        XCTAssertEqual(try JSONDecoder().decode(SidebarDragItem.self, from: workspaceData), .workspace(workspaceID))
        XCTAssertEqual(try JSONDecoder().decode(SidebarDragItem.self, from: folderData), .folder(folderID))
    }

    func testInitialFirstResponderRequestWaitsForAttachmentAndRunsOnce() {
        let focusRequest = InitialFirstResponderRequest()
        var requestCount = 0

        focusRequest.requestIfNeeded(isAttachedToWindow: false) { requestCount += 1 }
        XCTAssertFalse(focusRequest.didRequest)
        XCTAssertEqual(requestCount, 0)

        focusRequest.requestIfNeeded(isAttachedToWindow: true) { requestCount += 1 }
        focusRequest.requestIfNeeded(isAttachedToWindow: true) { requestCount += 1 }

        XCTAssertTrue(focusRequest.didRequest)
        XCTAssertEqual(requestCount, 1)
    }

    func testWorkspaceCommandShortcutDeclarations() {
        XCTAssertEqual(
            MyTermCommandShortcuts.newFolder,
            KeyChord(key: "n", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.decreaseWorkspaceFontSize,
            KeyChord(key: "-", modifiers: [.command])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.increaseWorkspaceFontSize,
            KeyChord(key: "=", modifiers: [.command])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.previousTab,
            KeyChord(key: "\t", modifiers: [.control, .shift])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.nextTab,
            KeyChord(key: "\t", modifiers: [.control])
        )
        XCTAssertEqual(
            MyTermCommandShortcuts.togglePaneFullScreen,
            KeyChord(key: "\r", modifiers: [.command, .shift])
        )
    }

    func testPaneTabDropPreviewOccupiesExactlyHalfTheDestinationPane() {
        let size = CGSize(width: 240, height: 120)

        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .left, in: size),
            CGRect(x: 0, y: 0, width: 120, height: 120)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .right, in: size),
            CGRect(x: 120, y: 0, width: 120, height: 120)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .top, in: size),
            CGRect(x: 0, y: 0, width: 240, height: 60)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.frame(for: .bottom, in: size),
            CGRect(x: 0, y: 60, width: 240, height: 60)
        )
        XCTAssertEqual(
            PaneTabDropPreviewFrame.centerFrame(in: size),
            CGRect(x: 60, y: 30, width: 120, height: 60)
        )
    }

    func testWorkspaceSplitRatioAdjustmentKeepsWeightsNormalizedAndUsable() {
        let weights = WorkspaceSplitRatioResolver.adjusting(
            [0.5, 0.5],
            dividerAt: 0,
            translation: 30,
            availableLength: 200
        )

        XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 0.000_001)
        XCTAssertEqual(weights[0], 0.65, accuracy: 0.000_001)
        XCTAssertEqual(weights[1], 0.35, accuracy: 0.000_001)
        XCTAssertTrue(weights.allSatisfy { $0 > 0 })
    }

    func testWorkspaceSplitKeyboardAdjustmentUsesOnlyMatchingAxis() {
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .left, orientation: .horizontal),
            .decrement
        )
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .right, orientation: .horizontal),
            .increment
        )
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .up, orientation: .vertical),
            .decrement
        )
        XCTAssertEqual(
            WorkspaceSplitKeyboardAdjustment.adjustment(for: .down, orientation: .vertical),
            .increment
        )
        XCTAssertNil(WorkspaceSplitKeyboardAdjustment.adjustment(for: .up, orientation: .horizontal))
        XCTAssertNil(WorkspaceSplitKeyboardAdjustment.adjustment(for: .left, orientation: .vertical))
    }

    func testFindFieldUsesItsOwnAccessiblePresentation() {
        XCTAssertEqual(
            BrowserTextFieldPresentation.findInPage,
            BrowserTextFieldPresentation(
                placeholder: "Find",
                accessibilityLabel: "Find in page",
                accessibilityHelp: "Find text on this page"
            )
        )
        XCTAssertNotEqual(
            BrowserTextFieldPresentation.findInPage,
            BrowserTextFieldPresentation.browserAddress
        )
    }
}
