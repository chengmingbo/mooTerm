import SwiftUI

@main
struct mtermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup("mterm") {
            ContentView()
                .environmentObject(sessionStore)
                .frame(minWidth: 720, minHeight: 360)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { sessionStore.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { sessionStore.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Split Horizontally") { sessionStore.activeTab?.split(.horizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Split Vertically") { sessionStore.activeTab?.split(.vertical) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Close Pane") { sessionStore.activeTab?.closeActivePane() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                Button("Toggle Broadcast Group") { sessionStore.activeTab?.toggleBroadcast() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}