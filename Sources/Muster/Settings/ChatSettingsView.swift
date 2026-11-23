import SwiftUI

struct ChatSettingsView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var store: SettingsStore
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var feedback: String?
    @State private var failed = false
    @State private var test: Task<Void, Never>?

    private var hasChanges: Bool { modelID != store.chatModelID || !apiKey.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Chat model"))
            Card {
                SettingsRow(label: L10n.t("OpenAI model ID")) {
                    MiniField(placeholder: "gpt-4.1-mini", text: $modelID, width: 200)
                }
                Hairline()
                SettingsRow(label: L10n.t("OpenAI API key"), hint: L10n.t("Muster stores your API key in macOS Keychain.")) {
                    SecureField(chat.keyIsSaved ? L10n.t("Replace saved key") : "sk-…", text: $apiKey)
                        .font(T.body).frame(width: 200)
                }
                Hairline()
                HStack(spacing: T.s2) {
                    if let message = feedback ?? chat.keyError {
                        Text(message).font(T.small).foregroundStyle(failed || chat.keyError != nil ? T.red : T.muted)
                    }
                    Spacer(minLength: T.s2)
                    Button(L10n.t("Remove key")) {
                        perform { try chat.removeKey(); apiKey = ""; return L10n.t("API key removed.") }
                    }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .disabled(!chat.keyIsSaved && chat.keyError == nil)
                    Button(L10n.t("Test connection"), action: testConnection)
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(!chat.keyIsSaved || hasChanges)
                    Button(L10n.t("Save")) {
                        perform {
                            try chat.saveConfiguration(model: modelID, apiKey: apiKey, settings: store)
                            modelID = store.chatModelID
                            apiKey = ""
                            return L10n.t("Saved")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!hasChanges)
                }
                .padding(T.s3)
            }
            .disabled(test != nil)
            Text(L10n.t("Chat messages and matching project and session details are sent to OpenAI. Agent transcripts stay on your Mac."))
                .font(T.small).foregroundStyle(T.muted)
        }
        .task {
            modelID = store.chatModelID
            chat.refreshKeyStatus()
        }
        .onDisappear { test?.cancel(); test = nil }
    }

    private func perform(_ action: () throws -> String) {
        do {
            feedback = try action()
            failed = false
        } catch {
            feedback = ChatModel.errorMessage(for: error)
            failed = true
        }
    }

    private func testConnection() {
        failed = false
        feedback = L10n.t("Testing connection…")
        test = Task {
            do {
                try await chat.testConnection(model: store.chatModelID)
                guard !Task.isCancelled else { return }
                feedback = L10n.t("OpenAI connection succeeded.")
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                feedback = ChatModel.errorMessage(for: error)
            }
            test = nil
        }
    }
}
