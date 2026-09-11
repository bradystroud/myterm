import Foundation

/// One thing an agent did that the user should know about: it finished, or asked a question.
///
/// An entry is a tab and a moment. A tab that needs the user again gets a new entry rather than
/// a refreshed one, so what was read stays read and the next thing the tab has to say is new.
public struct AgentInboxEntry: Identifiable, Equatable, Hashable, Sendable, Codable {
    public struct ID: Hashable, Codable, Sendable {
        public let tabID: TabID
        public let date: Date

        public init(tabID: TabID, date: Date) {
            self.tabID = tabID
            self.date = date
        }
    }

    public let tabID: TabID
    public let workspaceID: WorkspaceID
    public let tabGroupID: TabGroupID
    public let activity: AgentActivity
    /// When the event that produced this entry arrived.
    public let date: Date
    /// Read means the user has reached the tab, or was already looking at it when the agent spoke.
    public var isRead: Bool

    public var id: ID { ID(tabID: tabID, date: date) }

    public init(
        tabID: TabID,
        workspaceID: WorkspaceID,
        tabGroupID: TabGroupID,
        activity: AgentActivity,
        date: Date,
        isRead: Bool = false
    ) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.tabGroupID = tabGroupID
        self.activity = activity
        self.date = date
        self.isRead = isRead
    }
}

/// What agents did while the user was somewhere else, and what they have caught up on.
///
/// The unread part is the backlog: it draws the indicator on a tab and fills the bell, so the dot
/// and the list can never disagree, and a tab is listed there once. Reading an entry keeps it, as
/// history, so a device that connects later still learns what happened and that it was dealt with.
public struct AgentNotificationInbox: Equatable, Sendable, Codable {
    /// Enough to scroll back through a busy day, small enough that the list stays a list. The same
    /// number a device keeps, so nothing the Mac sends is cut off on arrival.
    public static let capacity = 200

    /// Newest first, which is the order the user works through.
    private var entries: [AgentInboxEntry] = []

    public init() {}

    /// Everything, read and unread, newest first.
    public var history: [AgentInboxEntry] { entries }

    /// The backlog: what is still waiting for the user, newest first.
    public var items: [AgentInboxEntry] { entries.filter { !$0.isRead } }
    public var isEmpty: Bool { !entries.contains { !$0.isRead } }
    public var count: Int { items.count }

    public func activity(forTab tabID: TabID) -> AgentActivity? {
        unreadEntry(forTab: tabID)?.activity
    }

    public func containsTab(in tabIDs: some Sequence<TabID>) -> Bool {
        guard !isEmpty else { return false }
        return tabIDs.contains { activity(forTab: $0) != nil }
    }

    /// Files what an agent reported, or retires the tab's backlog entry when the agent moves on.
    ///
    /// `isTabVisible` is the whole difference between a notification and a distraction: an agent
    /// that finishes in front of the user has already told them, so its entry is filed read, and
    /// the history stays complete without the bell ringing. Returns whether anything changed.
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
            return markRead(tabID: tabID)
        case .finished, .awaitingInput:
            // A question outranks a finished turn: it is the one the user has to act on.
            guard activity == .awaitingInput || self.activity(forTab: tabID) != .awaitingInput else {
                return false
            }
            // A tab is in the backlog once. Superseding an unread entry drops it rather than
            // reading it: the user never saw it, and the new one says the same thing more recently.
            entries.removeAll { $0.tabID == tabID && !$0.isRead }
            insert(AgentInboxEntry(
                tabID: tabID,
                workspaceID: workspaceID,
                tabGroupID: tabGroupID,
                activity: activity,
                date: date,
                isRead: isTabVisible
            ))
            return true
        }
    }

    /// The user reached the tab, so whatever it had waiting is read. Returns whether anything was.
    @discardableResult
    public mutating func markRead(tabID: TabID) -> Bool {
        var changed = false
        for index in entries.indices where entries[index].tabID == tabID && !entries[index].isRead {
            entries[index].isRead = true
            changed = true
        }
        return changed
    }

    public mutating func markRead(tabIDs: some Sequence<TabID>) {
        for tabID in tabIDs {
            markRead(tabID: tabID)
        }
    }

    /// Reads the whole backlog at once. The history stays.
    public mutating func markAllRead() {
        for index in entries.indices {
            entries[index].isRead = true
        }
    }

    private func unreadEntry(forTab tabID: TabID) -> AgentInboxEntry? {
        entries.first { $0.tabID == tabID && !$0.isRead }
    }

    /// Keeps the list newest first, and no longer than it should be. When something has to go, the
    /// oldest read entry goes before anything unread: history can be forgotten, a question cannot.
    private mutating func insert(_ entry: AgentInboxEntry) {
        let index = entries.firstIndex { $0.date <= entry.date } ?? entries.endIndex
        entries.insert(entry, at: index)
        while entries.count > Self.capacity {
            if let oldestRead = entries.lastIndex(where: \.isRead) {
                entries.remove(at: oldestRead)
            } else {
                entries.removeLast()
            }
        }
    }
}
