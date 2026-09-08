import Foundation
import MyTermRemoteProtocol
import Network

/// Carries the session identifier into an output tap that was installed before the identifier existed.
@MainActor
private final class AttachedSessionRoute {
    var session: UUID?
}

/// One connected device.
///
/// The pre-shared key proves the device holds the pairing token, so the handshake completing is the
/// authentication. `hello` carries only the protocol version and a name to show the user.
@MainActor
final class RemoteHostConnection {
    /// Output queued beyond this is discarded in favour of a fresh screen. A device that cannot keep
    /// up with a build wants the current screen, not every frame of one it already missed.
    static let maximumPendingBytes = 512 * 1024

    private let connection: NWConnection
    private let hostName: String
    /// Read each time it matters, so flipping the switch on the Mac applies to a device that is
    /// already connected, not only to the next one.
    private let allowsInput: () -> Bool
    private weak var dataSource: (any RemoteHostDataSource)?

    private var decoder = RemoteFrameDecoder()
    private var didGreet = false
    /// The attachment handle for each session this device is watching.
    private var attachedSessions: [UUID: UUID] = [:]
    /// One watcher per followed conversation. Held here so they die with the connection: a watcher
    /// that outlived its device would keep reading a file for nobody.
    private var agentWatchers: [String: AgentTranscriptWatcher] = [:]
    /// What was last sent to the device for each followed tab, so the same prompt is not pushed
    /// again on every poll.
    private var agentPromptOptions: [String: [RemoteAgentPromptOption]] = [:]
    private var pendingBytes = 0
    private var sessionsNeedingResync = Set<UUID>()

    private(set) var deviceName: String?
    var onStateChanged: (() -> Void)?
    var onClosed: (() -> Void)?
    /// Called after a device-requested change lands, so every device sees it without waiting for
    /// the next poll.
    var onTreeMutated: (() -> Void)?

    init(
        connection: NWConnection,
        hostName: String,
        allowsInput: @escaping () -> Bool,
        dataSource: (any RemoteHostDataSource)?
    ) {
        self.connection = connection
        self.hostName = hostName
        self.allowsInput = allowsInput
        self.dataSource = dataSource
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed, .cancelled:
                    self?.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        // Before the guard: a watcher holds no data source, so it must be stopped even when there
        // is none left to detach from.
        for watcher in agentWatchers.values {
            watcher.stop()
        }
        agentWatchers.removeAll()
        guard let dataSource else {
            finishClosing()
            return
        }
        for attachment in attachedSessions.values {
            dataSource.detach(attachment: attachment)
        }
        attachedSessions.removeAll()
        finishClosing()
    }

    /// Tells the device what this Mac permits now. Sent on arrival, and again whenever the answer
    /// changes, because the device hides its controls by what it was last told.
    func sendWelcome() {
        guard didGreet else { return }
        sendControl(.welcome(RemoteWelcome(hostName: hostName, allowsInput: allowsInput())))
    }

    private func finishClosing() {
        connection.cancel()
        let closed = onClosed
        onClosed = nil
        closed?()
    }

    func send(tree: RemoteTree) {
        sendControl(.tree(tree))
    }

    func send(agentActivity: RemoteAgentActivity) {
        sendControl(.agentActivity(agentActivity))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let content, !content.isEmpty {
                    self.consume(content)
                }
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        decoder.append(data)
        while true {
            let frame: RemoteFrame?
            do {
                frame = try decoder.nextFrame()
            } catch {
                sendControl(.error(RemoteError(code: "frame", message: "\(error)")))
                close()
                return
            }
            guard let frame else { return }
            handle(frame)
        }
    }

    private func handle(_ frame: RemoteFrame) {
        switch frame.kind {
        case .control:
            guard let message = try? RemoteControlCodec.decode(frame) else {
                sendControl(.error(RemoteError(code: "decode", message: "unreadable control message")))
                return
            }
            handle(message)
        case .input:
            guard allowsInput(),
                  let (session, bytes) = RemoteSessionPayload.decode(frame.payload),
                  attachedSessions[session] != nil else { return }
            dataSource?.sendInput(session: session, bytes: bytes[...])
        case .output:
            // Output only ever flows towards the device.
            break
        }
    }

    private func handle(_ message: RemoteControlMessage) {
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == RemoteProtocol.version else {
                sendControl(.error(RemoteError(
                    code: "version",
                    message: "this Mac speaks protocol \(RemoteProtocol.version)"
                )))
                close()
                return
            }
            deviceName = hello.deviceName
            didGreet = true
            sendWelcome()
            if let tree = dataSource?.remoteTree() {
                sendControl(.tree(tree))
            }
            onStateChanged?()

        case .attach(let attach):
            guard didGreet else { return }
            // The session identifier only exists once attach returns, and the tap needs it to label
            // the frames it sends. Everything here is main-actor isolated, so no output can arrive
            // before the box is filled.
            let route = AttachedSessionRoute()
            guard let attachment = dataSource?.attach(
                tabID: attach.tabID,
                output: { [weak self] bytes in
                    guard let session = route.session else { return }
                    self?.forward(bytes: bytes, session: session)
                }
            ) else {
                sendControl(.error(RemoteError(code: "attach", message: "no such terminal tab")))
                return
            }
            route.session = attachment.session
            // Attaching twice to one session keeps only the newest attachment, so a device that
            // re-attaches after a hiccup does not receive every byte twice.
            if let previous = attachedSessions.updateValue(attachment.id, forKey: attachment.session) {
                dataSource?.detach(attachment: previous)
            }
            sendControl(.attached(RemoteAttached(
                tabID: attach.tabID,
                session: attachment.session,
                columns: attachment.columns,
                rows: attachment.rows
            )))
            sendOutput(session: attachment.session, bytes: attachment.snapshot)
            onStateChanged?()

        case .detach(let session):
            guard let attachment = attachedSessions.removeValue(forKey: session) else { return }
            dataSource?.detach(attachment: attachment)
            onStateChanged?()

        case .attachAgent(let request):
            guard didGreet else { return }
            guard let session = dataSource?.agentSession(tabID: request.tabID) else {
                sendControl(.error(RemoteError(
                    code: "attachAgent",
                    message: "has no agent conversation to follow"
                )))
                return
            }
            // Following twice keeps only the newest, so a device that re-asks after a hiccup does
            // not end up with two watchers sending it the same entries.
            agentWatchers.removeValue(forKey: request.tabID)?.stop()
            let watcher = AgentTranscriptWatcher(
                tabID: request.tabID,
                agent: session.agent,
                sessionID: session.sessionID,
                onConversation: { [weak self] conversation in
                    self?.sendControl(.agentConversation(conversation))
                },
                onEntries: { [weak self] entries in
                    self?.sendControl(.agentEntries(entries))
                }
            )
            agentWatchers[request.tabID] = watcher
            watcher.start()

        case .detachAgent(let request):
            agentWatchers.removeValue(forKey: request.tabID)?.stop()
            agentPromptOptions.removeValue(forKey: request.tabID)

        case .agentReply(let request):
            // Typing into an agent reaches as far as typing into its terminal does, so it is gated
            // on the same answer the user gave about whether their devices may type at all.
            guard didGreet, allowsInput() else {
                sendControl(.error(RemoteError(code: "denied", message: "is not taking input from devices")))
                return
            }
            guard request.isTypable else {
                sendControl(.error(RemoteError(code: "agentReply", message: "would not accept that text")))
                return
            }
            // The Return is added here, not sent by the device. A device says words; it does not
            // decide when a line is submitted, and it cannot smuggle control bytes through this.
            let bytes = Array(request.text.utf8) + Array("\r".utf8)
            if dataSource?.sendInput(tabID: request.tabID, bytes: bytes[...]) != true {
                sendControl(.error(RemoteError(code: "agentReply", message: "has no terminal for that tab")))
            }

        case .agentAnswer(let request):
            guard didGreet, allowsInput() else {
                sendControl(.error(RemoteError(code: "denied", message: "is not taking input from devices")))
                return
            }
            answer(request)

        case .renameTab(let request):
            applyMutation("rename tab") { $0.renameTab(tabID: request.tabID, title: request.title) }

        case .closeTab(let request):
            applyMutation("close tab") { $0.closeTab(tabID: request.tabID) }

        case .renameWorkspace(let request):
            applyMutation("rename workspace") {
                $0.renameWorkspace(workspaceID: request.workspaceID, title: request.title)
            }

        case .createWorkspace(let request):
            applyMutation("create workspace") {
                $0.createWorkspace(title: request.title, folderID: request.folderID)
            }

        case .deleteWorkspace(let request):
            applyMutation("delete workspace") { $0.deleteWorkspace(workspaceID: request.workspaceID) }

        case .createTerminalTab(let request):
            applyMutation("create terminal tab") {
                $0.createTerminalTab(workspaceID: request.workspaceID)
            }

        case .welcome, .tree, .attached, .resync, .agentActivity,
             .agentConversation, .agentEntries, .agentPrompt, .error:
            // The host never receives these.
            break
        }
    }

    /// Answers a permission prompt, or refuses to.
    ///
    /// The screen is read again here rather than trusted from when it was offered. A menu's
    /// composition varies between runs, so a number that meant "No" a moment ago can mean "Yes, and
    /// switch to auto mode" now. Only a label still sitting on its own number is answered.
    private func answer(_ request: RemoteAgentAnswer) {
        if request.isDeny {
            // Escape needs no menu read. It is what the prompt's own footer offers and it means the
            // same thing wherever the options sit, which makes it the one safe blind answer.
            if dataSource?.sendInput(
                tabID: request.tabID,
                bytes: AgentPermissionMenu.denyKeystrokes[...]
            ) != true {
                sendControl(.error(RemoteError(code: "agentAnswer", message: "has no terminal for that tab")))
            }
            return
        }

        guard let option = request.option,
              let rows = dataSource?.visibleRows(tabID: request.tabID),
              let keystrokes = AgentPermissionMenu.keystrokes(forAnswering: option, rows: rows) else {
            // Saying so matters: the person pressed a button and nothing happened, and the reason
            // is that what they were looking at is no longer what the Mac is showing.
            sendControl(.error(RemoteError(
                code: "agentAnswer",
                message: "is showing something else now, so that answer was not sent"
            )))
            pushPrompt(tabID: request.tabID, force: true)
            return
        }
        _ = dataSource?.sendInput(tabID: request.tabID, bytes: keystrokes[...])
        pushPrompt(tabID: request.tabID, force: true)
    }

    /// Tells the device what the tab's screen is offering, when that has changed.
    func pushPrompt(tabID: String, force: Bool = false) {
        guard didGreet, agentWatchers[tabID] != nil else { return }
        let options = dataSource.map { AgentPermissionMenu.offerableOptions(rows: $0.visibleRows(tabID: tabID) ?? []) } ?? []
        guard force || options != agentPromptOptions[tabID] else { return }
        agentPromptOptions[tabID] = options
        sendControl(.agentPrompt(RemoteAgentPrompt(tabID: tabID, options: options)))
    }

    /// Every tab whose conversation this connection is following.
    var followedAgentTabs: [String] { Array(agentWatchers.keys) }

    /// Runs one change a device asked for, and refuses it outright unless this Mac accepts input.
    ///
    /// `allowsInput` is the user's single answer to whether their devices may act on this Mac.
    /// Changing workspaces reaches further than typing does, so nothing here may be allowed while
    /// typing is not. The check lives here rather than in the device's interface, because a device
    /// decides what to show and this Mac decides what to permit.
    private func applyMutation(
        _ intent: String,
        _ change: (any RemoteHostDataSource) -> Bool
    ) {
        guard didGreet else { return }
        guard allowsInput() else {
            sendControl(.error(RemoteError(
                code: "denied",
                message: "this Mac does not accept changes from devices"
            )))
            return
        }
        guard let dataSource else { return }
        guard change(dataSource) else {
            sendControl(.error(RemoteError(code: "mutate", message: "could not \(intent)")))
            return
        }
        // The tree is otherwise polled once a second. A device that just closed a tab must not spend
        // that second still showing it, so the change pushes a fresh tree rather than waiting.
        onTreeMutated?()
    }

    private func forward(bytes: ArraySlice<UInt8>, session: UUID) {
        guard pendingBytes < Self.maximumPendingBytes else {
            // Already behind. Stop adding to the backlog and repair with a whole screen instead.
            sessionsNeedingResync.insert(session)
            return
        }
        sendOutput(session: session, bytes: Array(bytes))
    }

    private func sendOutput(session: UUID, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let frame = RemoteFrame(
            kind: .output,
            payload: RemoteSessionPayload.encode(session: session, bytes: bytes)
        )
        transmit(RemoteFrameCodec.encode(frame))
    }

    private func sendControl(_ message: RemoteControlMessage) {
        guard let frame = try? RemoteControlCodec.encode(message) else { return }
        transmit(RemoteFrameCodec.encode(frame))
    }

    private func transmit(_ bytes: [UInt8]) {
        pendingBytes += bytes.count
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingBytes = max(0, self.pendingBytes - bytes.count)
                self.drainResyncsIfCaughtUp()
            }
        })
    }

    private func drainResyncsIfCaughtUp() {
        guard pendingBytes == 0, !sessionsNeedingResync.isEmpty else { return }
        let sessions = sessionsNeedingResync
        sessionsNeedingResync.removeAll()
        for session in sessions {
            guard let attachment = dataSource?.snapshot(session: session) else { continue }
            sendControl(.resync(session: session))
            sendOutput(session: session, bytes: attachment.snapshot)
        }
    }
}
