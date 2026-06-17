import Foundation
import SQLite3

/// Reads the Aputure amaran Desktop SQLite database and converts the stored
/// mesh + fixture rows into a SIG Mesh Configuration Database (MCDB) JSON
/// document that NordicMesh's `MeshNetworkManager.import(from:)` accepts.
enum MeshImporter {

    struct ImportedNetwork {
        let json: Data
        let provisionerUUID: UUID
        let fixtures: [Fixture]
    }

    struct Fixture: Equatable {
        let uuid: UUID
        let unicastAddress: UInt16
        let name: String
        let productCode: String
        let macAddress: String
    }

    enum ImportError: Error, LocalizedError {
        case desktopAppDataNotFound
        case noMeshConfigured
        case sqliteFailed(String)
        case invalidRow(String)

        var errorDescription: String? {
            switch self {
            case .desktopAppDataNotFound:
                return "Could not find the amaran Desktop app's data folder. Open the amaran Desktop app once and pair your light, then relaunch Amaranth."
            case .noMeshConfigured:
                return "No mesh network is configured in the amaran Desktop app yet."
            case .sqliteFailed(let m): return "SQLite error: \(m)"
            case .invalidRow(let m): return "Invalid row in amaran.db: \(m)"
            }
        }
    }

    static func locateDesktopDatabase() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let supportRoot = home
            .appendingPathComponent("Library/Containers/com.sidus.amaran-desktop/Data/Library/Application Support/amaran Desktop", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: supportRoot,
                                                                        includingPropertiesForKeys: nil)
        else { return nil }
        for entry in entries where entry.lastPathComponent.hasSuffix("_secure_id") {
            let candidate = entry.appendingPathComponent("amaran.db")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func importFromDesktopApp() throws -> ImportedNetwork {
        guard let dbURL = locateDesktopDatabase() else { throw ImportError.desktopAppDataNotFound }
        return try importFromDatabase(at: dbURL)
    }

    static func importFromDatabase(at url: URL) throws -> ImportedNetwork {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ImportError.sqliteFailed("could not open \(url.path)")
        }
        defer { sqlite3_close(db) }

        let (netKey, appKey) = try readMeshKeys(db: db)
        let rows = try readFixtures(db: db)
        guard !rows.isEmpty else { throw ImportError.noMeshConfigured }

        let provisionerUUID = UUID()
        let meshUUID = UUID()
        let timestamp = ISO8601DateFormatter.amaranth.string(from: Date())

        var fixtures: [Fixture] = []
        var nodesJSON: [[String: Any]] = []

        for row in rows {
            let nodeUUID = normalizedNodeUUID(fromHex: row.deviceUUIDHex) ?? UUID()
            fixtures.append(Fixture(uuid: nodeUUID,
                                    unicastAddress: row.nodeAddress,
                                    name: row.name,
                                    productCode: row.code,
                                    macAddress: row.macAddress))
            nodesJSON.append(makeNodeJSON(uuid: nodeUUID,
                                          unicastAddress: row.nodeAddress,
                                          deviceKeyHex: row.deviceKey,
                                          name: row.name))
        }

        let json: [String: Any] = [
            "$schema": "http://json-schema.org/draft-04/schema#",
            "id": "https://www.bluetooth.com/specifications/specs/mesh-configuration-database-profile-1-0/",
            "version": "1.0.0",
            "meshUUID": meshUUID.uuidString,
            "meshName": "Amaranth (imported from amaran)",
            "timestamp": timestamp,
            "partial": false,
            "provisioners": [
                [
                    "UUID": provisionerUUID.uuidString,
                    "provisionerName": "Amaranth",
                    "allocatedUnicastRange": [["lowAddress": "0100", "highAddress": "01FF"]],
                    "allocatedGroupRange":   [["lowAddress": "C000", "highAddress": "C0FF"]],
                    "allocatedSceneRange":   [["firstScene": "0001", "lastScene": "00FF"]]
                ]
            ],
            "netKeys": [
                [
                    "name": "Primary Network Key",
                    "index": 0,
                    "phase": 0,
                    "key": netKey.uppercased(),
                    "minSecurity": "secure",
                    "timestamp": timestamp
                ]
            ],
            "appKeys": [
                [
                    "name": "Primary Application Key",
                    "index": 0,
                    "boundNetKey": 0,
                    "key": appKey.uppercased()
                ]
            ],
            "nodes": nodesJSON,
            "groups": [],
            "scenes": []
        ]

        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.sortedKeys, .prettyPrinted])
        return ImportedNetwork(json: data, provisionerUUID: provisionerUUID, fixtures: fixtures)
    }

    // MARK: - SQLite helpers

    private static func readMeshKeys(db: OpaquePointer) throws -> (netKey: String, appKey: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT net_key, app_key FROM mesh LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.sqliteFailed("prepare mesh select")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ImportError.noMeshConfigured }
        let net = String(cString: sqlite3_column_text(stmt, 0))
        let app = String(cString: sqlite3_column_text(stmt, 1))
        return (net, app)
    }

    private struct FixtureRow {
        let name: String
        let macAddress: String
        let code: String
        let deviceKey: String
        let deviceUUIDHex: String
        let nodeAddress: UInt16
    }

    private static func readFixtures(db: OpaquePointer) throws -> [FixtureRow] {
        var stmt: OpaquePointer?
        let sql = "SELECT name, mac_address, code, device_key, device_uuid, node_address FROM fixtures"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError.sqliteFailed("prepare fixtures select")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [FixtureRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name      = String(cString: sqlite3_column_text(stmt, 0))
            let mac       = String(cString: sqlite3_column_text(stmt, 1))
            let code      = String(cString: sqlite3_column_text(stmt, 2))
            let deviceKey = String(cString: sqlite3_column_text(stmt, 3))
            let devUUID   = String(cString: sqlite3_column_text(stmt, 4))
            let nodeAddr  = sqlite3_column_int(stmt, 5)
            guard nodeAddr > 0, nodeAddr <= 0x7FFF else {
                throw ImportError.invalidRow("node_address out of unicast range: \(nodeAddr)")
            }
            rows.append(FixtureRow(name: name,
                                   macAddress: mac,
                                   code: code,
                                   deviceKey: deviceKey,
                                   deviceUUIDHex: devUUID,
                                   nodeAddress: UInt16(nodeAddr)))
        }
        return rows
    }

    // MARK: - Node JSON

    private static func makeNodeJSON(uuid: UUID,
                                     unicastAddress: UInt16,
                                     deviceKeyHex: String,
                                     name: String) -> [String: Any] {
        // Composition data observed for the amaran Verge (from amaran-desktop's
        // device introspection): CID=0x0211 PID=0x0201 VID=0x3333 CRPL=0x0069,
        // single element with these SIG models + the Telink vendor model 0x0211/0x0000.
        // We synthesise the same model list so the library will let us bind the
        // application key to OnOff / Lightness and send addressed messages.
        let sigModelIds: [String] = [
            "0000", // Configuration Server
            "0002", // Health Server
            "0003", // Health Client
            "1000", // Generic OnOff Server
            "1002", // Generic Level Server
            "1004", // Generic Default Transition Time Server
            "1006", // Generic Power OnOff Server
            "1007", // Generic Power OnOff Setup Server
            "1300", // Light Lightness Server
            "1301"  // Light Lightness Setup Server
        ]
        let vendorModelIds: [String] = [
            "02110000" // Telink vendor (Aputure command channel, incl. CCT)
        ]

        // Configuration models (0x0000/0x0001) are not bound to AppKeys; everything
        // else gets the primary AppKey so we can send addressed traffic to them.
        let unboundSigModels: Set<String> = ["0000", "0001"]

        var models: [[String: Any]] = []
        for id in sigModelIds {
            models.append([
                "modelId": id,
                "subscribe": [],
                "bind": unboundSigModels.contains(id) ? [] : [0]
            ])
        }
        for id in vendorModelIds {
            models.append([
                "modelId": id,
                "subscribe": [],
                "bind": [0]
            ])
        }

        return [
            "UUID": uuid.uuidString,
            "unicastAddress": String(format: "%04X", unicastAddress),
            "deviceKey": deviceKeyHex.uppercased(),
            "security": "secure",
            "configComplete": true,
            "name": name,
            "cid": "0211",
            "pid": "0201",
            "vid": "3333",
            "crpl": "0069",
            "features": [
                "relay": 2,
                "proxy": 2,
                "friend": 2,
                "lowPower": 2
            ],
            "secureNetworkBeacon": true,
            "defaultTTL": 5,
            "netKeys": [["index": 0, "updated": false]],
            "appKeys": [["index": 0, "updated": false]],
            "elements": [
                [
                    "name": "Primary Element",
                    "index": 0,
                    "location": "0000",
                    "models": models
                ]
            ],
            "excluded": false
        ]
    }

    private static func normalizedNodeUUID(fromHex hex: String) -> UUID? {
        // The amaran DB stores the BLE Mesh Device UUID as raw 16-byte hex, e.g.
        // "34303059352D35343332463630306670". Convert it into the standard 8-4-4-4-12
        // dashed form that Swift's UUID parser accepts.
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        let bytes = stride(from: 0, to: 32, by: 1).map { hex[hex.index(hex.startIndex, offsetBy: $0)] }
        let formatted = String(bytes[0..<8]) + "-" +
                        String(bytes[8..<12]) + "-" +
                        String(bytes[12..<16]) + "-" +
                        String(bytes[16..<20]) + "-" +
                        String(bytes[20..<32])
        return UUID(uuidString: formatted)
    }
}

private extension ISO8601DateFormatter {
    static let amaranth: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private extension Character {
    var isHexDigit: Bool { isASCII && (isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self)) }
}
