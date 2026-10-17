import SwiftUI
import AppKit

@main
struct LovortMacSubtitleServiceApp: App {
    @StateObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Lovort 局域网 Mac 字幕服务", id: "main") {
            MainWindowView(appState: appState)
                .onAppear {
                    appState.onAppLaunch()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.serviceManager.terminateOnAppQuit()
                }
        }
        .defaultSize(width: 850, height: 600)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Lovort 字幕服务", systemImage: appState.serviceManager.status.menuBarSymbol) {
            MenuBarView(appState: appState) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
        }
    }
}
