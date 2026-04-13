import Foundation
import Combine
import MacFanControlCore

/// Top-level observable view model. Polls the local SMC for sensor/fan
/// readings (read-only, no root) every second, and polls the helper for
/// override state on the same cadence.
@MainActor
final class DashboardViewModel: ObservableObject {

    @Published var sensors: [SensorReading] = []
    @Published var fans: [FanReading] = []
    @Published var overrides: [Int: FanOverrideState] = [:]
    @Published var installStatus: HelperInstallStatus = .unknown
    @Published var smcOpenError: String?
    @Published var hasTakenControl: Bool = false
    @Published var fanReadingsValid: Bool = true
    @Published var lastError: String?
    @Published var isInstalling: Bool = false
    /// When false, only sensors in the curated friendly-name map are shown.
    @Published var showAllSensors: Bool = false
    /// True when the active profile is being evaluated each tick.
    @Published var profileActive: Bool = false

    var visibleSensors: [SensorReading] {
        showAllSensors ? sensors : sensors.filter { $0.isFeatured }
    }

    let client = HelperClient()
    let installer: HelperInstaller
    let profileStore = ProfileStore()

    private let sensorReader = SensorReader()
    private let fanReader = FanReader()
    private var pollTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var statusTickCounter: Int = 0
    private var hysteresis = HysteresisState()
    /// Last actions applied by the profile evaluator, to avoid redundant XPC calls.
    private var lastProfileActions: [Int: FanAction] = [:]

    init() {
        self.installer = HelperInstaller(client: client)
        do {
            try SMC.shared.open()
        } catch {
            self.smcOpenError = "\(error)"
        }
    }

    func start() {
        stop()
        // Kick an immediate install-status check.
        Task { await self.refreshInstallStatus() }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.hasTakenControl, self.installStatus.isRunning {
                    _ = await self.client.heartbeat()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
    }

    private func tick() async {
        let s = sensorReader.readAll()
        let f = fanReader.readAll()

        var newOverrides: [Int: FanOverrideState] = [:]
        if hasTakenControl && installStatus.isRunning {
            let states = await client.overrideStatus()
            for st in states { newOverrides[st.index] = st }
        }

        let valid = f.contains(where: { $0.readingsValid && $0.actualRPM > 0 })
            || f.isEmpty
            || f.allSatisfy { $0.readingsValid }

        self.sensors = s
        self.fans = f
        self.overrides = newOverrides
        self.fanReadingsValid = valid

        // --- Profile evaluation ---
        await evaluateProfile(sensors: s, fans: f)

        // Re-check install status every ~10 ticks (10s) so the UI reflects
        // external changes (e.g., user ran uninstall script manually).
        statusTickCounter += 1
        if statusTickCounter >= 10 {
            statusTickCounter = 0
            await refreshInstallStatus()
        }
    }

    // MARK: - Install / Uninstall

    func refreshInstallStatus() async {
        self.installStatus = await installer.status()
    }

    func installHelper() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            try await installer.install()
            // Give launchd a moment to bring the mach service up, then re-check.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshInstallStatus()
            lastError = nil
        } catch let e as HelperInstallError {
            if case .userCancelled = e { return }
            lastError = e.errorDescription
        } catch {
            lastError = "\(error)"
        }
    }

    func uninstallHelper() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            // First release any active overrides so fans aren't pinned.
            if hasTakenControl {
                await releaseControl()
            }
            try await installer.uninstall()
            await refreshInstallStatus()
            lastError = nil
        } catch let e as HelperInstallError {
            if case .userCancelled = e { return }
            lastError = e.errorDescription
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Fan control

    func takeControl() async {
        guard installStatus.isRunning else {
            lastError = "Install the helper first."
            return
        }
        let state = await client.ping()
        if case .connected = state {
            self.hasTakenControl = true
            // Auto-activate profile if one was previously selected.
            if profileStore.activeProfileID != nil {
                profileActive = true
            }
        } else {
            lastError = "Helper unreachable."
        }
    }

    func releaseControl() async {
        for index in overrides.keys {
            _ = await client.setFanAuto(index: index)
        }
        self.hasTakenControl = false
        self.overrides = [:]
        self.profileActive = false
        self.hysteresis = HysteresisState()
        self.lastProfileActions = [:]
    }

    func setFan(_ index: Int, toRPM rpm: Double) async -> String {
        let (_, msg) = await client.setFanOverride(index: index, rpm: rpm)
        return msg
    }

    func setFanFull(_ index: Int) async -> String {
        let (_, msg) = await client.setFanFullSpeed(index: index)
        return msg
    }

    func setFanAuto(_ index: Int) async -> String {
        let (_, msg) = await client.setFanAuto(index: index)
        return msg
    }

    // MARK: - Profile management

    func activateProfile(_ id: UUID) {
        profileStore.setActiveProfile(id)
        hysteresis = HysteresisState()
        lastProfileActions = [:]
        profileActive = hasTakenControl && installStatus.isRunning
    }

    func deactivateProfile() async {
        // Return all profile-managed fans to auto.
        for (index, action) in lastProfileActions {
            if case .setRPM = action {
                _ = await client.setFanAuto(index: index)
            }
        }
        profileStore.setActiveProfile(nil)
        profileActive = false
        hysteresis = HysteresisState()
        lastProfileActions = [:]
    }

    func addProfile(_ profile: FanProfile) {
        profileStore.addProfile(profile)
    }

    func updateProfile(_ profile: FanProfile) {
        profileStore.updateProfile(profile)
        // If this is the active profile, reset hysteresis so changes take effect.
        if profile.id == profileStore.activeProfileID {
            hysteresis = HysteresisState()
            lastProfileActions = [:]
        }
    }

    func deleteProfile(_ id: UUID) async {
        if id == profileStore.activeProfileID {
            await deactivateProfile()
        }
        profileStore.deleteProfile(id)
    }

    // MARK: - Profile evaluation

    private func evaluateProfile(sensors: [SensorReading], fans: [FanReading]) async {
        guard profileActive, hasTakenControl, installStatus.isRunning,
              let profile = profileStore.activeProfile else {
            return
        }

        let sensorValues = Dictionary(sensors.map { ($0.key, $0.celsius) },
                                      uniquingKeysWith: { a, _ in a })
        let fanLimits = Dictionary(fans.map { ($0.index, (min: $0.minRPM, max: $0.maxRPM)) },
                                   uniquingKeysWith: { a, _ in a })

        let actions = ProfileEvaluator.evaluate(
            profile: profile,
            sensorValues: sensorValues,
            fanLimits: fanLimits,
            hysteresis: &hysteresis
        )

        // Only send XPC when action changed from last tick.
        for (index, action) in actions {
            if action != lastProfileActions[index] {
                switch action {
                case .setRPM(let rpm):
                    _ = await client.setFanOverride(index: index, rpm: rpm)
                case .auto:
                    _ = await client.setFanAuto(index: index)
                }
            }
        }
        // Handle fans that were in lastProfileActions but no longer in actions (rule removed).
        for index in lastProfileActions.keys where actions[index] == nil {
            _ = await client.setFanAuto(index: index)
        }
        lastProfileActions = actions
    }
}
