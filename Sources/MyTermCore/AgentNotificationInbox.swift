import Foundation

/// One agent waiting for the user, in a tab the user was not looking at.
///
/// The entry is identified by its tab, so a pane that finishes several turns keeps one row rather
/// than growing a log. The backlog answers "which tabs need me", and a tab needs the user once.
public struct AgentInboxEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: TabID
    public let workspaceID: WorkspaceID
    public let tabGroupID: TabGroupID
    public let activity: AgentActivity
    /// When the event that produced this entry arrived.
    public let date: Date

    public var tabID: TabID { id }

    public init(
        tabID: TabID,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        activity: AgentActivity,
        date: Date
    ) {
        id = tabID
        self.workspaceID = workspaceID
        self.tabGroupID = tabGroupID
        self.activity = activity
        self.date = date
    }
}

/// The backlog of agents that finished, or asked a question, while the user was somewhere else.
///
/// This is also what draws the indicator on a tab, so the dot and the list can never disagree.
/// Reaching the tab is what reads an entry, and a read entry is gone.
public struct AgentNotificationInbox: Equatable, Sendable {
    /// Newest first, which is the order the user works through.
    private var entries: [AgentInboxEntry] = []

    public init() {}

    public var items: [AgentInboxEntry] { entries }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func activity(forTab tabID: TabID) -> AgentActivity? {
        entries.first(where: { $0.id == tabID })?.activity
    }

    public func containsTab(in tabIDs: some Sequence<TabID>) -> Bool {
        guard !entries.isEmpty else { return false }
        return tabIDs.contains { activity(forTab: $0) != nil }
    }

    /// Files what an agent reported, or takes the tab's entry back out when the agent moves on.
    ///
    /// `isTabVisible` is the whole difference between a notification and a distraction: an agent
    /// that finishes in front of the user has already told them.
    @discardableResult
    public mutating func record(
        _ activity: AgentActivity,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        tabID: TabID,
        isTabVisible: Bool,
        date: Date = Date()
    ) -> Bool {
        switch activity {
        case .ready, .working, .exited:
            return remove(tabID: tabID)
        case .finished, .awaitingInput:
            guard !isTabVisible else { return remove(tabID: tabID) }
            // A question outranks a finished turn: it is the one the user has to act on.
            guard activity == .awaitingInput || self.activity(forTab: tabID) != .awaitingInput else {
                return false
            }
            remove(tabID: tabID)
            entries.insert(
                AgentInboxEntry(
                    tabID: tabID,
                    workspaceID: workspaceID,
                    tabGroupID: tabGroupID,
                    activity: activity,
                    date: date
                ),
                at: 0
            )
            return true
        }
    }

    /// The user reached the tab, so its entry is read.
    @discardableResult
    public mutating func markRead(tabID: TabID) -> Bool {
        remove(tabID: tabID)
    }

    public mutating func markRead(tabIDs: some Sequence<TabID>) {
        for tabID in tabIDs {
            remove(tabID: tabID)
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    @discardableResult
    private mutating func remove(tabID: TabID) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == tabID }
        return entries.count != before
    }
}
