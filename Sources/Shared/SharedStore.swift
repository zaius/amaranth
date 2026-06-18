import Foundation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared state bridge between the menu-bar agent and the Control Center
/// extension. They run in separate (and differently-sandboxed) processes, so
/// everything flows through the App Group container:
///
///   - agent → extension: the agent publishes the fixture roster + each
///     fixture's on/off state into the container, then asks Control Center to
///     reload the control so it re-reads the new value.
///   - extension → agent: the toggle's intent writes a one-shot command into
///     the container and fires a Darwin notification; the agent (which owns the
///     live BLE mesh bearer) observes it and performs the actual mesh send.
///
/// The extension never touches Bluetooth: only one process can hold the mesh
/// proxy connection, and the agent already does. See ControlBridge.swift.
enum SharedStore {
    /// macOS App Groups must be prefixed with the Team ID. Both the app and the
    /// extension carry this in `com.apple.security.application-groups`, which is
    /// what grants them a shared container at
    /// ~/Library/Group Containers/<group>/.
    static let appGroup = "P9U2E575US.group.so.kel.Amaranth"

    /// Must match the `kind:` passed to AppIntentControlConfiguration.
    static let controlKind = "so.kel.Amaranth.LightToggle"

    /// Darwin notification fired by the extension after writing a command.
    static let commandNotification = "so.kel.Amaranth.control.command"

    /// Shared between the agent and the extension; filter logs with
    /// `log stream --predicate 'subsystem == "so.kel.Amaranth"'`.
    static let log = Logger(subsystem: "so.kel.Amaranth", category: "control")

    /// A light the control can be configured to target.
    struct Fixture: Codable, Hashable {
        var address: Int
        var name: String
    }

    /// A one-shot toggle request from the extension to the agent.
    struct Command: Codable {
        var address: Int
        var isOn: Bool
    }

    // MARK: - Container

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static func url(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name)
    }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Roster (agent writes, extension reads for the picker)

    static func writeRoster(_ fixtures: [Fixture]) { write(fixtures, to: "roster.json") }
    static func readRoster() -> [Fixture] { read([Fixture].self, from: "roster.json") ?? [] }

    // MARK: - Per-fixture on/off state (agent writes, extension reads to render)

    static func writeStates(_ states: [String: Bool]) { write(states, to: "state.json") }

    static func writeState(address: Int, isOn: Bool) {
        var states = read([String: Bool].self, from: "state.json") ?? [:]
        states[String(address)] = isOn
        writeStates(states)
    }

    static func readState(address: Int) -> Bool {
        (read([String: Bool].self, from: "state.json") ?? [:])[String(address)] ?? false
    }

    // MARK: - Command (extension writes + signals, agent reads)

    static func writeCommand(address: Int, isOn: Bool) {
        write(Command(address: address, isOn: isOn), to: "command.json")
        log.debug("wrote command address=\(address, privacy: .public) isOn=\(isOn, privacy: .public)")
    }

    static func readCommand() -> Command? { read(Command.self, from: "command.json") }

    static func postCommand() {
        log.debug("posting Darwin notification \(commandNotification, privacy: .public)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(commandNotification as CFString),
            nil, nil, true
        )
    }

    // MARK: - Control refresh (agent asks Control Center to re-read the value)

    static func reloadControls() {
        #if canImport(WidgetKit)
        ControlCenter.shared.reloadControls(ofKind: controlKind)
        #endif
    }
}
