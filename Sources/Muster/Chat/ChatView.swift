import MusterCore
import SwiftUI

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var panel: PanelModel
    @ObservedObject var settings: SettingsStore
    private var canSend: Bool {
        chat.keyIsSaved && !chat.isGenerating && chat.draft.count <= ChatModel.draftLimit
            && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.s3) {
                Text(L10n.t("Chat")).font(.title2.weight(.semibold)).foregroundStyle(T.fg)
                Spacer()
                Button { panel.showSettings(.chat) } label: {
                    HStack(spacing: T.s2) {
                        StatusDot(tone: chat.keyIsSaved ? .busy : .neutral, size: 6).accessibilityHidden(true)
                        Text("OpenAI · " + settings.chatModelID).lineLimit(1)
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .help(L10n.t("Chat model"))
                Button { chat.newConversation() } label: {
                    Label(L10n.t("New conversation"), systemImage: "square.and.pencil")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(chat.turns.isEmpty && chat.draft.isEmpty)
            }
            .padding(.horizontal, 24).frame(height: 60)
            Hairline()
            transcript
            composer
        }
        .background(T.card)
        .task { chat.refreshKeyStatus() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if chat.turns.isEmpty { emptyState }
                    ForEach(chat.turns) { turn in
                        message(turn)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 650)
                .padding(.horizontal, 24).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: chat.turns.last?.reply) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.turns.last?.cards.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.turns.last?.notice) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            BrandMark()
            if chat.keyIsSaved {
                Text(L10n.t("Ask Muster about your projects or recent sessions."))
                    .font(T.body).foregroundStyle(T.fg2)
            } else {
                Text(chat.keyError ?? L10n.t("Save an OpenAI API key in Chat model settings first."))
                    .font(T.body).foregroundStyle(T.fg2)
                Button(L10n.t("Open chat settings")) { panel.showSettings(.chat) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ turn: ChatModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer(minLength: 36)
                Text(verbatim: turn.prompt).font(T.body).foregroundStyle(T.fg)
                    .textSelection(.enabled)
                    .padding(.horizontal, T.s3).padding(.vertical, T.s2)
                    .background(T.accentSoft, in: .rect(cornerRadius: 10))
            }
            HStack(alignment: .top, spacing: T.s2) {
                BrandMark().frame(width: 32, height: 32)
                    .background(T.bg, in: .rect(cornerRadius: T.r))
                VStack(alignment: .leading, spacing: T.s2) {
                    Text("Muster").font(T.body.weight(.semibold)).foregroundStyle(T.fg)
                    if turn.didQuery {
                        Label(L10n.t("Queried projects and sessions"), systemImage: "checkmark.circle")
                            .font(T.small).foregroundStyle(T.muted)
                    }
                    if !turn.reply.isEmpty {
                        Text(verbatim: turn.reply).font(T.body).foregroundStyle(T.fg)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(turn.cards) { card in
                        ChatSessionCard(card: card, isAvailable: panel.sessions.contains { session in
                            session.key == card.session.key && session.isProcessAlive && session.client != nil
                                && session.pid == card.session.pid && session.pidStartTime == card.session.pidStartTime
                        }) { chat.openClient(card, panel: panel) }
                    }
                    if let notice = turn.notice {
                        Text(notice).font(T.small).foregroundStyle(T.muted)
                        if turn.id == chat.turns.last?.id {
                            Button(L10n.t("Retry reply")) {
                                chat.send(panel: panel, model: settings.chatModelID, retrying: turn.id)
                            }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                            .disabled(!chat.keyIsSaved || chat.isGenerating)
                        }
                    } else if chat.isGenerating && turn.id == chat.turns.last?.id {
                        ProgressView().controlSize(.small).accessibilityLabel(L10n.t("Generating response"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, T.s1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            if let error = chat.sendError {
                Text(error).font(T.small).foregroundStyle(T.red)
            } else if chat.draft.count > ChatModel.draftLimit {
                Text(L10n.t("Messages can contain up to %d characters.", ChatModel.draftLimit)).font(T.small).foregroundStyle(T.red)
            }
            HStack(alignment: .bottom, spacing: T.s2) {
                ChatEditor(text: $chat.draft, enabled: chat.keyIsSaved, send: send)
                if chat.isGenerating {
                    composerButton("stop.fill", title: L10n.t("Stop generating"), action: chat.stop)
                } else {
                    composerButton("arrow.up", title: L10n.t("Send message"), action: send).disabled(!canSend)
                }
            }
            .padding(T.s3)
            .frame(height: 78)
            .background(T.card2, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(T.line, lineWidth: 1).allowsHitTesting(false) }
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.t("Messages and matching details go to OpenAI"), systemImage: "lock")
                Spacer(minLength: T.s2)
                Text(L10n.t("↵ Send · ⇧↵ New line"))
            }
            .font(T.small).foregroundStyle(T.muted)
        }
        .frame(maxWidth: 650)
        .padding(.horizontal, 24).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    private func composerButton(_ icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(minWidth: 16) }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .accessibilityLabel(title).help(title)
    }

    private func send() {
        if canSend { chat.send(panel: panel, model: settings.chatModelID) }
    }
}

private struct ChatSessionCard: View {
    let card: ChatTools.Card
    let isAvailable: Bool
    let open: () -> String?
    @State private var error: String?

    var body: some View {
        Card {
            HStack {
                Text(L10n.t("Session available to open")).font(T.section).foregroundStyle(T.muted)
                Spacer()
                StatusDot(tone: isAvailable ? .busy : .neutral, size: 6).accessibilityHidden(true)
                Text(L10n.t(isAvailable ? "Running" : "This session is no longer available to open."))
                    .font(T.small).foregroundStyle(T.muted)
            }
            .padding(.horizontal, T.s3).frame(height: 30)
            .background(T.card2, in: UnevenRoundedRectangle(topLeadingRadius: T.r, topTrailingRadius: T.r))
            Hairline()
            HStack(spacing: T.s3) {
                AgentLogo(agentID: card.session.agent.rawValue, mark: String(card.session.agent.displayName.prefix(1)), size: 32)
                VStack(alignment: .leading, spacing: T.s1) {
                    Text(verbatim: card.title).font(T.body.weight(.semibold)).foregroundStyle(T.fg).lineLimit(2)
                    HStack(spacing: T.s1) {
                        Text(([card.session.agent.displayName, card.project] + [card.session.client?.name].compactMap { $0 })
                            .joined(separator: " · ") + " · ").lineLimit(1)
                        Text(card.session.lastActivityAt, style: .relative).lineLimit(1)
                    }
                    .font(T.small).foregroundStyle(T.muted)
                    if let error { Text(error).font(T.small).foregroundStyle(T.red) }
                }
                Spacer(minLength: T.s2)
                Button { error = open() } label: {
                    Label(L10n.t("Open client"), systemImage: "arrow.up.right")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(!isAvailable)
            }
            .padding(T.s3)
        }
        .frame(maxWidth: 520)
    }
}

final class ChatInputTextView: NSTextView {
    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder, let font else { return }
        (L10n.t("Message Muster…") as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font, .foregroundColor: NSColor(T.muted)
        ])
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

private struct ChatEditor: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(editor: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChatInputTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setAccessibilityLabel(L10n.t("Message Muster…"))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.editor = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.needsDisplay = true
        }
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = NSColor(T.fg)
        view.insertionPointColor = NSColor(T.fg)
        view.isEditable = enabled
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var editor: ChatEditor
        init(editor: ChatEditor) { self.editor = editor }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            editor.text = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(),
                  NSApp.currentEvent?.modifierFlags.contains(.shift) != true else { return false }
            editor.send()
            return true
        }
    }
}
