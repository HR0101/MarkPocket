import AppKit
import SwiftUI

@main
struct MarkPocketMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var coordinator = SyncCoordinator()
    @State private var loginManager = LoginItemManager()

    var body: some Scene {
        Window("MarkPocket Sync", id: "main") {
            MainSyncView(coordinator: coordinator, loginManager: loginManager)
        }
        .defaultSize(width: 880, height: 580)

        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.isSyncing ? "arrow.triangle.2.circlepath.icloud" : (coordinator.settings.isAutoSyncEnabled ? "doc.text.fill" : "pause.circle"))
        }
        .menuBarExtraStyle(.window)
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
