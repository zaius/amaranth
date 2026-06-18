import Foundation
import CoreBluetooth
import Combine
import NordicMesh

/// Observable state for a single mesh-controlled light fixture.
@MainActor
final class FixtureViewModel: ObservableObject, Identifiable {
    let id: UUID
    let unicastAddress: UInt16
    let productCode: String
    @Published var name: String
    @Published var isOn: Bool = false
    /// 0.0 – 1.0 representing the SIG Lightness range 1 ... 0xFFFF.
    @Published var lightness: Double = 1.0
    /// 0.0 – 1.0 mapping to a CCT range we can later refine per fixture.
    @Published var temperature: Double = 0.5
    @Published var lastStatus: Date?

    init(_ fixture: MeshImporter.Fixture) {
        self.id = fixture.uuid
        self.unicastAddress = fixture.unicastAddress
        self.productCode = fixture.productCode
        self.name = fixture.name
    }
}

@MainActor
final class MeshController: ObservableObject {

    enum ConnectionState: Equatable {
        case idle
        case noBluetooth
        case scanning
        case connecting(name: String)
        case ready(proxyName: String)
        case error(String)

        var description: String {
            switch self {
            case .idle: return "Idle"
            case .noBluetooth: return "Bluetooth off"
            case .scanning: return "Scanning…"
            case .connecting(let n): return "Connecting to \(n)…"
            case .ready(let n): return "Connected via \(n)"
            case .error(let e): return "Error: \(e)"
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var fixtures: [FixtureViewModel] = []
    @Published private(set) var importError: String?

    private let manager: MeshNetworkManager
    private var connection: NetworkConnection?
    private var fixtureByAddress: [UInt16: FixtureViewModel] = [:]
    /// Debounce so dragging a slider doesn't fire 60 mesh messages per second.
    private var sendDebouncers: [String: Task<Void, Never>] = [:]
    private var hasBootstrapped = false
    private var hasBoundFixtureModels: Set<UInt16> = []
    /// Periodically polls fixtures for their live state while connected.
    private var statusPoller: Task<Void, Never>?

    init() {
        manager = MeshNetworkManager()
        manager.networkParameters = .basic { p in
            p.setDefaultTtl(5)
        }
        manager.logger = OSLogMeshLogger.shared
        Log.app.info("MeshController initialised")
    }

    /// Loads an existing mesh from local storage, or imports from amaran.db
    /// on first launch. Idempotent — safe to call from `.onAppear` etc; we
    /// only actually run the wiring once per process.
    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        Log.app.notice("bootstrap()")
        do {
            if try manager.load(), manager.meshNetwork != nil {
                Log.app.info("Loaded mesh network from local storage")
                rebuildFixtureModels()
            } else {
                Log.app.info("No saved network — importing from amaran.db")
                try performFirstLaunchImport()
            }
            try ensureLocalProvisionerAddress()
            // localElements must be set even if empty so the standard models
            // (Configuration Client, Health Client) get installed.
            manager.localElements = []
            manager.delegate = self
            _ = manager.save()
            if let net = manager.meshNetwork {
                Log.app.notice("Mesh ready: \(net.nodes.count, privacy: .public) nodes, \(self.fixtures.count, privacy: .public) fixtures, local provisioner at \(String(format: "0x%04X", net.localProvisioner?.primaryUnicastAddress ?? 0), privacy: .public)")
            }
            startConnection()
        } catch {
            Log.app.error("bootstrap failed: \(error.localizedDescription, privacy: .public)")
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connectionState = .error(importError ?? "Unknown error")
        }
    }

    func shutdown() {
        statusPoller?.cancel()
        statusPoller = nil
        connection?.close()
        connection = nil
    }

    // MARK: - Public commands

    // Verge bicolour range, used to map the 0..1 slider to a real Kelvin.
    private static let kelvinMin = 2700
    private static let kelvinMax = 6500

    /// Slider 0 = warm icon side = lowest Kelvin (2700K).
    /// Slider 1 = cool icon side = highest Kelvin (6500K).
    nonisolated static func kelvin(forSlider slider: Double) -> Int {
        let s = max(0.0, min(1.0, slider))
        return Int(round(Double(kelvinMin) + s * Double(kelvinMax - kelvinMin)))
    }

    /// Inverse of `kelvin(forSlider:)` — maps a fixture-reported Kelvin back to
    /// the 0…1 slider position so incoming status can drive the CCT slider.
    nonisolated static func slider(forKelvin kelvin: Int) -> Double {
        let span = Double(kelvinMax - kelvinMin)
        guard span > 0 else { return 0 }
        return max(0.0, min(1.0, (Double(kelvin) - Double(kelvinMin)) / span))
    }

    nonisolated static func intensity(forLightness lightness: Double) -> Int {
        Int(round(max(0.0, min(1.0, lightness)) * 1000))
    }

    func setOnOff(_ fixture: FixtureViewModel, isOn: Bool) {
        fixture.isOn = isOn
        let address = fixture.unicastAddress
        publishState(address: address, isOn: isOn)
        // Snapshot brightness/CCT so we can re-apply them after turning on.
        let intensity = Self.intensity(forLightness: fixture.lightness)
        let kelvin = Self.kelvin(forSlider: fixture.temperature)
        debounce(key: "onoff-\(address)") { [weak self] in
            guard let self else { return }
            await self.send(AputureVendorMessage.onOff(isOn), to: address)
            if isOn {
                // Let the firmware finish its on-transition, then push CCT
                // and brightness so the on-state matches the UI sliders.
                try? await Task.sleep(nanoseconds: 120_000_000)
                await self.send(AputureVendorMessage.ctl(kelvin: kelvin, intensity: intensity), to: address)
                await self.send(AputureVendorMessage.brightness(intensity: intensity), to: address)
            }
            // Reconcile against the fixture's real state once it settles.
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.requestStatus(address: address)
        }
    }

    func setLightness(_ fixture: FixtureViewModel, lightness: Double) {
        let clamped = max(0.0, min(1.0, lightness))
        fixture.lightness = clamped
        // While the light is off, treat slider moves as staged values. They
        // get re-applied when the user turns the light back on (in setOnOff).
        // Sending a brightness packet with intensity > 0 here would race the
        // OnOff(false) command and end up turning the light back on while
        // the toggle still says off.
        guard fixture.isOn else { return }
        let intensity = Self.intensity(forLightness: clamped)
        let address = fixture.unicastAddress
        debounce(key: "light-\(address)") { [weak self] in
            guard let self else { return }
            await self.send(AputureVendorMessage.brightness(intensity: intensity), to: address)
        }
    }

    func setTemperature(_ fixture: FixtureViewModel, slider: Double) {
        let clamped = max(0.0, min(1.0, slider))
        fixture.temperature = clamped
        guard fixture.isOn else { return }
        let kelvin = Self.kelvin(forSlider: clamped)
        let intensity = Self.intensity(forLightness: fixture.lightness)
        let address = fixture.unicastAddress
        debounce(key: "cct-\(address)") { [weak self] in
            guard let self else { return }
            await self.send(AputureVendorMessage.ctl(kelvin: kelvin, intensity: intensity), to: address)
        }
    }

    /// Pull each fixture's true state over the Telink vendor status channel and
    /// re-publish to the menu bar + Control Center. The fixture's SIG Generic
    /// OnOff Server is useless here (it always reports "on"), but a vendor
    /// status request (sub-opcode 0x0E) makes the fixture report its real
    /// on/off, brightness, and CCT — including changes made by another app or a
    /// physical control. Replies arrive asynchronously in
    /// `handle(message:source:)`.
    func refreshAllState() {
        publishSharedSnapshot()
        Task { await pollStatus() }
    }

    /// Ask one fixture to report its live state.
    func requestStatus(address: UInt16) async {
        await send(AputureVendorMessage.statusRequest(), to: address)
    }

    /// Ask every fixture to report its live state.
    func pollStatus() async {
        for fixture in fixtures {
            await requestStatus(address: fixture.unicastAddress)
        }
    }

    /// While connected, periodically refresh live state so the UI tracks
    /// changes made outside the app (physical knob, official app, etc.).
    private func startStatusPolling() {
        statusPoller?.cancel()
        statusPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard !Task.isCancelled else { break }
                await self?.pollStatus()
            }
        }
    }

    /// True while the user is actively driving a control on this fixture, so an
    /// incoming poll won't fight a live slider drag.
    private func hasPendingControl(address: UInt16) -> Bool {
        sendDebouncers["light-\(address)"] != nil ||
        sendDebouncers["cct-\(address)"] != nil ||
        sendDebouncers["onoff-\(address)"] != nil
    }

    // MARK: - Control Center bridge

    /// Publish the full roster + current on/off state into the App Group
    /// container and refresh the control. Cheap; call whenever fixtures change.
    func publishSharedSnapshot() {
        SharedStore.writeRoster(fixtures.map { .init(address: Int($0.unicastAddress), name: $0.name) })
        SharedStore.writeStates(Dictionary(uniqueKeysWithValues:
            fixtures.map { (String($0.unicastAddress), $0.isOn) }))
        SharedStore.reloadControls()
    }

    private func publishState(address: UInt16, isOn: Bool) {
        SharedStore.writeState(address: Int(address), isOn: isOn)
        SharedStore.reloadControls()
    }

    /// Bind our primary AppKey to a list of (modelId, optional companyId) on
    /// the fixture's primary element. Sequential, since each bind is acked.
    func bindModels(on fixture: FixtureViewModel,
                    sigModels: [UInt16],
                    vendorModels: [(company: UInt16, id: UInt16)]) async {
        guard let network = manager.meshNetwork,
              let node = network.node(withAddress: fixture.unicastAddress),
              let appKey = network.applicationKeys.first,
              let element = node.elements.first else {
            Log.send.error("bindModels: missing node/element/key")
            return
        }
        for modelId in sigModels {
            guard let model = element.models.first(where: { $0.modelIdentifier == modelId && $0.companyIdentifier == nil }) else {
                Log.send.error("bindModels: SIG model \(String(format: "0x%04X", modelId), privacy: .public) not in node entry — skipping")
                continue
            }
            await bind(appKey: appKey, to: model, label: String(format: "SIG 0x%04X", modelId))
        }
        for (company, id) in vendorModels {
            guard let model = element.models.first(where: { $0.modelIdentifier == id && $0.companyIdentifier == company }) else {
                Log.send.error("bindModels: vendor model \(String(format: "%04X/%04X", company, id), privacy: .public) not in node entry — skipping")
                continue
            }
            await bind(appKey: appKey, to: model, label: String(format: "vendor %04X/%04X", company, id))
        }
    }

    private func bind(appKey: ApplicationKey, to model: Model, label: String) async {
        guard let bind = ConfigModelAppBind(applicationKey: appKey, to: model) else {
            Log.send.error("bindModels: failed to build ConfigModelAppBind for \(label, privacy: .public)")
            return
        }
        let elementAddress = model.parentElement?.unicastAddress ?? 0
        Log.send.notice("→ ConfigModelAppBind \(label, privacy: .public) on element \(String(format: "0x%04X", elementAddress), privacy: .public)")
        do {
            let response = try await manager.send(bind, to: elementAddress)
            let desc = String(describing: response)
            Log.recv.notice("← \(desc, privacy: .public)")
        } catch {
            Log.send.error("bind \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internals

    private func performFirstLaunchImport() throws {
        let imported = try MeshImporter.importFromDesktopApp()
        _ = try manager.import(from: imported.json)
        rebuildFixtureModels()
    }

    private func ensureLocalProvisionerAddress() throws {
        guard let network = manager.meshNetwork,
              let local = network.localProvisioner else { return }
        if local.node == nil {
            // First allocated unicast in the provisioner's range.
            try network.assign(unicastAddress: 0x0100, for: local)
        }
    }

    private func rebuildFixtureModels() {
        guard let network = manager.meshNetwork else { return }
        var models: [FixtureViewModel] = []
        var byAddress: [UInt16: FixtureViewModel] = [:]
        for node in network.nodes where !node.isLocalProvisioner {
            let address = node.primaryUnicastAddress
            let fixture = MeshImporter.Fixture(
                uuid: node.uuid,
                unicastAddress: address,
                name: node.name ?? "Light \(String(format: "0x%04X", address))",
                productCode: "",
                macAddress: ""
            )
            let model = FixtureViewModel(fixture)
            models.append(model)
            byAddress[address] = model
        }
        self.fixtures = models.sorted { $0.unicastAddress < $1.unicastAddress }
        self.fixtureByAddress = byAddress
        // Seed on/off from the last-known state (persisted in the shared
        // container) so the UI has something to show immediately on launch.
        // Once the bearer connects we poll the fixtures for their true state
        // (see refreshAllState / handle(message:source:)), which then takes over.
        for fixture in self.fixtures {
            fixture.isOn = SharedStore.readState(address: Int(fixture.unicastAddress))
        }
        publishSharedSnapshot()
    }

    private func startConnection() {
        guard let network = manager.meshNetwork else { return }
        connection?.close()
        let conn = NetworkConnection(to: network, owner: self)
        conn.dataDelegate = manager
        conn.logger = OSLogMeshLogger.shared
        manager.transmitter = conn
        self.connection = conn
        conn.open()
        connectionState = .scanning
        Log.scanner.notice("startConnection — beginning scan for Mesh Proxy service 1828")
    }

    private func send(_ message: MeshMessage, to unicast: UInt16) async {
        guard let network = manager.meshNetwork,
              let appKey = network.applicationKeys.first else { return }
        let typeName = String(describing: type(of: message))
        let addr = String(format: "0x%04X", unicast)
        guard connection?.isOpen == true else {
            Log.send.info("queued \(typeName, privacy: .public) → \(addr, privacy: .public) (bearer closed, scanning)")
            return
        }
        Log.send.info("→ \(typeName, privacy: .public) \(addr, privacy: .public)")
        do {
            try await manager.send(message,
                                   to: MeshAddress(unicast),
                                   using: appKey)
        } catch {
            Log.send.error("send error \(typeName, privacy: .public) → \(addr, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Trailing debouncer: schedule the action after `delay`; if the caller
    /// fires again before the delay elapses, the prior task is cancelled and
    /// only the most recent value is sent. Short delay (60 ms) keeps drags
    /// feeling responsive without spamming the bearer.
    private func debounce(key: String, _ action: @escaping @Sendable () async -> Void) {
        sendDebouncers[key]?.cancel()
        sendDebouncers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms
            guard !Task.isCancelled else { return }
            await action()
            self?.sendDebouncers.removeValue(forKey: key)
        }
    }

    // Called by NetworkConnection back into us.
    fileprivate func proxyDidConnect(name: String?) {
        connectionState = .ready(proxyName: name ?? "Mesh proxy")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            // The Verge sends its vendor status replies to addresses we don't
            // own (0xC000, and 0x0001 — the Aputure app's hardcoded unicast),
            // so we must receive traffic to those too. Use a *reject* filter
            // with an empty list, i.e. "forward everything", instead of adding
            // specific addresses to an accept list: the Verge reports a smaller
            // Proxy Filter list size than requested, which makes NordicMesh's
            // AddAddressesToFilter handler compute a negative `prefix` length
            // and trap, crashing the whole app on (re)connect.
            manager.proxyFilter.setType(.rejectList)
            await rebindIfNeeded()
            // Pull live state now, then keep it fresh on a timer.
            await pollStatus()
            startStatusPolling()
        }
    }

    /// After a factory-reset re-pair the Verge's AppKey bindings may not
    /// include our AppKey for the models we use. Idempotent: SUCCESS or
    /// AlreadyBound both leave us in the right state. We do this once per
    /// fixture per process; subsequent reconnects skip it.
    @MainActor
    private func rebindIfNeeded() async {
        for fixture in fixtures where !hasBoundFixtureModels.contains(fixture.unicastAddress) {
            await bindModels(on: fixture,
                             sigModels: [0x1000],
                             vendorModels: [(company: 0x0211, id: 0x0000)])
            hasBoundFixtureModels.insert(fixture.unicastAddress)
        }
    }

    fileprivate func proxyConnecting(name: String?) {
        connectionState = .connecting(name: name ?? "Mesh proxy")
    }

    fileprivate func proxyDidDisconnect() {
        statusPoller?.cancel()
        statusPoller = nil
        connectionState = .scanning
    }

    fileprivate func bluetoothUnavailable() {
        connectionState = .noBluetooth
    }
}

// MARK: - Incoming status messages

extension MeshController: MeshNetworkDelegate {
    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                        didReceiveMessage message: any MeshMessage,
                                        sentFrom source: Address,
                                        to destination: MeshAddress) {
        Task { @MainActor in
            await handle(message: message, source: source)
        }
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                        didSendMessage message: any MeshMessage,
                                        from localElement: Element,
                                        to destination: MeshAddress) {}

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                        failedToSendMessage message: any MeshMessage,
                                        from localElement: Element,
                                        to destination: MeshAddress,
                                        error: any Error) {
        let typeName = String(describing: type(of: message))
        Log.send.error("manager reported send failure for \(typeName, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    @MainActor
    private func handle(message: any MeshMessage, source: Address) async {
        // We only care about Telink vendor status reports (opcode 0x26). They
        // arrive as `UnknownMessage` because no local model decodes 0x26, and
        // they're addressed to the official app's provisioner unicast (0x0001),
        // not to us — but NordicMesh still delivers them to this global delegate
        // (the destination filter only gates per-model callbacks). The SIG
        // Generic OnOff Server is ignored on purpose: it always reports "on".
        guard message.opCode == AputureVendorMessage.opCode,
              let payload = message.parameters,
              let status = AputureVendorMessage.decodeStatus(payload) else { return }
        guard let fixture = fixtureByAddress[source] else {
            Log.recv.debug("vendor status from unknown source \(String(format: "0x%04X", source), privacy: .public)")
            return
        }

        let detail = status.mode == .cct
            ? "cct=\(status.kelvin)K"
            : "hsi=\(status.hue)°/\(status.saturation)%"
        Log.recv.notice("⟵ status \(fixture.name, privacy: .public): on=\(status.isOn, privacy: .public) intensity=\(status.intensity, privacy: .public) \(detail, privacy: .public) (cmd 0x\(String(format: "%02X", status.commandType), privacy: .public))")

        fixture.lastStatus = Date()
        let onChanged = fixture.isOn != status.isOn
        fixture.isOn = status.isOn

        // Fold brightness/CCT back into the sliders only when the user isn't
        // mid-adjustment on this fixture, so a poll can't yank a live drag.
        if status.isOn, !hasPendingControl(address: source) {
            fixture.lightness = Double(status.intensity) / 1000.0
            if status.mode == .cct {
                fixture.temperature = Self.slider(forKelvin: status.kelvin)
            }
        }

        if onChanged { publishState(address: source, isOn: status.isOn) }
    }
}

// MARK: - Network connection (scanning + GATT proxy bearer aggregator)

/// Lifted directly from the nRF Mesh example app and adapted: scans for
/// peripherals advertising the Mesh Proxy service (0x1828), matches the
/// advertisement to our network identity, and hands the peripheral to a
/// GattBearer instance. The first connected bearer is used as the transmitter.
final class NetworkConnection: NSObject, Bearer {
    static let maxConnections = 1

    let centralManager: CBCentralManager
    let meshNetwork: MeshNetwork
    var proxies: [GattBearer] = []
    var isOpen: Bool = false

    weak var delegate: BearerDelegate?
    weak var dataDelegate: BearerDataDelegate?
    weak var logger: LoggerDelegate?

    var supportedPduTypes: PduTypes {
        [.networkPdu, .meshBeacon, .proxyConfiguration]
    }

    private var isStarted: Bool = false
    private weak var owner: MeshController?
    private var diagnosticTimer: Timer?
    private var sawAnyAdvertisement: Bool = false

    init(to meshNetwork: MeshNetwork, owner: MeshController) {
        self.centralManager = CBCentralManager()
        self.meshNetwork = meshNetwork
        self.owner = owner
        super.init()
        centralManager.delegate = self
    }

    func open() {
        Log.scanner.notice("NetworkConnection.open (cb state \(self.centralManager.state.rawValue, privacy: .public))")
        if !isStarted, centralManager.state == .poweredOn {
            Log.scanner.notice("starting scan for service 0x1828")
            centralManager.scanForPeripherals(
                withServices: [MeshProxyService.uuid],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            armDiagnosticFallback()
        }
        isStarted = true
    }

    func close() {
        Log.scanner.notice("NetworkConnection.close")
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        centralManager.stopScan()
        proxies.forEach { $0.close() }
        proxies.removeAll()
        isStarted = false
        isOpen = false
    }

    /// If we don't see a mesh proxy advertisement within 12s, switch to an
    /// unfiltered scan for 8s and log every peripheral we see. This helps
    /// diagnose "nothing showing up" cases — e.g. the official Aputure app
    /// holding the proxy connection so the Verge stops advertising.
    private func armDiagnosticFallback() {
        diagnosticTimer?.invalidate()
        sawAnyAdvertisement = false
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.isStarted, self.proxies.isEmpty else { return }
            Log.scanner.warning("no mesh proxy seen in 12s — switching to unfiltered diagnostic scan for 8s")
            self.centralManager.stopScan()
            self.centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                guard let self, self.isStarted, self.proxies.isEmpty else { return }
                Log.scanner.warning("diagnostic scan done — back to filtered scan for service 0x1828")
                self.centralManager.stopScan()
                self.centralManager.scanForPeripherals(
                    withServices: [MeshProxyService.uuid],
                    options: nil
                )
            }
        }
    }

    func send(_ data: Data, ofType type: PduType) throws {
        var success = false
        var lastError: Error = BearerError.bearerClosed
        for proxy in proxies where proxy.isOpen {
            do {
                try proxy.send(data, ofType: type)
                success = true
            } catch {
                lastError = error
            }
        }
        if !success { throw lastError }
    }

    private func use(proxy bearer: GattBearer) {
        guard !proxies.contains(where: { $0.identifier == bearer.identifier }) else {
            Log.bearer.debug("ignoring duplicate proxy \(bearer.identifier.uuidString, privacy: .public)")
            return
        }
        if proxies.count >= Self.maxConnections {
            proxies.last?.close()
        }
        bearer.delegate = self
        bearer.dataDelegate = self
        bearer.logger = logger
        proxies.append(bearer)
        Log.bearer.notice("opening GATT bearer to \(bearer.identifier.uuidString, privacy: .public)")
        Task { @MainActor [weak owner] in owner?.proxyConnecting(name: bearer.name) }
        if bearer.isOpen {
            bearerDidOpen(self)
        } else {
            bearer.open()
        }
        if proxies.count >= Self.maxConnections {
            centralManager.stopScan()
            Log.scanner.notice("scan stopped (max connections reached)")
        }
    }
}

extension NetworkConnection: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.scanner.notice("CB state → \(central.state.rawValue, privacy: .public)")
        switch central.state {
        case .poweredOn:
            if isStarted, proxies.count < Self.maxConnections {
                Log.scanner.notice("CB powered on, (re)starting scan")
                central.scanForPeripherals(withServices: [MeshProxyService.uuid], options: nil)
            }
        case .poweredOff, .resetting, .unauthorized, .unsupported:
            Log.scanner.warning("CB unavailable (state \(central.state.rawValue, privacy: .public)), tearing down")
            proxies.forEach { $0.close() }
            proxies.removeAll()
            Task { @MainActor [weak owner] in owner?.bluetoothUnavailable() }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        sawAnyAdvertisement = true
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "<unnamed>")
        let id = peripheral.identifier.uuidString
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString).joined(separator: ",") ?? "-"
        if let networkIdentity = advertisementData.networkIdentity {
            let kind = String(describing: type(of: networkIdentity))
            if meshNetwork.matches(networkIdentity: networkIdentity) {
                Log.scanner.notice("✓ proxy match (network-id, \(kind, privacy: .public)) — \(name, privacy: .public) [\(id, privacy: .public)] rssi=\(RSSI.intValue, privacy: .public)")
                use(proxy: GattBearer(target: peripheral))
            } else {
                Log.scanner.debug("× foreign network — \(name, privacy: .public) [\(id, privacy: .public)] (\(kind, privacy: .public))")
            }
        } else if let nodeIdentity = advertisementData.nodeIdentity {
            let kind = String(describing: type(of: nodeIdentity))
            if meshNetwork.matches(nodeIdentity: nodeIdentity) {
                Log.scanner.notice("✓ proxy match (node-id, \(kind, privacy: .public)) — \(name, privacy: .public) [\(id, privacy: .public)] rssi=\(RSSI.intValue, privacy: .public)")
                use(proxy: GattBearer(target: peripheral))
            } else {
                Log.scanner.debug("× foreign node-id — \(name, privacy: .public) [\(id, privacy: .public)] (\(kind, privacy: .public))")
            }
        } else {
            Log.scanner.debug("? no identity beacon — \(name, privacy: .public) [\(id, privacy: .public)] services=[\(services, privacy: .public)] rssi=\(RSSI.intValue, privacy: .public)")
        }
    }
}

extension NetworkConnection: GattBearerDelegate, BearerDataDelegate {
    func bearerDidConnect(_ bearer: any Bearer) {
        Log.bearer.notice("bearer connected (\((bearer as? GattBearer)?.name ?? "?", privacy: .public))")
    }

    func bearerDidDiscoverServices(_ bearer: any Bearer) {
        Log.bearer.notice("bearer discovered services")
    }

    func bearerDidOpen(_ bearer: any Bearer) {
        let name = (bearer as? GattBearer)?.name
        Log.bearer.notice("bearer OPEN (\(name ?? "?", privacy: .public))")
        guard !isOpen else { return }
        isOpen = true
        Task { @MainActor [weak owner] in owner?.proxyDidConnect(name: name) }
        delegate?.bearerDidOpen(self)
    }

    func bearer(_ bearer: any Bearer, didClose error: (any Error)?) {
        Log.bearer.warning("bearer CLOSE \(error?.localizedDescription ?? "no error", privacy: .public)")
        if let gatt = bearer as? GattBearer,
           let index = proxies.firstIndex(of: gatt) {
            proxies.remove(at: index)
        }
        if isStarted, proxies.count < Self.maxConnections,
           centralManager.state == .poweredOn {
            Log.scanner.notice("restarting scan after bearer close")
            centralManager.scanForPeripherals(withServices: [MeshProxyService.uuid], options: nil)
        }
        if proxies.isEmpty {
            isOpen = false
            Task { @MainActor [weak owner] in owner?.proxyDidDisconnect() }
            delegate?.bearer(self, didClose: nil)
        }
    }

    func bearer(_ bearer: any Bearer, didDeliverData data: Data, ofType type: PduType) {
        Log.recv.debug("bearer rx \(data.count, privacy: .public) bytes type=\(type.rawValue, privacy: .public)")
        dataDelegate?.bearer(self, didDeliverData: data, ofType: type)
    }
}
