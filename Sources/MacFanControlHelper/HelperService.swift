import Foundation
import MacFanControlCore

/// Actor-ish serial queue around all SMC writes. Guarantees the
/// reconciliation loop and incoming XPC calls never race.
final class HelperService: NSObject, FanHelperProtocol, @unchecked Sendable {

    private let smc = SMC.shared
    private let fans = FanReader()
    private let queue = DispatchQueue(label: "com.laurinfrank.MacFanControl.helper.work")

    /// Per-fan override state. Mutated only on `queue`.
    private var overrides: [Int: FanOverrideState] = [:]

    /// Monotonic timestamp of last heartbeat. Mutated only on `queue`.
    private var lastHeartbeat: Date = Date()

    private var reconciliationTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    func start() {
        queue.sync {
            do {
                try smc.open()
                NSLog("helper: SMC open OK")
            } catch {
                NSLog("helper: SMC open failed: \(error)")
            }
            self.lastHeartbeat = Date()
            self.startTimers()
        }
    }

    private func startTimers() {
        // Reconciliation loop — runs every reconciliationInterval, re-writes
        // F%dTg for any fan in .custom mode to beat thermalmonitord reclaim.
        let rec = DispatchSource.makeTimerSource(queue: queue)
        rec.schedule(
            deadline: .now() + HelperConstants.reconciliationInterval,
            repeating: HelperConstants.reconciliationInterval,
            leeway: .milliseconds(50)
        )
        rec.setEventHandler { [weak self] in self?.tickReconcile() }
        rec.resume()
        self.reconciliationTimer = rec

        // Watchdog — if client hasn't heartbeat in watchdogTimeout, revert all
        // overrides to auto so fans aren't left pinned on a crash.
        let wd = DispatchSource.makeTimerSource(queue: queue)
        wd.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        wd.setEventHandler { [weak self] in self?.tickWatchdog() }
        wd.resume()
        self.watchdogTimer = wd
    }

    private func tickReconcile() {
        // Called on `queue`
        for (index, state) in overrides where state.mode == .custom {
            guard let tgKey = FanReader.fanKey(index: index, suffix: "Tg") else { continue }
            _ = smc.writeFloat(tgKey, Float(state.targetRPM))
        }
    }

    private func tickWatchdog() {
        // Called on `queue`
        guard !overrides.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(lastHeartbeat)
        guard elapsed > HelperConstants.watchdogTimeout else { return }
        NSLog("helper: watchdog elapsed=\(elapsed)s — reverting all fans to auto")
        for index in overrides.keys {
            revertFanToAutoUnlocked(index: index)
        }
        overrides.removeAll()
    }

    // MARK: - FanHelperProtocol

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply("MacFanControl helper 0.1.0")
    }

    func heartbeat(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            self?.lastHeartbeat = Date()
            reply(true)
        }
    }

    func setFanOverride(index: Int, rpm: Double,
                        reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(false, "gone"); return }

            guard let mdKey = FanReader.fanKey(index: index, suffix: "md"),
                  let tgKey = FanReader.fanKey(index: index, suffix: "Tg"),
                  let mnKey = FanReader.fanKey(index: index, suffix: "Mn"),
                  let mxKey = FanReader.fanKey(index: index, suffix: "Mx")
            else { reply(false, "bad fan index"); return }

            let mn = Double(self.smc.readFloat(mnKey) ?? 0)
            let mx = Double(self.smc.readFloat(mxKey) ?? 0)
            guard mx > 0 else {
                reply(false, "could not read F\(index)Mx")
                return
            }

            // Clamp to hardware-reported min/max.
            let clamped = max(mn, min(rpm, mx))

            // Take manual ownership (F%dmd = 1). This is the latch gate.
            if !self.smc.writeUInt8(mdKey, 1) {
                reply(false, "F\(index)md=1 write failed")
                return
            }

            // Write initial target. Reconciliation loop will keep rewriting.
            if !self.smc.writeFloat(tgKey, Float(clamped)) {
                reply(false, "F\(index)Tg write failed")
                return
            }

            self.overrides[index] = FanOverrideState(
                index: index, mode: .custom, targetRPM: clamped
            )
            self.lastHeartbeat = Date()

            NSLog("helper: fan\(index) custom rpm=\(clamped) (requested=\(rpm))")
            reply(true, "fan \(index) → \(Int(clamped)) rpm")
        }
    }

    func setFanFullSpeed(index: Int,
                         reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(false, "gone"); return }

            guard let mdKey = FanReader.fanKey(index: index, suffix: "md"),
                  let tgKey = FanReader.fanKey(index: index, suffix: "Tg"),
                  let mxKey = FanReader.fanKey(index: index, suffix: "Mx")
            else { reply(false, "bad fan index"); return }

            guard let mx = self.smc.readFloat(mxKey), mx > 0 else {
                reply(false, "could not read F\(index)Mx")
                return
            }

            // Full speed writes the hardware-reported F%dMx directly.
            let target = Double(mx)

            if !self.smc.writeUInt8(mdKey, 1) {
                reply(false, "F\(index)md=1 write failed")
                return
            }
            if !self.smc.writeFloat(tgKey, Float(target)) {
                reply(false, "F\(index)Tg write failed")
                return
            }

            self.overrides[index] = FanOverrideState(
                index: index, mode: .fullSpeed, targetRPM: target
            )
            self.lastHeartbeat = Date()

            NSLog("helper: fan\(index) full-speed rpm=\(target) (mx=\(mx))")
            reply(true, "fan \(index) → \(Int(target)) rpm (max)")
        }
    }

    func setFanAuto(index: Int,
                    reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply(false, "gone"); return }
            let ok = self.revertFanToAutoUnlocked(index: index)
            self.overrides.removeValue(forKey: index)
            self.lastHeartbeat = Date()
            reply(ok,
                  ok ? "fan \(index) → auto (note: M5 Max latch persists until reboot)"
                     : "fan \(index) revert failed")
        }
    }

    func overrideStatus(reply: @escaping @Sendable ([FanOverrideState]) -> Void) {
        queue.async { [weak self] in
            guard let self else { reply([]); return }
            let list = self.overrides.values.sorted { $0.index < $1.index }
            reply(Array(list))
        }
    }

    // MARK: - Internal

    /// Write mode=0. Must be called on `queue`.
    @discardableResult
    private func revertFanToAutoUnlocked(index: Int) -> Bool {
        guard let mdKey = FanReader.fanKey(index: index, suffix: "md") else { return false }
        let ok = smc.writeUInt8(mdKey, 0)
        NSLog("helper: fan\(index) revert md=0 ok=\(ok)")
        return ok
    }
}
