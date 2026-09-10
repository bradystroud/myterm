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
    @State private var draft = ""
    @FocusState private var isWritingReply: Bool

    var body: some View {
        Group {
            if isShowingTerminal {
                TerminalScreen(tab: tab, store: store)
            } else {
                conversation
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
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

    /// What the person can send: either an answer to a question the agent is stopped on, or words.
    ///
    /// The two are never offered together. While an agent is waiting on a permission prompt it is
    /// not reading a reply, so a text field there would take something that goes nowhere.
    @ViewBuilder
    private var composer: some View {
        if !store.client.allowsMutation {
            Label("View only. Typing is turned off on the Mac.", systemImage: "eye")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("agent.viewOnly")
        } else if !store.promptOptions.isEmpty {
            AgentPromptBar(tab: tab, store: store)
        } else {
            AgentReplyBar(tab: tab, store: store, draft: $draft, isWriting: $isWritingReply)
        }
    }

    private static let bottomAnchor = "conversation.bottom"
}

/// Work the agent handed to another agent.
///
/// This is not another tool call and should not read as one. It is the agent bringing somebody in,
/// and the honest thing to say is that the work happened somewhere this screen cannot follow: a
/// teammate's own turns are not in this conversation's record, only the handover and the report.
private struct AgentTeammateView: View {
    let use: RemoteAgentToolUse
    let teammate: RemoteAgentTeammate
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(use.detail)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(heading)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                        Text(use.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                    }
                }
            }

            if use.isPending {
                Label("Still working", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        teammate.kind == .delegated ? "person.badge.plus" : "paperplane"
    }

    /// Names the teammate where the call named one. "Explore" says far more than "Agent" does.
    private var heading: String {
        switch teammate.kind {
        case .delegated:
            guard let role = teammate.role else { return "Handed to a teammate" }
            return "Handed to \(role)"
        case .message:
            guard let addressee = teammate.addressee else { return "Message to a teammate" }
            return "Message to \(addressee)"
        }
    }
}

/// The answer to a question the agent has stopped on.
///
/// Every button here names a choice the Mac read off its own screen a moment ago. Tapping one sends
/// the label back, and the Mac only types a digit if that label is still sitting on that number, so
/// a menu that moved under the person answers nothing at all.
private struct AgentPromptBar: View {
    let tab: RemoteTab
    let store: RemoteSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your agent is waiting on this", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)

            ForEach(store.promptOptions) { option in
                Button {
                    store.answerPrompt(tabID: tab.id, option: option)
                } label: {
                    Text(option.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("agent.option.\(option.number)")
            }

            // Always offered, and never one of the numbered choices. Cancelling is the one answer
            // that means the same thing whatever the menu holds.
            Button(role: .destructive) {
                store.denyPrompt(tabID: tab.id)
            } label: {
                Text("Don\u{2019}t allow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agent.deny")
        }
        .disabled(store.isAnswering)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Grouped, so VoiceOver reads the question and its choices as one thing rather than as
        // loose buttons, and so the identifier names a container that can actually be found.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.prompt")
    }
}

/// Saying something to the agent.
private struct AgentReplyBar: View {
    let tab: RemoteTab
    let store: RemoteSessionStore
    @Binding var draft: String
    @FocusState.Binding var isWriting: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Grows with what is written, up to a point: a phone reply is often a sentence, and a
            // single line hides most of it.
            TextField("Reply to your agent", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                .focused($isWriting)
                .accessibilityIdentifier("agent.reply")

            Button {
                store.reply(tabID: tab.id, text: draft)
                draft = ""
                isWriting = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("agent.send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
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
                    if let teammate = use.teammate {
                        AgentTeammateView(use: use, teammate: teammate)
                    } else {
                        AgentToolUseView(use: use)
                    }
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

/// What was said, rendered as the markdown the agent wrote.
///
/// A person's message is tinted and indented; the agent's runs full width, because the agent does
/// most of the talking and a bubble for every paragraph wastes a phone's width.
private struct AgentTextView: View {
    let text: String
    let role: RemoteAgentRole

    var body: some View {
        let blocks = RemoteAgentMarkdown.blocks(of: text)
        if role == .user {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    AgentTextBlockView(block: block)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    AgentTextBlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentTextBlockView: View {
    let block: RemoteAgentTextBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            inline(text)
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

        case .bullet(let text):
            marker("\u{2022}", text)

        case .numbered(let number, let text):
            marker("\(number).", text)

        case .code(let language, let text):
            AgentCodeBlockView(language: language, text: text)
        }
    }

    /// A hanging indent, so a bullet that wraps stays clear of its own marker.
    private func marker(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(symbol)
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            inline(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bold, italics, inline code, and links, left to the system parser.
    ///
    /// Whitespace is preserved rather than collapsed, because the block structure was already
    /// decided and this must not undo it. A message that will not parse is shown as it arrived,
    /// which is worse than formatted and far better than nothing.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return Text(text)
        }
        return Text(attributed)
    }
}

/// A fenced block. Scrolls sideways rather than wrapping, because a wrapped command is a command
/// nobody can copy with confidence.
private struct AgentCodeBlockView: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language {
                Text(language)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
