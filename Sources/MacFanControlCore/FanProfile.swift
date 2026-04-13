import Foundation

public struct FanRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sensorKey: String        // FourCC e.g. "TPMP"
    public var fanIndex: Int            // 0 or 1
    public var thresholdCelsius: Double  // trigger temp
    public var targetRPM: Double         // RPM when triggered
    public var isEnabled: Bool           // toggle without deleting

    public init(
        id: UUID = UUID(),
        sensorKey: String,
        fanIndex: Int,
        thresholdCelsius: Double,
        targetRPM: Double,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sensorKey = sensorKey
        self.fanIndex = fanIndex
        self.thresholdCelsius = thresholdCelsius
        self.targetRPM = targetRPM
        self.isEnabled = isEnabled
    }
}

public struct FanProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var rules: [FanRule]

    public init(id: UUID = UUID(), name: String, rules: [FanRule] = []) {
        self.id = id
        self.name = name
        self.rules = rules
    }
}
