import Sentry
import SwiftUI

@main
struct AmaranthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = Updater()

    init() {
        SentrySDK.start { options in
            options.dsn = "https://cbf5c8426f024e8dd93248e07fd31476@o4511463230668800.ingest.us.sentry.io/4511582436720640"
            // Release defaults to {bundleID}@{CFBundleShortVersionString}+{CFBundleVersion};
            // the build number comes from the git commit count, so each build is distinct.
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
        }
        // Tie crashes back to the exact commit (GitCommit is injected at build time).
        if let commit = Bundle.main.infoDictionary?["GitCommit"] as? String, !commit.isEmpty {
            SentrySDK.configureScope { $0.setTag(value: commit, key: "git_commit") }
        }
    }

    var body: some Scene {
        MenuBarExtra("Amaranth", systemImage: "lightbulb.led") {
            MenuView()
                .environmentObject(appDelegate.controller)
                .environmentObject(updater)
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
    private var controlBridge: ControlBridge?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Log.app.notice("applicationDidFinishLaunching — booting MeshController")
            controller.bootstrap()
            // Listen for Control Center toggle requests and keep the control's
            // published state in sync with the mesh.
            controlBridge = ControlBridge(controller: controller)
        }
    }
}
