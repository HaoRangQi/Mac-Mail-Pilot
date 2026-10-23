import SwiftUI

@main
struct MailPilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.prefs)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("写邮件") { model.composing = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 MailPilot") { model.openSettings(tab: .about) }
            }

            CommandGroup(after: .appSettings) {
                Button("设置…") { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("问问 AI") { model.toggleAsk() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("刷新") { Task { await model.reload() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
