import Foundation
import MyTermCore
import MyTermRemoteProtocol

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
    /// tab, or an agent renaming its own conversation, renames the row that points at it. So is the
    /// pane: a tab dragged into another pane is still the tab that is waiting. An entry whose tab is
    /// gone is dropped rather than shown as a row that leads nowhere.
    var agentNotificationItems: [AgentNotificationItem] {
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        return agentInbox.items.compactMap { entry in
            guard let workspace = workspacesByID[entry.workspaceID],
                  let tabGroupID = workspace.groupID(containing: entry.tabID),
                  let tab = workspace.tab(id: entry.tabID) else {
                return nil
            }
            return AgentNotificationItem(
                id: entry.tabID,
                workspaceID: entry.workspaceID,
                tabGroupID: tabGroupID,
                activity: entry.activity,
                date: entry.date,
                workspaceTitle: workspace.displayTitle,
                tabTitle: tab.customTitle ?? tab.automaticDisplayTitle
            )
        }
    }

    var agentNotificationCount: Int { agentNotificationItems.count }

    /// The backlog as a device receives it, for its Latest tab.
    func remoteNotifications() -> RemoteNotifications? {
        RemoteNotifications(entries: agentNotificationItems.map { item in
            RemoteNotification(
                tabID: item.id.description,
                workspaceID: item.workspaceID.description,
                workspaceTitle: item.workspaceTitle,
                tabTitle: item.tabTitle,
                activity: item.activity,
                date: item.date
            )
        })
    }

    /// Pushes the backlog to every connected device, so its Latest tab follows the bell.
    ///
    /// Reading on a device changes nothing here. Whether a tab read on the phone should lose its
    /// dot on the Mac is still an open question, so for now the Mac is the only place that reads.
    func broadcastAgentNotifications() {
        guard let notifications = remoteNotifications() else { return }
        remoteHost.broadcast(notifications: notifications)
    }

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
        broadcastAgentNotifications()
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
