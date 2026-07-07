import Foundation

public enum Ident {
    /// RFC 9562 UUIDv7: 48-bit ms timestamp | ver 7 | 12 rand | var 10 | 62 rand.
    public static func uuidv7(nowMs: EpochMs) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ts = UInt64(nowMs)
        for i in 0..<6 { bytes[i] = UInt8((ts >> (8 * (5 - i))) & 0xff) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3f) | 0x80   // variant 10
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }
}
