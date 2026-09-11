import Foundation
import MyTermRemoteProtocol
import Observation

/// Owns the one `RemoteClient` for the app's lifetime and turns its delegate callbacks into state
/// SwiftUI can observe, or into per-attachment closures that a terminal screen installs only while
/// it is the thing showing that session's bytes.
@MainActor
@Observable
final class RemoteSessionStore {
    let client: RemoteClient
    private(set) var tree: RemoteTree?
    /// What agents did while the person was away, and what they have read of it. Not cleared with
    /// the tree: it is the device's own record, and leaving a Mac does not unmake what happened.
    let notifications = RemoteNotificationLogStore()
    /// The last request the Mac refused, for a passing banner. Cleared on its own.
    private(set) var refusal: RemoteError?
    /// Why the tab on screen could not be attached, when the Mac said so.
    private(set) var attachRefusal: String?
    /// The agent conversation the screen on show is following, if any.
    ///
    /// One at a time, like the terminal attachment: a device shows one tab, and holding conversations
    /// for tabs nobody is looking at would keep the Mac reading files for nothing.
    private(set) var conversation: RemoteAgentConversation?
    /// Set while a conversation has been asked for and nothing has come back. The file may not exist
    /// yet, which is normal for the first seconds of an agent session.
    private(set) var isLoadingConversation = false
    /// What the tab's screen is offering, when the agent has stopped to ask. Empty means there is
    /// nothing to answer, which is the ordinary case.
    private(set) var promptOptions: [RemoteAgentPromptOption] = []
    /// Set while an answer is in flight, so the buttons cannot be pressed twice.
    private(set) var isAnswering = false

    /// Set by whichever `TerminalScreen` is currently attached; cleared when it detaches.
    @ObservationIgnored
    private(set) var onAttach: ((RemoteAttached) -> Void)?
    @ObservationIgnored
    private(set) var onOutput: (([UInt8], UUID) -> Void)?
    @ObservationIgnored
    private(set) var onResync: ((UUID) -> Void)?

    /// The screen these callbacks belong to. A pushed screen installs its callbacks before the
    /// screen it replaced is torn down, so a departing screen must not clear its successor's.
    @ObservationIgnored
    private weak var attachmentOwner: AnyObject?
    @ObservationIgnored
    private var refusalTimer: Task<Void, Never>?

    init(deviceName: String) {
        client = RemoteClient(deviceName: deviceName)
        client.delegate = self
    }

    func claimAttachment(
        owner: AnyObject,
        onAttach: @escaping (RemoteAttached) -> Void,
        onOutput: @escaping ([UInt8], UUID) -> Void,
        onResync: @escaping (UUID) -> Void
    ) {
        attachmentOwner = owner
        attachRefusal = nil
        self.onAttach = onAttach
        self.onOutput = onOutput
        self.onResync = onResync
    }

    func releaseAttachment(owner: AnyObject) {
        guard attachmentOwner === owner else { return }
        attachmentOwner = nil
        attachRefusal = nil
        onAttach = nil
        onOutput = nil
        onResync = nil
    }

    /// Starts following a tab's agent conversation, dropping whatever was followed before.
    func followConversation(tabID: String) {
        if let current = conversation?.tabID, current != tabID {
            client.detachAgent(tabID: current)
        }
        conversation = nil
        isLoadingConversation = true
        client.attachAgent(tabID: tabID)
    }

    func stopFollowingConversation(tabID: String) {
        client.detachAgent(tabID: tabID)
        if conversation?.tabID == tabID {
            conversation = nil
        }
        isLoadingConversation = false
        promptOptions = []
        isAnswering = false
    }

    func reply(tabID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client.replyToAgent(tabID: tabID, text: trimmed)
    }

    /// Sends the whole option rather than its number. The Mac checks the label is still on that
    /// number before it types anything, so a menu that changed answers nothing at all.
    func answerPrompt(tabID: String, option: RemoteAgentPromptOption) {
        isAnswering = true
        client.answerAgentPrompt(tabID: tabID, option: option)
    }

    func denyPrompt(tabID: String) {
        isAnswering = true
        client.denyAgentPrompt(tabID: tabID)
    }

    /// Forgets the Mac's tree. For leaving a Mac, not for losing it: a dropped connection keeps the
    /// tree so the screen stays where the user left it while the device reconnects.
    func clearTree() {
        tree = nil
        conversation = nil
        isLoadingConversation = false
        promptOptions = []
        isAnswering = false
    }

    func dismissRefusal() {
        refusalTimer?.cancel()
        refusalTimer = nil
        refusal = nil
    }
}

extension RemoteSessionStore: RemoteClientDelegate {
    func remoteClient(_ client: RemoteClient, didReceive tree: RemoteTree) {
        self.tree = tree
    }

    func remoteClient(_ client: RemoteClient, didAttach attached: RemoteAttached) {
        attachRefusal = nil
        onAttach?(attached)
    }

    func remoteClient(_ client: RemoteClient, didReceiveOutput bytes: [UInt8], for session: UUID) {
        onOutput?(bytes, session)
    }

    func remoteClient(_ client: RemoteClient, shouldResync session: UUID) {
        onResync?(session)
    }

    func remoteClient(_ client: RemoteClient, didReceive activity: RemoteAgentActivity) {
        tree = tree?.applyingAttention(from: activity)
    }

    func remoteClient(_ client: RemoteClient, didReceive notifications: RemoteNotifications) {
        self.notifications.merge(notifications)
    }

    func remoteClient(_ client: RemoteClient, didReceive conversation: RemoteAgentConversation) {
        self.conversation = conversation
        isLoadingConversation = false
    }

    func remoteClient(_ client: RemoteClient, didReceive entries: RemoteAgentEntries) {
        // A late batch for a tab the user has left is not this screen's, and applying it would show
        // one conversation's entries under another's name.
        guard var current = conversation, current.tabID == entries.tabID else { return }
        var seen = Set(current.entries.map(\.id))
        for entry in entries.entries where !seen.contains(entry.id) {
            seen.insert(entry.id)
            current.entries.append(entry)
        }
        conversation = current
    }

    func remoteClient(_ client: RemoteClient, didReceive prompt: RemoteAgentPrompt) {
        guard conversation?.tabID == prompt.tabID else { return }
        promptOptions = prompt.options
        isAnswering = false
    }

    func remoteClient(_ client: RemoteClient, didRefuse error: RemoteError) {
        // An attach that failed belongs to the screen that asked. Everything else is a passing
        // notice: the tree the Mac sends next already shows what did and did not change.
        if error.code == "attach", attachmentOwner != nil {
            attachRefusal = error.message
            return
        }
        if error.code == "agentAnswer" || error.code == "agentReply" {
            // The banner says what happened. Freeing the buttons matters as much: a refused answer
            // that left them disabled would look like the Mac had stopped listening.
            isAnswering = false
        }
        if error.code == "attachAgent" {
            // The tab has no conversation to show. The screen falls back to the terminal rather
            // than saying so: there is nothing the person can do about it.
            isLoadingConversation = false
            return
        }
        refusal = error
        refusalTimer?.cancel()
        refusalTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refusal = nil
        }
    }
}

private extension RemoteTree {
    /// Patches one tab's agent state in place. The host sends this instead of a full tree resend,
    /// so the device's cook tracks the Mac's without the user reopening the tab list.
    func applyingAttention(from activity: RemoteAgentActivity) -> RemoteTree {
        var tree = self
        for workspaceIndex in tree.workspaces.indices {
            for tabIndex in tree.workspaces[workspaceIndex].tabs.indices
            where tree.workspaces[workspaceIndex].tabs[tabIndex].id == activity.tabID {
                tree.workspaces[workspaceIndex].tabs[tabIndex].agentActivity = activity.activity
                tree.workspaces[workspaceIndex].tabs[tabIndex].needsAttention = activity.needsAttention
            }
        }
        return tree
    }
}
