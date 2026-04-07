import SwiftUI

@main
struct CodeGraphContextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Label("CodeGraphContext", systemImage: "circle.grid.3x3.fill")
        }
        .menuBarExtraStyle(.menu)

        Window("CodeGraphContext - Visualization", id: "visualization") {
            VisualizationWindow(port: appState.vizPort)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — menu bar only app
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Subprocesses are cleaned up via AppState.stop() called from Quit button
    }
}
