import Foundation
import MyTermRemoteProtocol
import Network
import Observation

public struct RemoteHostDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum RemoteHostState: Equatable, Sendable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)
}

/// Accepts device connections and advertises this Mac on the local network.
///
/// Nothing here runs until the user turns the feature on. A listener that exists by default is a
/// remote shell that exists by default.
@MainActor
@Observable
public final class RemoteHostService {
    public private(set) var state: RemoteHostState = .stopped {
        didSet { onStateChanged?(state) }
    }
    /// Fires on every state change, for the app to start or stop what depends on the listener.
    public var onStateChanged: ((RemoteHostState) -> Void)?

    /// The port the listener is on, or nil while it is not listening.
    public var listeningPort: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }
    public private(set) var connectedDevices: [RemoteHostDevice] = []

    /// The pairing token. A device proves it holds this by completing the TLS handshake.
    public private(set) var token: String

    /// Whether devices may type and change workspaces. Applies at once to every device already
    /// connected: each is told again what it may do, and its controls follow.
    public var allowsInput: Bool {
        didSet {
            guard allowsInput != oldValue else { return }
            for connection in connections.values {
                connection.sendWelcome()
            }
        }
    }

    /// The port to listen on. When something else holds it, the listener falls back to any free
    /// port and says so through `state`, so pairing still works and the address shown is right.
    public var preferredPort: UInt16 = RemoteProtocol.defaultPort

    /// What devices see this Mac as, and the name it advertises on the local network.
    public let hostName: String
    private let queue = DispatchQueue(label: "com.gordonbeeming.myterm.remote-host")
    private var listener: NWListener?
    /// The port the current listener was asked for, so a failure knows whether a fallback is left.
    private var attemptedPort: NWEndpoint.Port?
    private var connections: [UUID: RemoteHostConnection] = [:]
    private weak var dataSource: (any RemoteHostDataSource)?
    private var treeWatch: Timer?
    private var lastBroadcastRevision: Int?

    public init(
        hostName: String,
        token: String,
        allowsInput: Bool = true,
        dataSource: (any RemoteHostDataSource)? = nil
    ) {
        self.hostName = hostName
        self.token = token
        self.allowsInput = allowsInput
        self.dataSource = dataSource
    }

    public func connect(dataSource: (any RemoteHostDataSource)?) {
        self.dataSource = dataSource
    }

    public func rotateToken() {
        token = RemoteTransportSecurity.makeToken()
        if case .listening = state {
            stop()
            start()
        }
    }

    public func start() {
        start(on: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
    }

    private func start(on port: NWEndpoint.Port) {
        guard listener == nil else { return }
        state = .starting
        attemptedPort = port

        do {
            let parameters = RemoteTransportSecurity.parameters(token: token)
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: hostName,
                type: RemoteProtocol.bonjourServiceType
            )
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor [weak self] in
                    self?.handle(listenerState: listenerState)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        stopWatchingTree()
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        connectedDevices = []
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    /// Pushes the current tree to every connected device.
    public func broadcastTree() {
        guard let tree = dataSource?.remoteTree() else { return }
        lastBroadcastRevision = tree.revision
        for connection in connections.values {
            connection.send(tree: tree)
        }
    }

    /// Sends the tree only when its revision changed.
    ///
    /// The app mutates its workspaces through many paths, and threading a notification through all
    /// of them would touch far more of the app than this feature should. Comparing a cheap revision
    /// keeps the coupling at one call. Deltas and a push replace this once the tree grows.
    private func broadcastTreeIfChanged() {
        guard !connections.isEmpty, let tree = dataSource?.remoteTree() else { return }
        guard tree.revision != lastBroadcastRevision else { return }
        lastBroadcastRevision = tree.revision
        for connection in connections.values {
            connection.send(tree: tree)
        }
    }

    private func startWatchingTree() {
        guard treeWatch == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastTreeIfChanged()
                self?.pushAgentPrompts()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        treeWatch = timer
    }

    /// Tells each device what the tabs it is following are asking, when that has changed.
    ///
    /// Polled with the tree rather than pushed, because a permission prompt is drawn on the screen
    /// and nothing in the app announces it. A device learns about it the same second the Mac does.
    private func pushAgentPrompts() {
        for connection in connections.values {
            for tabID in connection.followedAgentTabs {
                connection.pushPrompt(tabID: tabID)
            }
        }
    }

    private func stopWatchingTree() {
        treeWatch?.invalidate()
        treeWatch = nil
        lastBroadcastRevision = nil
    }

    public func broadcast(agentActivity: RemoteAgentActivity) {
        for connection in connections.values {
            connection.send(agentActivity: agentActivity)
        }
    }

    private func handle(listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            state = .listening(port: listener?.port?.rawValue ?? 0)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The fixed port belongs to something else, so take any port rather than stay off.
            // The pairing code carries whatever port was won, so a device still finds this Mac.
            if case .posix(.EADDRINUSE) = error, attemptedPort != .any {
                start(on: .any)
                return
            }
            state = .failed(error.localizedDescription)
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let identifier = UUID()
        let connection = RemoteHostConnection(
            connection: nwConnection,
            hostName: hostName,
            allowsInput: { [weak self] in self?.allowsInput ?? false },
            dataSource: dataSource
        )
        connection.onClosed = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: identifier)
                self?.refreshDevices()
                if self?.connections.isEmpty == true {
                    self?.stopWatchingTree()
                }
            }
        }
        connection.onStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        connection.onTreeMutated = { [weak self] in
            // Every device, not just the one that asked. Two iPads looking at the same workspace
            // must not disagree about whether a tab still exists.
            self?.broadcastTree()
        }
        connections[identifier] = connection
        connection.start(queue: queue)
        startWatchingTree()
    }

    private func refreshDevices() {
        connectedDevices = connections
            .compactMap { identifier, connection in
                connection.deviceName.map { RemoteHostDevice(id: identifier, name: $0) }
            }
            .sorted { $0.name < $1.name }
    }
}
