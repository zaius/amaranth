import SwiftUI

@main
struct AmaranthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Amaranth", systemImage: "lightbulb.led") {
            MenuView()
                .environmentObject(appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the MeshController so we can boot it at app-launch (before the first
/// menu open) and keep its GATT proxy connection alive for the whole process
/// lifetime, regardless of how many times the user opens/closes the popover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = MeshController()

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Log.app.notice("applicationDidFinishLaunching — booting MeshController")
            controller.bootstrap()
        }
    }
}
