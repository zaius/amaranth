import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var controller: MeshController
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader

            if let err = controller.importError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.fixtures.isEmpty {
                Text("No lights yet — open amaran Desktop, pair the light, then relaunch Amaranth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.fixtures) { fixture in
                    FixtureRow(fixture: fixture)
                        .environmentObject(controller)
                    if fixture.id != controller.fixtures.last?.id {
                        Divider().opacity(0.6)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    controller.refreshAllState()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Refresh state")

                Button {
                    updater.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!updater.canCheckForUpdates)
                .help("Check for updates")

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .help("Quit Amaranth")
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder private var statusHeader: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(controller.connectionState.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch controller.connectionState {
        case .ready: return .green
        case .connecting, .scanning: return .yellow
        case .noBluetooth, .error: return .red
        case .idle: return .gray
        }
    }
}

private struct FixtureRow: View {
    @ObservedObject var fixture: FixtureViewModel
    @EnvironmentObject private var controller: MeshController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fixture.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { fixture.isOn },
                    set: { controller.setOnOff(fixture, isOn: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            IconSlider(
                icon: "sun.max.fill",
                value: Binding(
                    get: { fixture.lightness },
                    set: { controller.setLightness(fixture, lightness: $0) }
                ),
                tint: .white.opacity(fixture.isOn ? 0.92 : 0.45)
            )

            IconSlider(
                icon: "thermometer.medium",
                value: Binding(
                    get: { fixture.temperature },
                    set: { controller.setTemperature(fixture, slider: $0) }
                ),
                tint: ctTint(slider: fixture.temperature).opacity(fixture.isOn ? 1.0 : 0.55)
            )
        }
    }

    /// Warm→cool gradient endpoint matching the CCT slider value.
    private func ctTint(slider: Double) -> Color {
        let warm = SIMD3<Double>(1.00, 0.66, 0.35)
        let cool = SIMD3<Double>(0.72, 0.82, 1.00)
        let mix = warm * (1 - slider) + cool * slider
        return Color(red: mix.x, green: mix.y, blue: mix.z)
    }
}
