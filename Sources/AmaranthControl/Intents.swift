import AppIntents

/// Toggles the amaran light. A plain `AppIntent` on a `ControlWidgetButton`,
/// NOT a `SetValueIntent` on a `ControlWidgetToggle`: the latter doesn't
/// reliably dispatch in this setup (its `value` never resolves — see git
/// history). This reads the light's current state from the shared container and
/// sends the opposite. Runs in the extension's background process (no app launch,
/// no Bluetooth here — the agent owns the mesh bearer and applies the command).
struct ToggleLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Amaran Light"
    static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        let roster = SharedStore.readRoster()
        guard let address = roster.first?.address else {
            SharedStore.log.error("ToggleLightIntent.perform: roster empty — nothing to toggle")
            return .result()
        }
        let newState = !SharedStore.readState(address: address)
        SharedStore.log.debug("ToggleLightIntent.perform address=\(address, privacy: .public) → \(newState, privacy: .public)")
        SharedStore.writeCommand(address: address, isOn: newState)
        // Optimistically reflect the new state so the control's icon updates
        // immediately; the agent corrects it if the light reports otherwise.
        SharedStore.writeState(address: address, isOn: newState)
        SharedStore.postCommand()
        return .result()
    }
}
