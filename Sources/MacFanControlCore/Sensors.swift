import Foundation

/// A single temperature sensor reading.
public struct SensorReading: Sendable, Hashable, Codable {
    public let key: String      // FourCC as ASCII ("TPMP")
    public let label: String    // Friendly name if known, else the key
    public let category: SensorCategory
    public let celsius: Double
    public let isFeatured: Bool // true if in the curated name map

    public init(key: String, label: String, category: SensorCategory,
                celsius: Double, isFeatured: Bool) {
        self.key = key
        self.label = label
        self.category = category
        self.celsius = celsius
        self.isFeatured = isFeatured
    }
}

public enum SensorCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case cpu
    case gpu
    case memory
    case battery
    case chassis
    case power
    case other

    public var displayName: String {
        switch self {
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        case .memory:  return "Storage / Memory"
        case .battery: return "Battery"
        case .chassis: return "Chassis"
        case .power:   return "Power"
        case .other:   return "Other"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .cpu:     return 0
        case .gpu:     return 1
        case .memory:  return 2
        case .battery: return 3
        case .chassis: return 4
        case .power:   return 5
        case .other:   return 6
        }
    }
}

/// Enumerates T-prefix SMC keys and produces SensorReading values.
public final class SensorReader {
    private let smc: SMC
    private var keyCache: [UInt32]?

    public init(smc: SMC = .shared) {
        self.smc = smc
    }

    /// Collect all currently-readable temperature sensors.
    public func readAll() -> [SensorReading] {
        let keys = keyCache ?? smc.listAllKeys()
        keyCache = keys

        var readings: [SensorReading] = []
        readings.reserveCapacity(350)

        for key in keys {
            let name = FourCC.string(key)
            guard name.hasPrefix("T") else { continue }
            guard let (type, data) = smc.read(key) else { continue }
            guard let celsius = smc.decodeDouble(type: type, data: data) else { continue }
            // Skip implausible values.
            guard celsius > -20, celsius < 125 else { continue }
            // Skip exact zeros ("not reporting").
            if celsius == 0 { continue }

            let (label, category, featured) = Self.metadata(for: name)
            readings.append(
                SensorReading(
                    key: name,
                    label: label,
                    category: category,
                    celsius: celsius,
                    isFeatured: featured
                )
            )
        }

        readings.sort { lhs, rhs in
            // Featured first, then by category, then by label.
            if lhs.isFeatured != rhs.isFeatured { return lhs.isFeatured }
            if lhs.category != rhs.category {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            return lhs.label < rhs.label
        }
        return readings
    }

    // MARK: - Key metadata

    /// (label, category, isFeatured) for a given key. Featured entries
    /// come from a hand-curated list of the most useful Apple Silicon
    /// SMC sensors — the ones we can confidently label.
    static func metadata(for key: String) -> (String, SensorCategory, Bool) {
        if let entry = featuredMap[key] {
            return (entry.0, entry.1, true)
        }
        return (key, categoryHeuristic(for: key), false)
    }

    /// Curated Apple Silicon sensor map. Labels are best-effort based on
    /// SMC naming conventions and were cross-checked against real M-series
    /// key dumps. Entries that aren't present on a given machine simply
    /// get skipped.
    static let featuredMap: [String: (String, SensorCategory)] = [
        // ---- Battery ----
        "TB0T": ("Battery cell 1",           .battery),
        "TB1T": ("Battery cell 2",           .battery),
        "TB2T": ("Battery cell 3",           .battery),
        "TBAT": ("Battery ambient",          .battery),
        "TBXT": ("Battery max",              .battery),

        // ---- SSD / NAND ----
        "TH0a": ("SSD controller",           .memory),
        "TH0b": ("SSD flash B",              .memory),
        "TH0c": ("SSD flash C",              .memory),
        "TH0x": ("SSD flash X",              .memory),
        "TH1a": ("SSD 2 controller",         .memory),
        "TH1b": ("SSD 2 flash B",            .memory),
        "TH1x": ("SSD 2 flash X",            .memory),

        // ---- CPU (package-level) ----
        "TCHP": ("CPU (high power)",         .cpu),
        "TCDX": ("CPU die",                  .cpu),
        "TCMb": ("CPU motherboard",          .cpu),
        "TCXC": ("CPU cluster",              .cpu),
        "TCSC": ("CPU skin",                 .cpu),
        "TC0P": ("CPU proximity",            .cpu),
        "TC0D": ("CPU die (D)",              .cpu),
        "TCAD": ("CPU ambient",              .cpu),
        "TCGC": ("CPU integrated GPU",       .cpu),

        // ---- GPU (package-level) ----
        "TG0D": ("GPU die",                  .gpu),
        "TG0P": ("GPU proximity",            .gpu),
        "TG1D": ("GPU die 2",                .gpu),
        "TG1P": ("GPU proximity 2",          .gpu),
        "TGDD": ("GPU DMA",                  .gpu),

        // ---- Memory ----
        "TM0P": ("Memory proximity",         .memory),
        "TM0p": ("Memory bank",              .memory),
        "TmMP": ("Memory module",            .memory),
        "TPMP": ("Platform memory",          .memory),

        // ---- Chassis / Ambient / Airport ----
        "TaLP": ("Airport (left)",           .chassis),
        "TaRP": ("Airport (right)",          .chassis),
        "TaRF": ("Airport (right, front)",   .chassis),
        "TaLT": ("Ambient (left top)",       .chassis),
        "TaRT": ("Ambient (right top)",      .chassis),
        "TaLW": ("WiFi area (left)",         .chassis),
        "TaRW": ("WiFi area (right)",        .chassis),
        "TaTP": ("Ambient (top)",            .chassis),
        "TAOL": ("Ambient overall",          .chassis),
        "TW0P": ("WiFi module",              .chassis),
        "Ts0P": ("Palm rest",                .chassis),
        "Ts1P": ("Top case",                 .chassis),
        "TS0P": ("Trackpad area",            .chassis),
        "Ts0S": ("Bottom skin",              .chassis),
        "TsMP": ("Speaker area",             .chassis),

        // ---- Power / VRMs ----
        "TMVR": ("Memory VR",                .power),
        "TSVR": ("System VR",                .power),
        "TSWR": ("Switching VR",             .power),
        "TSXR": ("Aux VR",                   .power),
        "TVDG": ("GPU voltage",              .power),
        "TVDM": ("Memory voltage",           .power),
        "TVDP": ("Platform voltage",         .power),
        "TVDA": ("Analog voltage",           .power),
        "TVDc": ("CPU voltage",              .power),
    ]

    // MARK: - Fallback heuristic for unknown keys

    static func categoryHeuristic(for key: String) -> SensorCategory {
        guard key.count == 4, key.hasPrefix("T") else { return .other }
        let second = key[key.index(key.startIndex, offsetBy: 1)]
        switch second {
        case "p", "P":  return .cpu           // Tp.. perf cores, TP.. platform
        case "e", "E":  return .cpu           // Te.. efficiency cores
        case "C":       return .cpu
        case "c":       return .cpu
        case "g", "G":  return .gpu           // Tg.. GPU cores, TG.. GPU die
        case "m", "M":  return .memory        // Tm.. memory
        case "N":       return .memory        // NAND
        case "H", "h":  return .memory        // Hard drive / NAND
        case "B":       return .battery
        case "s", "S":  return .chassis       // Ts.. skin
        case "a", "A":  return .chassis       // Ta.. ambient/airport
        case "W":       return .chassis       // Wireless
        case "V", "v":  return .power         // Voltage rails
        case "R", "r":  return .power         // Regulators
        case "D", "d":  return .other         // Die diagnostics vary
        case "f", "F":  return .other         // Flow/fan related
        default:        return .other
        }
    }
}
