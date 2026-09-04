import AppKit
import QuotaCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Refresh") {
                Picker(
                    "Automatic refresh",
                    selection: Binding(
                        get: { model.automaticRefreshInterval },
                        set: { model.setAutomaticRefreshInterval($0) }
                    )
                ) {
                    ForEach(AutomaticRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                Text("Automatic refresh applies to connected ChatGPT, Claude, OpenAI API, and Anthropic API accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy & storage") {
                LabeledContent("Usage history") {
                    Text("Local JSON")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Quota-stored API keys") {
                    Text("macOS Keychain")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Managed sign-ins") {
                    Text("Isolated provider profiles")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Telemetry") {
                    Text("None")
                        .foregroundStyle(.secondary)
                }

                Button("Show Data Folder in Finder") {
                    showDataFolder()
                }
                .disabled(model.dataDirectoryURL == nil)
            }

            Section("Provider boundaries") {
                Label(
                    "API organization connections report provider usage and costs but may not expose live quota headroom or reset times.",
                    systemImage: "building.2"
                )
                Label(
                    "ChatGPT Plus and Pro use OpenAI's local Codex service and keep each account's managed sign-in isolated.",
                    systemImage: "person.crop.circle"
                )
                Label(
                    "Claude Pro and Max use Anthropic's local Claude Code client. Quota receives reported usage windows without reading Claude credentials.",
                    systemImage: "sun.max"
                )
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 430)
        .navigationTitle("Quota Settings")
    }

    private func showDataFolder() {
        guard let directoryURL = model.dataDirectoryURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
        } catch {
            model.presentedError = PresentedError(
                title: "Could not open data folder",
                message: error.localizedDescription
            )
        }
    }
}
