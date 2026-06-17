import Combine
import Sparkle
import SwiftUI

/// Drives Sparkle auto-updates and backs the "Check for Updates…" menu item.
///
/// Creating the controller with `startingUpdater: true` schedules the
/// background update check (per `SUEnableAutomaticChecks` in Info.plist) for
/// the app's lifetime. The feed URL and the EdDSA public key that verifies
/// downloads both live in Info.plist (`SUFeedURL` / `SUPublicEDKey`).
@MainActor
final class Updater: ObservableObject {
    /// Sparkle disables the menu item while a check is already in flight; the
    /// view binds `.disabled` to the inverse of this.
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
