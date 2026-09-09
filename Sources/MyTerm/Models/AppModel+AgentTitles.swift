import Foundation
import MyTermCore

/// Naming a tab after the agent conversation running in it.
///
/// Claude Code writes its session name to the terminal title, and writes it again when `/rename`
/// changes the name, so the title is the only channel a running conversation has for saying what it
/// is called. A shell writes the terminal title as well, which is why a pane is named this way only
/// while an agent has reported itself in it.
extension AppModel {
    /// Remembers which panes hold an agent, so a shell's title is never taken for a conversation.
    func recordAgentPresence(
        _ report: AgentActivityReport,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) {
        switch report.activity {
        case .ready, .working, .finished, .awaitingInput:
            liveAgentTabs[tabID] = report.agent
        case .exited:
            // Only the agent that named the tab gives the name back, so a second agent in the same
            // pane cannot take the first one's name off it.
            guard liveAgentTabs[tabID] == report.agent else { return }
            liveAgentTabs.removeValue(forKey: tabID)
            updateAgentTitle(nil, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
        }
    }

    func recordAgentTitle(
        _ title: String,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        sessionID: TerminalSessionID
    ) {
        guard liveAgentTabs[tabID] != nil,
              let name = AgentSessionTitle.sanitized(title),
              let terminal = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)?
                  .terminalSession, terminal.id == sessionID,
              (try? store.resolvedSettings(for: workspaceID))?.namesTabsFromAgentSessions == true else {
            return
        }
        updateAgentTitle(name, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
    }

    /// Drops the conversation name of a pane that has nothing running in it.
    func forgetAgentTitle(
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) {
        updateAgentTitle(nil, workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)
    }

    func forgetAgentPresence(forTab tabID: TabID) {
        liveAgentTabs.removeValue(forKey: tabID)
    }

    /// Puts the tabs of a workspace back to their plain labels.
    ///
    /// Turning the setting off is an answer about what tabs should say, so it takes effect on the
    /// tabs that are already named rather than on the next conversation only.
    func clearAgentTitles(in workspace: Workspace) {
        for group in workspace.orderedGroups {
            for tab in group.tabs where tab.terminalSession?.agentTitle != nil {
                try? store.updateTerminalAgentTitle(
                    workspaceID: workspace.id,
                    tabGroupID: group.id,
                    tabID: tab.id,
                    agentTitle: nil
                )
            }
        }
    }

    private func updateAgentTitle(
        _ title: String?,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID
    ) {
        // An agent writes the title several times a conversation. Writing only real changes keeps
        // that off the disk.
        guard let terminal = tab(workspaceID: workspaceID, tabGroupID: tabGroupID, tabID: tabID)?
            .terminalSession, terminal.agentTitle != title else { return }
        perform {
            try store.updateTerminalAgentTitle(
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                tabID: tabID,
                agentTitle: title
            )
        }
    }
}
