import Foundation

public enum FanAction: Sendable, Equatable {
    case setRPM(Double)
    case auto
}

public struct HysteresisState: Sendable {
    /// Rule IDs that are currently "active" (triggered and haven't dropped below deadband).
    public var activeRuleIDs: Set<UUID>

    public init(activeRuleIDs: Set<UUID> = []) {
        self.activeRuleIDs = activeRuleIDs
    }
}

public enum ProfileEvaluator {

    /// Deadband in degrees C. A rule activates at threshold and deactivates
    /// only when the sensor drops below (threshold - deadband).
    public static let deadband: Double = 3.0

    /// Evaluate a profile against current sensor readings.
    ///
    /// Returns a dictionary of fan index -> action. Only fans that appear in
    /// at least one enabled rule are included. Fans with no triggered rules
    /// get `.auto`.
    ///
    /// - Parameters:
    ///   - profile: The active fan profile.
    ///   - sensorValues: Map of sensor FourCC key to current temperature in C.
    ///   - fanLimits: Map of fan index to (min, max) RPM for clamping.
    ///   - hysteresis: In/out hysteresis state tracking active rule IDs.
    /// - Returns: Per-fan actions to apply.
    public static func evaluate(
        profile: FanProfile,
        sensorValues: [String: Double],
        fanLimits: [Int: (min: Double, max: Double)],
        hysteresis: inout HysteresisState
    ) -> [Int: FanAction] {

        // Collect all fan indices mentioned by enabled rules.
        var mentionedFans = Set<Int>()
        // Per-fan max triggered RPM.
        var fanMaxRPM: [Int: Double] = [:]

        var newActiveIDs = Set<UUID>()

        for rule in profile.rules where rule.isEnabled {
            mentionedFans.insert(rule.fanIndex)

            guard let temp = sensorValues[rule.sensorKey] else {
                // Sensor not present — skip, don't activate.
                continue
            }

            let wasActive = hysteresis.activeRuleIDs.contains(rule.id)
            let isTriggered: Bool

            if wasActive {
                // Deactivate only when temp drops below threshold - deadband.
                isTriggered = temp >= (rule.thresholdCelsius - deadband)
            } else {
                // Activate when temp reaches threshold.
                isTriggered = temp >= rule.thresholdCelsius
            }

            if isTriggered {
                newActiveIDs.insert(rule.id)
                let existing = fanMaxRPM[rule.fanIndex] ?? 0
                fanMaxRPM[rule.fanIndex] = max(existing, rule.targetRPM)
            }
        }

        hysteresis.activeRuleIDs = newActiveIDs

        // Build result: triggered fans get max RPM (clamped), untriggered get auto.
        var result: [Int: FanAction] = [:]
        for fanIndex in mentionedFans {
            if let rpm = fanMaxRPM[fanIndex] {
                let clamped: Double
                if let limits = fanLimits[fanIndex] {
                    clamped = Swift.min(Swift.max(rpm, limits.min), limits.max)
                } else {
                    clamped = rpm
                }
                result[fanIndex] = .setRPM(clamped)
            } else {
                result[fanIndex] = .auto
            }
        }

        return result
    }
}
