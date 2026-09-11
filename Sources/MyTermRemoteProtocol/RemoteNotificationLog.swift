import Foundation
import MyTermCore

/// One thing that happened, as a device remembers it.
///
/// The Mac keeps one entry per tab and drops it once the user reaches the tab. A device keeps
/// every entry it has seen, so the person can scroll back through what happened, and it keeps its
/// own read mark, because reading on the phone is not reaching the tab on the Mac.
public struct RemoteNotificationLogEntry: Codable, Equatable, Sendable, Identifiable {
    /// The tab and the moment together. A tab that needs the user again is a new entry, so a read
    /// one can never swallow the next thing the same tab has to say.
    public struct ID: Hashable, Codable, Sendable {
        public var tabID: String
        public var date: Date

        public init(tabID: String, date: Date) {
            self.tabID = tabID
            self.date = date
        }
    }

    public var tabID: String
    public var workspaceID: String
    public var workspaceTitle: String
    public var tabTitle: String
    public var activity: AgentActivity
    public var date: Date
    public var isRead: Bool

    public var id: ID { ID(tabID: tabID, date: date) }

    public init(_ notification: RemoteNotification, isRead: Bool = false) {
        tabID = notification.tabID
        workspaceID = notification.workspaceID
        workspaceTitle = notification.workspaceTitle
        tabTitle = notification.tabTitle
        activity = notification.activity
        date = notification.date
        self.isRead = isRead
    }
}

/// What has happened, newest first, and which of it the person has looked at.
///
/// Pure: every rule about what a host snapshot does to the list lives here, where it is tested
/// without a socket or a screen. `RemoteNotificationLogStore` is the shell that persists it.
public struct RemoteNotificationLog: Codable, Equatable, Sendable {
    /// Enough to scroll back through a busy day, small enough that the list stays a list.
    public static let capacity = 200

    /// Newest first, which is the order the person reads through.
    public private(set) var entries: [RemoteNotificationLogEntry]

    public init(entries: [RemoteNotificationLogEntry] = []) {
        self.entries = Self.trimmed(entries)
    }

    public var unreadCount: Int { entries.filter { !$0.isRead }.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Folds the Mac's current backlog into what the device already knows.
    ///
    /// An entry the Mac lists and the device has not seen is new, and unread. One the device already
    /// has keeps its read mark and takes the Mac's current names, so a renamed tab renames the row.
    /// One the device has that the Mac no longer lists was reached on the Mac, or the agent moved
    /// on, so it is read: either way the person has nothing left to do about it.
    public mutating func merge(_ snapshot: RemoteNotifications) {
        let listed = Set(snapshot.entries.map { RemoteNotificationLogEntry.ID(tabID: $0.tabID, date: $0.date) })
        var merged = entries
        for index in merged.indices where !listed.contains(merged[index].id) {
            merged[index].isRead = true
        }
        for notification in snapshot.entries {
            let id = RemoteNotificationLogEntry.ID(tabID: notification.tabID, date: notification.date)
            if let index = merged.firstIndex(where: { $0.id == id }) {
                let isRead = merged[index].isRead
                merged[index] = RemoteNotificationLogEntry(notification, isRead: isRead)
            } else {
                merged.append(RemoteNotificationLogEntry(notification))
            }
        }
        entries = Self.trimmed(merged)
    }

    public mutating func markRead(_ id: RemoteNotificationLogEntry.ID, isRead: Bool = true) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isRead = isRead
    }

    public mutating func markAllRead() {
        for index in entries.indices {
            entries[index].isRead = true
        }
    }

    /// Newest first, and no more than the log keeps. Two entries in the same instant keep the
    /// order they arrived in, which is the order the Mac listed them.
    private static func trimmed(_ entries: [RemoteNotificationLogEntry]) -> [RemoteNotificationLogEntry] {
        let sorted = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date {
                return lhs.element.date > rhs.element.date
            }
            return lhs.offset < rhs.offset
        }
        return Array(sorted.map(\.element).prefix(capacity))
    }
}

/// Keeps the log between launches, and publishes it for SwiftUI.
@MainActor
@Observable
public final class RemoteNotificationLogStore {
    public private(set) var log: RemoteNotificationLog

    private let defaults: UserDefaults
    private let defaultsKey: String

    public init(defaults: UserDefaults = .standard, defaultsKey: String = "remote.notificationLog") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        log = Self.load(from: defaults, key: defaultsKey)
    }

    public func merge(_ snapshot: RemoteNotifications) {
        log.merge(snapshot)
        persist()
    }

    public func markRead(_ id: RemoteNotificationLogEntry.ID, isRead: Bool = true) {
        log.markRead(id, isRead: isRead)
        persist()
    }

    public func markAllRead() {
        log.markAllRead()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(log) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> RemoteNotificationLog {
        guard let data = defaults.data(forKey: key),
              let log = try? JSONDecoder().decode(RemoteNotificationLog.self, from: data)
        else {
            return RemoteNotificationLog()
        }
        return log
    }
}
