import CoreTransferable
import Foundation
import MyTermCore
import SwiftUI
import UniformTypeIdentifiers

// This identifier is also declared in Packaging/Info.plist for the packaged app's exported
// document types; changing it here without updating that file breaks drops there while dev
// builds keep working.
extension UTType {
    static let mytermSidebarItem = UTType(exportedAs: "com.gordonbeeming.myterm.sidebar-item")
}

enum SidebarDragItem: Codable, Equatable, Sendable, Transferable {
    case workspace(WorkspaceID)
    case folder(WorkspaceFolderID)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mytermSidebarItem)
    }
}

/// What a sidebar row draws while a drag hovers over it. `.highlight` means the drop lands inside
/// the row, `.insertion` means it lands beside the row on that edge.
enum SidebarDropFeedback: Equatable {
    case none
    case highlight
    case insertion(SidebarDropCalculations.InsertionEdge)

    var insertionEdge: SidebarDropCalculations.InsertionEdge? {
        guard case .insertion(let edge) = self else { return nil }
        return edge
    }

    var isHighlighted: Bool { self == .highlight }
}

/// Rows resolve their own drop feedback because `dropDestination` only reports whether a row is
/// targeted, never where the pointer sits inside it. `DropInfo.location` in `dropUpdated` is what
/// lets the insertion line follow the pointer between the upper and lower halves of a row.
struct SidebarRowDropDelegate: DropDelegate {
    let feedback: (CGPoint) -> SidebarDropFeedback
    let commit: (CGPoint) -> Bool
    @Binding var current: SidebarDropFeedback

    func validateDrop(info: DropInfo) -> Bool {
        // A refusal here rejects the row for the rest of the drag, so accept on the payload type
        // and leave every position decision to `dropUpdated`. An in-flight sidebar drag that the
        // pasteboard does not report is still accepted, because resolved feedback proves it.
        info.hasItemsConforming(to: [.mytermSidebarItem]) || feedback(info.location) != .none
    }

    func dropEntered(info: DropInfo) {
        update(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = update(at: info.location)
        return DropProposal(operation: next == .none ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        update(to: .none)
    }

    func performDrop(info: DropInfo) -> Bool {
        update(to: .none)
        return commit(info.location)
    }

    @discardableResult
    private func update(at location: CGPoint) -> SidebarDropFeedback {
        let next = feedback(location)
        update(to: next)
        return next
    }

    private func update(to next: SidebarDropFeedback) {
        if current != next { current = next }
    }
}

/// The line a row draws on the edge where a dragged item will land.
struct SidebarInsertionLine: View {
    let leadingInset: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.leading, leadingInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum SidebarVisibleRow: Hashable, Identifiable {
    enum ID: Hashable {
        case folder(WorkspaceFolderID)
        case workspace(WorkspaceID)
    }

    case folder(WorkspaceFolderID)
    case workspace(WorkspaceID)

    var id: ID {
        switch self {
        case .folder(let folderID): .folder(folderID)
        case .workspace(let workspaceID): .workspace(workspaceID)
        }
    }
}

enum SidebarVisibleRows {
    static func filed(folders: [WorkspaceFolder], workspaces: [Workspace]) -> [SidebarVisibleRow] {
        let workspacesByFolder = Dictionary(grouping: workspaces, by: \.folderID)
        return folders.flatMap { folder in
            let children: [SidebarVisibleRow] = folder.isExpanded
                ? ordered(workspacesByFolder[folder.id, default: []]).map { .workspace($0.id) }
                : []
            return [.folder(folder.id)] + children
        }
    }

    private static func ordered(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }
    }
}

enum SidebarDropCalculations {
    static func renderedHeight(measured: CGFloat, minimum: CGFloat) -> CGFloat {
        measured > 0 ? measured : minimum
    }

    static func folderTarget(
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat
    ) -> WorkspaceFolderID? {
        locationY <= renderedHeight / 2 ? folderID : nextFolderID
    }

    enum InsertionEdge: Equatable {
        case top
        case bottom
    }

    enum WorkspaceRowDrop: Equatable {
        case rejected
        case insert(before: WorkspaceID?, edge: InsertionEdge)
    }

    /// Relationship-only acceptance (no pointer position involved): true whenever `source` can
    /// land somewhere in `target`'s row. A row always speaks for its own folder and pinned band,
    /// so accepting a source from elsewhere is what lets a drop both refile and repin it.
    static func workspaceRowAcceptsSource(source: Workspace, target: Workspace) -> Bool {
        source.id != target.id
    }

    static func workspaceRowDrop(
        source: Workspace,
        target: Workspace,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in workspaces: [Workspace]
    ) -> WorkspaceRowDrop {
        guard workspaceRowAcceptsSource(source: source, target: target) else {
            return .rejected
        }

        let siblings = workspaces.filter {
            $0.folderID == target.folderID && $0.isPinned == target.isPinned
        }
        guard let targetIndex = siblings.firstIndex(where: { $0.id == target.id }) else {
            return .rejected
        }

        if let sourceIndex = siblings.firstIndex(where: { $0.id == source.id }) {
            // A neighbouring row is one large swap target. Requiring the pointer to land in the
            // "moving" half makes a common one-slot reorder needlessly precise.
            if sourceIndex == targetIndex + 1 {
                return .insert(before: target.id, edge: .top)
            }
            if targetIndex == sourceIndex + 1 {
                return .insert(before: siblings.dropFirst(targetIndex + 1).first?.id, edge: .bottom)
            }
        }

        let edge: InsertionEdge = locationY <= renderedHeight / 2 ? .top : .bottom
        let before = edge == .top ? target.id : siblings.dropFirst(targetIndex + 1).first?.id

        // A drop that would land source right back where it already sits shows no line and
        // moves nothing, rather than flickering an insertion indicator for a no-op reorder.
        if let sourceIndex = siblings.firstIndex(where: { $0.id == source.id }) {
            let sourceSuccessorID = siblings.dropFirst(sourceIndex + 1).first?.id
            if before == source.id || before == sourceSuccessorID {
                return .rejected
            }
        }

        return .insert(before: before, edge: edge)
    }

    static func containerAcceptsWorkspace(source: Workspace, folderID: WorkspaceFolderID?) -> Bool {
        source.folderID != folderID
    }

    static func containerAcceptsDragItem(
        _ item: SidebarDragItem?,
        folderID: WorkspaceFolderID?,
        workspaces: [Workspace],
        folders: [WorkspaceFolder]
    ) -> Bool {
        switch item {
        case .workspace(let sourceID):
            guard let source = workspaces.first(where: { $0.id == sourceID }) else { return false }
            return containerAcceptsWorkspace(source: source, folderID: folderID)
        case .folder(let sourceID):
            guard let folderID else { return false }
            return sourceID != folderID && folders.contains(where: { $0.id == sourceID })
        case nil:
            return false
        }
    }

    /// What a workspace row should draw for the drag currently over it.
    static func workspaceRowFeedback(
        _ item: SidebarDragItem?,
        target: Workspace,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in workspaces: [Workspace]
    ) -> SidebarDropFeedback {
        guard case .workspace(let sourceID) = item,
              let source = workspaces.first(where: { $0.id == sourceID }) else {
            return .none
        }
        switch workspaceRowDrop(
            source: source,
            target: target,
            locationY: locationY,
            renderedHeight: renderedHeight,
            in: workspaces
        ) {
        case .rejected:
            return .none
        case .insert(_, let edge):
            return .insertion(edge)
        }
    }

    /// What a folder row should draw for the drag currently over it. A workspace lands inside the
    /// folder, so the row highlights. Another folder lands beside it, so the row shows an edge.
    static func folderRowFeedback(
        _ item: SidebarDragItem?,
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        workspaces: [Workspace],
        folders: [WorkspaceFolder]
    ) -> SidebarDropFeedback {
        switch item {
        case .workspace(let sourceID):
            guard let source = workspaces.first(where: { $0.id == sourceID }),
                  containerAcceptsWorkspace(source: source, folderID: folderID) else {
                return .none
            }
            return .highlight
        case .folder(let sourceID):
            switch folderRowDrop(
                sourceID: sourceID,
                folderID: folderID,
                nextFolderID: nextFolderID,
                locationY: locationY,
                renderedHeight: renderedHeight,
                in: folders
            ) {
            case .rejected:
                return .none
            case .insert(_, let edge):
                return .insertion(edge)
            }
        case nil:
            return .none
        }
    }

    enum FolderRowDrop: Equatable {
        case rejected
        case insert(before: WorkspaceFolderID?, edge: InsertionEdge)
    }

    /// Adjacent folders use the entire neighbouring row as a swap target. Non-adjacent folders
    /// still use the upper and lower halves to choose an insertion boundary.
    static func folderRowDrop(
        sourceID: WorkspaceFolderID,
        folderID: WorkspaceFolderID,
        nextFolderID: WorkspaceFolderID?,
        locationY: CGFloat,
        renderedHeight: CGFloat,
        in folders: [WorkspaceFolder]
    ) -> FolderRowDrop {
        guard sourceID != folderID else {
            return .rejected
        }

        guard let sourceIndex = folders.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            return .rejected
        }

        if sourceIndex == targetIndex + 1 {
            return .insert(before: folderID, edge: .top)
        }
        if targetIndex == sourceIndex + 1 {
            return .insert(before: nextFolderID, edge: .bottom)
        }

        let edge: InsertionEdge = locationY <= renderedHeight / 2 ? .top : .bottom
        let before = folderTarget(
            folderID: folderID,
            nextFolderID: nextFolderID,
            locationY: locationY,
            renderedHeight: renderedHeight
        )

        let sourceSuccessorID = folders.dropFirst(sourceIndex + 1).first?.id
        if before == sourceID || before == sourceSuccessorID {
            return .rejected
        }

        return .insert(before: before, edge: edge)
    }
}
