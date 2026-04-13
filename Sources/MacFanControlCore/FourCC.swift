import Foundation
import SMCShim

/// Utilities for SMC FourCC keys (big-endian UInt32 of four ASCII chars).
public enum FourCC {
    /// Build a UInt32 key from a 4-char ASCII string. Traps on bad input
    /// so you get a clean crash during development instead of silent zero.
    public static func make(_ s: StaticString) -> UInt32 {
        let str = "\(s)"
        precondition(str.utf8.count == 4, "FourCC must be exactly 4 ASCII characters: \(str)")
        var result: UInt32 = 0
        for byte in str.utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    /// Build a UInt32 from a runtime string (e.g., enumerated from the SMC).
    public static func makeRuntime(_ s: String) -> UInt32? {
        guard s.utf8.count == 4 else { return nil }
        var result: UInt32 = 0
        for byte in s.utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    /// Decode a UInt32 key into its ASCII representation.
    public static func string(_ key: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((key >> 24) & 0xFF),
            UInt8((key >> 16) & 0xFF),
            UInt8((key >> 8) & 0xFF),
            UInt8(key & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}
