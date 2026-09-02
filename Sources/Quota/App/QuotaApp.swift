import AppKit
import SwiftUI

@main
struct QuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    await model.start()
                }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Account…") {
                    model.isShowingAddAccount = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Usage") {
                Button("Refresh All") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)

                Button("Show Reset Planner") {
                    model.selection = .resetPlanner
                }
                .keyboardShortcut("2", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
