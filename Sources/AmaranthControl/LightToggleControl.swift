import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center / menu-bar control that toggles the amaran light. Built as a
/// `ControlWidgetButton` (reliable action dispatch) whose icon reflects the
/// light's current state via the value provider — filled bulb when on, empty
/// when off. The agent calls `reloadControls` whenever the state changes, so the
/// icon stays in sync. Targets the first light the agent publishes.
@main
struct LightToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedStore.controlKind,
            provider: Provider()
        ) { value in
            ControlWidgetButton(action: ToggleLightIntent()) {
                Label(value.name, systemImage: value.isOn ? "lightbulb.fill" : "lightbulb")
            }
            .tint(value.isOn ? .orange : nil)
        }
        .displayName("Amaran Light")
        .description("Toggle the amaran light on or off.")
    }

    struct Value {
        var isOn: Bool
        var name: String
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value {
            Value(isOn: false, name: "Amaran Light")
        }

        func currentValue() async throws -> Value {
            let fixture = SharedStore.readRoster().first
            let isOn = fixture.map { SharedStore.readState(address: $0.address) } ?? false
            SharedStore.log.debug("currentValue light=\(fixture?.address ?? -1, privacy: .public) isOn=\(isOn, privacy: .public)")
            return Value(isOn: isOn, name: fixture?.name ?? "Amaran Light")
        }
    }
}
