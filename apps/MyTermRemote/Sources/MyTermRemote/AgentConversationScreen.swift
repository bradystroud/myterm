import MyTermRemoteProtocol
import SwiftUI

/// A tab whose agent is talking, shown as the conversation it is having.
///
/// A phone cannot usefully show a hundred-column terminal grid. It can show a conversation, and the
/// agent already keeps one: the Mac reads the agent's own record and sends it as messages, so
/// nothing here parses a screen.
///
/// The raw terminal stays one tap away. Anything this cannot express — a menu, a progress display,
/// a tool with a shape nobody anticipated — is still reachable, and that escape is what makes it
/// safe to show a simplified view by default.
struct AgentConversationScreen: View {
    let tab: RemoteTab
    let store: RemoteSessionStore

    @State private var isShowingTerminal = false

    var body: some View {
        Group {
            if isShowingTerminal {
                TerminalScreen(tab: tab, store: store)
            } else {
                conversation
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isShowingTerminal ? "Conversation" : "Terminal",
                       systemImage: isShowingTerminal ? "bubble.left.and.bubble.right" : "terminal") {
                    isShowingTerminal.toggle()
                }
                .accessibilityIdentifier("agent.toggleTerminal")
            }
        }
        .onAppear { store.followConversation(tabID: tab.id) }
        .onDisappear { store.stopFollowingConversation(tabID: tab.id) }
    }

    @ViewBuilder
    private var conversation: some View {
        if let conversation = store.conversation, conversation.tabID == tab.id {
            entries(of: conversation)
                .navigationTitle(conversation.title ?? tab.title)
                .navigationBarTitleDisplayMode(.inline)
        } else if store.isLoadingConversation {
            // A session that has just started has not written its record yet, so this is a normal
            // few seconds rather than a failure.
            ProgressView("Reading the conversation…")
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "No Conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("This tab is not running an agent MyTerm can read. Open the terminal instead.")
            )
        }
    }

    private func entries(of conversation: RemoteAgentConversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isTruncated {
                        Text("Earlier messages are not shown.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(conversation.entries) { entry in
                        AgentEntryView(entry: entry)
                            .id(entry.id)
                    }
                    // Scrolling to the last entry lands on its top, which hides a long message's
                    // end. An anchor after it is what puts the newest text on screen.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .accessibilityIdentifier("agent.conversation")
            .onChange(of: conversation.entries.count) {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    private static let bottomAnchor = "conversation.bottom"
}

private struct AgentEntryView: View {
    let entry: RemoteAgentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    AgentTextView(text: text, role: entry.role)
                case .thinking(let text):
                    AgentThinkingView(text: text)
                case .toolUse(let use):
                    AgentToolUseView(use: use)
                case .toolResult(let result):
                    AgentToolResultView(result: result)
                case .image:
                    Label("Image", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What was said. A person's message is tinted and indented; the agent's runs full width, because
/// the agent does most of the talking and a bubble for every paragraph wastes a phone's width.
private struct AgentTextView: View {
    let text: String
    let role: RemoteAgentRole

    var body: some View {
        if role == .user {
            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Folded away by default. It says what the agent is doing, and it is not what the agent said.
private struct AgentThinkingView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// What a tool was asked to do.
///
/// The name alone is not enough: "Bash" says nothing about whether the agent is about to list a
/// directory or remove one, and that difference is the whole reason someone checks from a phone.
private struct AgentToolUseView: View {
    let use: RemoteAgentToolUse
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(use.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(use.name)
                            .font(.caption.weight(.semibold))
                        Text(use.summary)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            // A command that wraps must stay left aligned. Centred, the second line
                            // of a command reads as something nobody would ever type.
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
            }

            if use.isPending {
                // The agent is stopped on this and cannot go on alone. Answering it is the next
                // milestone; saying so is what this screen owes the person today.
                Label("Waiting for your answer on the Mac", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("agent.pending")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if use.isPending {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange, lineWidth: 1.5)
            }
        }
    }
}

private struct AgentToolResultView: View {
    let result: RemoteAgentToolResult
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                if result.isTruncated {
                    Text("Cut to fit. The whole output is on your Mac.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(
                result.isError ? "Failed" : "Result",
                systemImage: result.isError ? "exclamationmark.triangle.fill" : "arrow.turn.down.right"
            )
            .font(.caption)
            .foregroundStyle(result.isError ? Color.red : .secondary)
        }
        .padding(.leading, 10)
    }
}
