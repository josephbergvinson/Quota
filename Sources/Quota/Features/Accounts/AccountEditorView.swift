import QuotaCore
import SwiftUI

struct AccountEditorView: View {
    enum Mode {
        case add
        case edit(ConnectedAccount)

        var title: String {
            switch self {
            case .add: "Add Account"
            case .edit: "Edit Account"
            }
        }

        var existingAccount: ConnectedAccount? {
            guard case let .edit(account) = self else { return nil }
            return account
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var displayName: String
    @State private var accountKind: AccountKind
    @State private var organizationIdentifier: String
    @State private var credential: String = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(mode: Mode) {
        self.mode = mode
        let existing = mode.existingAccount
        _displayName = State(initialValue: existing?.displayName ?? AccountKind.chatGPTPro.displayName)
        _accountKind = State(initialValue: existing?.kind ?? .chatGPTPro)
        _organizationIdentifier = State(initialValue: existing?.organizationIdentifier ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Account") {
                    if let existing = mode.existingAccount {
                        LabeledContent("Type", value: existing.kind.displayName)
                    } else {
                        Picker("Type", selection: $accountKind) {
                            ForEach(AccountKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .onChange(of: accountKind) { _, newValue in
                            displayName = newValue.displayName
                            organizationIdentifier = ""
                            credential = ""
                        }
                    }

                    TextField("Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)

                    if accountKind == .openAIAPI {
                        TextField("Organization ID (optional)", text: $organizationIdentifier)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if accountKind.requiresCredential {
                    Section("Connection") {
                        SecureField(
                            mode.existingAccount == nil ? "Admin API key" : "New admin API key (leave blank to keep current)",
                            text: $credential
                        )
                        .textFieldStyle(.roundedBorder)

                        Label {
                            Text(credentialGuidance)
                        } icon: {
                            Image(systemName: "key.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Label(
                            "The key is stored in macOS Keychain and is never written to Quota's data file.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else if accountKind.isChatGPTSubscription {
                    Section("Connection") {
                        Label {
                            Text("Quota opens OpenAI's managed ChatGPT sign-in through the local Codex service. Codex keeps each account's tokens in macOS Keychain.")
                        } icon: {
                            Image(systemName: "person.badge.key")
                        }
                        .font(.callout)

                        Text("After adding the account, finish sign-in in your browser. Quota reads only the supported Codex quota windows and aggregate token history; other ChatGPT product limits stay unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if accountKind.isClaudeSubscription {
                    Section("Connection") {
                        Label {
                            Text("Quota asks Anthropic's installed Claude Code client to open its secure sign-in page. Claude Code keeps this account's managed session isolated in its own local profile.")
                        } icon: {
                            Image(systemName: "person.badge.key")
                        }
                        .font(.callout)

                        Text("After adding the account, finish sign-in in your browser. Quota reads only the usage windows and reset times Claude Code reports; token history and other missing metrics stay hidden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(primaryButtonTitle) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(16)
        }
        .frame(width: 520, height: accountKind.requiresCredential ? 500 : 440)
        .navigationTitle(mode.title)
    }

    private var credentialGuidance: String {
        switch accountKind {
        case .openAIAPI:
            "Use an OpenAI organization Admin API key. Normal project API keys cannot access organization usage."
        case .anthropicAPI:
            "Use an Anthropic Admin API key (sk-ant-admin…) for a Claude Console organization. Workspace keys cannot access organization usage reports."
        case .chatGPTPlus, .chatGPTPro, .chatGPTSubscription,
             .claudePro, .claudeMax, .claudeSubscription:
            "Use a supported provider credential."
        }
    }

    private var primaryButtonTitle: String {
        guard mode.existingAccount == nil else { return "Save" }
        if accountKind.isChatGPTSubscription {
            return "Connect ChatGPT"
        }
        if accountKind.isClaudeSubscription {
            return "Connect Claude"
        }
        return "Add Account"
    }

    private func save() {
        validationMessage = nil
        isSaving = true

        do {
            let existing = mode.existingAccount
            let account = try ConnectedAccount(
                id: existing?.id ?? UUID(),
                displayName: displayName,
                kind: existing?.kind ?? accountKind,
                organizationIdentifier: accountKind == .openAIAPI ? organizationIdentifier : nil,
                createdAt: existing?.createdAt ?? Date()
            )

            let replacementCredential: ProviderCredential?
            if credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if existing == nil, account.kind.requiresCredential {
                    throw CredentialStoreError.emptyCredential
                }
                replacementCredential = nil
            } else {
                replacementCredential = try ProviderCredential(secret: credential)
            }

            Task {
                let succeeded: Bool
                if existing == nil {
                    succeeded = await model.addAccount(
                        account,
                        credential: replacementCredential,
                        initialSnapshot: nil
                    )
                } else {
                    succeeded = await model.updateAccount(
                        account,
                        replacementCredential: replacementCredential
                    )
                }
                isSaving = false
                if succeeded {
                    dismiss()
                }
            }
        } catch {
            validationMessage = error.localizedDescription
            isSaving = false
        }
    }
}
