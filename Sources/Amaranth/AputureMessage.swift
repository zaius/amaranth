import Foundation
import NordicMesh

/// Aputure / Telink proprietary vendor command sent to amaran lights.
///
/// Wire format reverse-engineered from the Telink SDK and confirmed against
/// the reference CLI at https://github.com/aarondfrancis/amaran (which is a
/// pure-Swift reimplementation of Telink's encoding). The packet is always
/// opcode 0x26 + a 10-byte payload structured as:
///
///   bytes 0..7  = little-endian 64-bit `low64`
///   bytes 8..9  = little-endian 16-bit `high16`
///   byte 0      = checksum (sum of bytes 1..9 mod 256, recomputed at the end)
///
/// The high byte of `high16` (= byte 9) is a sub-opcode that picks a command:
///   0x8C — Generic OnOff. high16 = 0x8C00 | (isOn ? 1 : 0).
///   0x8F — Brightness. Encodes 0..1000 intensity, split across low64 bit 62-63
///          and high16 low byte.
///   0x82 — Light CTL. Encodes both intensity AND a 10-bit `telinkCct = K/10`
///          (so 80..2000 ≈ 800K..20000K). For the amaran Verge the Kelvin range
///          is 2700..6500K.
///
/// Bits inside `low64`:
///   62..63 — intensity low 2 bits
///   52..61 — telinkCct low 10 bits (CCT mode only)
///   43     — gmFlag (G/M tint sign; we send 0)
///   45..51 — gm magnitude (we send 0)
///   42     — telinkCct overflow flag for telinkCct >= 1001 (not needed for Verge)
///
/// Bits inside `high16`:
///   9..15  — sub-opcode (0x8C/0x8F/0x82) and other static bits
///   0..7   — intensity middle 8 bits (= (intensity >> 2) & 0xFF)
///          + telinkCct high 0..8 bits OR'd into low byte (not needed for ≤ 6500K)
struct AputureVendorMessage: UnacknowledgedMeshMessage, StaticMeshMessage {
    static let opCode: UInt32 = 0x26
    let parameters: Data?

    init?(parameters: Data) {
        guard parameters.count == 10 else { return nil }
        self.parameters = parameters
    }
    init(payload: Data) {
        precondition(payload.count == 10, "Aputure payload must be 10 bytes")
        self.parameters = payload
    }

    /// Generic OnOff. Captured bytes: `8d…01 8c` (on), `8c…00 8c` (off).
    static func onOff(_ isOn: Bool) -> AputureVendorMessage {
        AputureVendorMessage(payload: Data(buildPacket(
            low64: 0,
            high16: 0x8C00 | UInt16(isOn ? 0x01 : 0x00)
        )))
    }

    /// Vendor "read data" request (sub-opcode 0x0E). Asks the fixture to report
    /// its live state; it replies with a status report (sub-opcode 0x02 CCT or
    /// 0x01 HSI) — see `decodeStatus`. The reply is addressed to the official
    /// app's provisioner unicast (0x0001), not to us, but we still receive it
    /// because the proxy filter forwards all traffic. See
    /// `MeshController.handle(message:source:)`.
    static func statusRequest() -> AputureVendorMessage {
        AputureVendorMessage(payload: Data(buildPacket(low64: 0, high16: 0x0E00)))
    }

    /// Brightness. `intensity` is 0…1000 (=0…100.0%).
    static func brightness(intensity: Int) -> AputureVendorMessage {
        let i = UInt64(max(0, min(1000, intensity)))
        let low64 = (i & 0x03) << 62
        let high16 = UInt16(0x8F00 | UInt16((i >> 2) & 0xFF))
        return AputureVendorMessage(payload: Data(buildPacket(low64: low64, high16: high16)))
    }

    /// Light CTL. `kelvin` 800…20000 (Verge supports 2700…6500). `intensity` 0…1000.
    static func ctl(kelvin: Int, intensity: Int) -> AputureVendorMessage {
        let telinkCct = max(80, min(2000, Int((Double(kelvin) / 10.0).rounded())))
        let i = UInt64(max(0, min(1000, intensity)))

        var low64: UInt64 = 0
        var high16: UInt16 = 0x8200

        low64 |= (i & 0x03) << 62
        high16 |= UInt16((i >> 2) & 0xFF)

        if telinkCct < 1001 {
            low64 |= UInt64(telinkCct) << 52
            high16 |= UInt16((telinkCct >> 12) & 0xFF)
        } else {
            low64 |= UInt64((telinkCct + 0x18) & 0x3FF) << 52
            low64 |= 0x0000_0400_0000_0000 // bit 42 = overflow flag
        }
        // gm=0, gmFlag=0 → no extra bits to OR in for the Verge.

        return AputureVendorMessage(payload: Data(buildPacket(low64: low64, high16: high16)))
    }

    private static func buildPacket(low64: UInt64, high16: UInt16) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        for i in 0..<8 {
            bytes[i] = UInt8((low64 >> (UInt64(i) * 8)) & 0xFF)
        }
        bytes[8] = UInt8(high16 & 0xFF)
        bytes[9] = UInt8((high16 >> 8) & 0xFF)
        bytes[0] = 0
        let checksum = bytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        bytes[0] = UInt8(checksum)
        return bytes
    }
}

// MARK: - Incoming status reports

extension AputureVendorMessage {

    /// A fixture's live state, decoded from an incoming Telink vendor status
    /// report. Fixtures emit these in reply to `statusRequest()` and also
    /// whenever their state changes from a physical control or another app —
    /// which is what lets us reflect the *true* state rather than the value we
    /// last commanded.
    struct Status: Equatable {
        enum Mode: Equatable { case cct, hsi }
        let isOn: Bool
        let mode: Mode
        /// 0…1000 (= 0…100.0%); valid in both modes.
        let intensity: Int
        /// Kelvin (CCT mode only; 0 in HSI mode).
        let kelvin: Int
        /// 0…360 hue (HSI mode only).
        let hue: Int
        /// 0…100 saturation (HSI mode only).
        let saturation: Int
        /// Raw command-type byte (`p[9] & 0x7F`), kept for diagnostics.
        let commandType: Int
    }

    /// Parse a 10-byte vendor payload as a *status report*, or return `nil` if
    /// it isn't one.
    ///
    /// Bit layout cross-checked against the two open-source reimplementations
    /// linked in the README: aarondfrancis/amaran (`decodePacket`) and
    /// wesbos/amaran-BLE-control (`decodeStatus`). On/off is `(low64 >> 8) & 1`
    /// (Wes Bos confirmed this against live hardware as two-way sync; the
    /// amaran CLI calls the same bit `sleep_mode`).
    ///
    /// Returns `nil` for: a bad checksum; a "set" packet (operaType / high bit
    /// of byte 9 set — i.e. an echo of one of our own on/off, brightness, or
    /// CTL commands, which matters because a CTL Set's byte 9 0x82 would
    /// otherwise alias the CCT report type 0x02); or a command-type we don't
    /// model (e.g. the constant 0x0A diagnostic page the desktop app polls).
    static func decodeStatus(_ payload: Data) -> Status? {
        let bytes = [UInt8](payload)
        guard bytes.count == 10 else { return nil }
        // Checksum: byte 0 = sum(bytes 1…9) mod 256.
        let expected = UInt8(bytes[1...].reduce(0) { ($0 + Int($1)) & 0xFF })
        guard bytes[0] == expected else { return nil }

        let byte9 = bytes[9]
        // Reports have the operaType (top) bit clear; our outgoing Set commands
        // (0x8C/0x8F/0x82) have it set.
        guard byte9 & 0x80 == 0 else { return nil }
        let commandType = Int(byte9 & 0x7F)

        var low64: UInt64 = 0
        for i in 0..<8 { low64 |= UInt64(bytes[i]) << (UInt64(i) * 8) }
        let high16 = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)

        let isOn = (low64 >> 8) & 0x1 == 1
        // Intensity packing is identical in both modes; the command-type bits in
        // the high byte fall outside the 10-bit field and are masked off.
        let intensity = (Int(high16) << 2 | Int((low64 >> 62) & 0x3)) & 0x3FF

        switch commandType {
        case 0x02: // CCT
            let cctRaw = Int((low64 >> 52) & 0x3FF)
            let cctFlag = Int((low64 >> 42) & 0x1)
            let telinkCct = cctFlag == 1 ? cctRaw + 1000 : cctRaw // = Kelvin / 10
            return Status(isOn: isOn, mode: .cct, intensity: intensity,
                          kelvin: telinkCct * 10, hue: 0, saturation: 0,
                          commandType: commandType)
        case 0x01: // HSI / colour
            var sat = (Int(bytes[6] & 0x1F) << 2) | Int((bytes[5] >> 6) & 0x3)
            var hue = (Int(bytes[7] & 0x3F) << 3) | Int((bytes[6] >> 5) & 0x7)
            if sat > 100 { sat = 100 }
            if hue > 360 { hue = 360 }
            return Status(isOn: isOn, mode: .hsi, intensity: intensity,
                          kelvin: 0, hue: hue, saturation: sat,
                          commandType: commandType)
        default:
            return nil // 0x0A diagnostic page or unknown
        }
    }
}

