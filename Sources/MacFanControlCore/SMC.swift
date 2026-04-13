import Foundation
import SMCShim

/// Swift wrapper around the C shim. A single process-wide SMC connection.
/// All methods are thread-safe via an internal lock.
public final class SMC: @unchecked Sendable {
    public static let shared = SMC()

    private let lock = NSLock()
    private var opened = false

    private init() {}

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        if opened { return }
        let rc = smc_open()
        if rc != 0 {
            throw SMCError.openFailed(rc: Int(rc))
        }
        opened = true
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if opened {
            smc_close()
            opened = false
        }
    }

    // MARK: - Reads

    /// Read a key and return its dataType + raw bytes.
    public func read(_ key: UInt32) -> (type: UInt32, data: [UInt8])? {
        lock.lock(); defer { lock.unlock() }
        var size: UInt32 = 0
        var type: UInt32 = 0
        var buf = [UInt8](repeating: 0, count: 32)
        let ok = buf.withUnsafeMutableBufferPointer { ptr -> Bool in
            smc_read_key(key, &size, &type, ptr.baseAddress)
        }
        guard ok, size > 0, size <= 32 else { return nil }
        return (type, Array(buf.prefix(Int(size))))
    }

    public func readFloat(_ key: UInt32) -> Float? {
        guard let (_, data) = read(key), data.count == 4 else { return nil }
        return data.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
        }
    }

    public func readUInt8(_ key: UInt32) -> UInt8? {
        guard let (_, data) = read(key), data.count == 1 else { return nil }
        return data[0]
    }

    /// Decode value as a Double, choosing a decoder based on dataType.
    public func readDouble(_ key: UInt32) -> Double? {
        guard let (type, data) = read(key) else { return nil }
        return decodeDouble(type: type, data: data)
    }

    public func decodeDouble(type: UInt32, data: [UInt8]) -> Double? {
        var out: Double = 0
        return data.withUnsafeBufferPointer { buf -> Double? in
            let base = buf.baseAddress
            let size = UInt32(data.count)
            switch type {
            case FourCC.make("flt "):
                if smc_decode_flt(base, size, &out) { return out }
            case FourCC.make("fpe2"):
                if smc_decode_fpe2(base, size, &out) { return out }
            case FourCC.make("sp78"):
                if smc_decode_sp78(base, size, &out) { return out }
            case FourCC.make("ui8 "), FourCC.make("ui16"), FourCC.make("ui32"):
                var u: UInt64 = 0
                if smc_decode_ui(base, size, &u) { return Double(u) }
            case FourCC.make("si8 "), FourCC.make("si16"), FourCC.make("si32"):
                var s: Int64 = 0
                if smc_decode_si(base, size, &s) { return Double(s) }
            default:
                return nil
            }
            return nil
        }
    }

    /// Enumerate every key's FourCC. Cached because it's expensive.
    public func listAllKeys() -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        let count = smc_key_count()
        guard count > 0 else { return [] }
        var result: [UInt32] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            let k = smc_key_at_index(i)
            if k != 0 { result.append(k) }
        }
        return result
    }

    // MARK: - Writes (require root)

    @discardableResult
    public func writeFloat(_ key: UInt32, _ value: Float) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return smc_write_flt(key, value)
    }

    @discardableResult
    public func writeUInt8(_ key: UInt32, _ value: UInt8) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return smc_write_u8(key, value)
    }
}

public enum SMCError: Error, CustomStringConvertible {
    case openFailed(rc: Int)
    case notOpen
    case readFailed(key: String)
    case writeFailed(key: String)

    public var description: String {
        switch self {
        case .openFailed(let rc):   return "SMC open failed (rc=\(rc))"
        case .notOpen:              return "SMC connection not open"
        case .readFailed(let key):  return "SMC read failed: \(key)"
        case .writeFailed(let key): return "SMC write failed: \(key)"
        }
    }
}
