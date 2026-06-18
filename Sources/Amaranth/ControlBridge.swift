import Foundation

/// Receives toggle requests from the Control Center extension and applies them
/// through the agent's live mesh bearer. The extension can't touch Bluetooth
/// (separate sandboxed process; only one holder of the mesh proxy), so it writes
/// a command into the App Group container and fires a Darwin notification — we
/// observe that here and hand off to `MeshController`.
@MainActor
final class ControlBridge {
    private let controller: MeshController

    init(controller: MeshController) {
        self.controller = controller
        registerObserver()
        // Publish whatever we already know so a control added before the first
        // mesh event still has a roster + state to render.
        controller.publishSharedSnapshot()
    }

    private func registerObserver() {
        // The C callback can't capture context, so pass `self` through as the
        // observer pointer and recover it inside. `self` is owned by AppDelegate
        // for the process lifetime, so an unretained pointer is safe.
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<ControlBridge>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in bridge.handleCommand() }
            },
            SharedStore.commandNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handleCommand() {
        guard let command = SharedStore.readCommand() else {
            SharedStore.log.error("agent: notification fired but no command.json to read")
            return
        }
        guard let fixture = controller.fixtures.first(where: { Int($0.unicastAddress) == command.address }) else {
            SharedStore.log.error("agent: no fixture for address \(command.address, privacy: .public) (have \(self.controller.fixtures.count, privacy: .public))")
            return
        }
        SharedStore.log.debug("agent: applying command address=\(command.address, privacy: .public) isOn=\(command.isOn, privacy: .public)")
        controller.setOnOff(fixture, isOn: command.isOn)
    }
}
