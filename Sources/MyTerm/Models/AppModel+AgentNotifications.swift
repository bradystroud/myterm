import Foundation
import MyTermCore

/// The backlog of agents waiting for the user, behind the bell in the toolbar.
///
/// `recordAgentActivity` files entries and `markAsRead` clears them, so the bell, the cook, and the
/// banner all answer to the same hook event. Reaching the tab is what reads an entry, whichever way
/// the user gets there.
extension AppModel {
    func agentActivity(forTab tabID: TabID) -> AgentActivity? {
        agentInbox.activity(forTab: tabID)
    }

    func needsAgentAttention(workspaceID: WorkspaceID) -> Bool {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            return false
        }
        return agentInbox.containsTab(in: workspace.allTabs.map(\.id))
    }

    /// The backlog as the popover shows it, newest first.
    ///
    /// Titles are resolved on every read rather than copied when the entry is filed, so renaming a
    /// tab, or an agent renaming its own conversation, renames the row that points at it. An entry
    /// whose tab is gone is dropped rather than shown as a row that leads nowhere.
    var agentNotificationItems: [AgentNotificationItem] {
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        return agentInbox.items.compactMap { entry in
            guard let workspace = workspacesByID[entry.workspaceID],
                  let tab = workspace.orderedGroups
                      .first(where: { $0.id == entry.tabGroupID })?
                      .tabs.first(where: { $0.id == entry.tabID }) else {
                return nil
            }
            return AgentNotificationItem(
                id: entry.tabID,
                workspaceID: entry.workspaceID,
                tabGroupID: entry.tabGroupID,
                activity: entry.activity,
                date: entry.date,
                workspaceTitle: workspace.displayTitle,
                tabTitle: tab.customTitle ?? tab.automaticDisplayTitle
            )
        }
    }

    var agentNotificationCount: Int { agentNotificationItems.count }

    /// Goes to the tab the entry points at. Arriving is what reads it.
    func openAgentNotification(_ item: AgentNotificationItem) {
        if store.selectedWorkspaceID != item.workspaceID {
            selectWorkspace(item.workspaceID)
        }
        selectTab(item.id, in: item.tabGroupID)
    }

    /// Clearing the list reads every tab in it, so the cooks go quiet with the bell.
    func clearAgentNotifications() {
        for entry in agentInbox.items {
            markAsRead(tabID: entry.tabID)
        }
        agentInbox.removeAll()
    }
}

/// One backlog row, with the names it shows resolved from the live workspace.
struct AgentNotificationItem: Identifiable, Equatable {
    let id: TabID
    let workspaceID: WorkspaceID
    let tabGroupID: TabGroupID
    let activity: AgentActivity
    let date: Date
    let workspaceTitle: String
    let tabTitle: String
}
