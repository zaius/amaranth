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

