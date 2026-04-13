import Foundation
import MacFanControlCore

/// Resume-once wrapper around a CheckedContinuation so XPC error handlers
/// and success callbacks can race without double-resuming.
private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private let cont: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var resumed = false

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        if resumed { return }
        resumed = true
        cont.resume(returning: value)
    }
}

/// Thin wrapper around NSXPCConnection to the privileged helper.
/// Lazily connects on first use; surfaces connection state as a
/// published-friendly value. All async methods time out so a missing
/// helper never hangs the app.
final class HelperClient: @unchecked Sendable {

    enum State: Equatable {
        case disconnected
        case connected(version: String)
        case error(String)
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private(set) var state: State = .disconnected

    /// Returns the helper proxy configured to forward failures to `onError`.
    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> FanHelperProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: [.privileged]
            )

            let iface = NSXPCInterface(with: FanHelperProtocol.self)
            let classes = NSSet(objects: FanOverrideState.self, NSArray.self)
            iface.setClasses(classes as! Set<AnyHashable>,
                             for: #selector(FanHelperProtocol.overrideStatus(reply:)),
                             argumentIndex: 0,
                             ofReply: true)
            conn.remoteObjectInterface = iface

            conn.invalidationHandler = { [weak self] in
                self?.invalidate(reason: "invalidated")
            }
            conn.interruptionHandler = { [weak self] in
                self?.invalidate(reason: "interrupted")
            }
            conn.resume()
            self.connection = conn
        }

        return connection?.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.invalidate(reason: "proxy error: \(err.localizedDescription)")
            onError(err)
        } as? FanHelperProtocol
    }

    private func invalidate(reason: String) {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
        state = .error(reason)
    }

    /// Force-drop the connection so a subsequent call re-establishes it.
    /// Needed right after installing/uninstalling the helper.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
        state = .disconnected
    }

    /// Schedule a timeout that resumes the box with `fallback`.
    private func scheduleTimeout<T: Sendable>(box: ResumeBox<T>, fallback: T, seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            box.resume(fallback)
        }
    }

    // MARK: - Public API

    func ping(timeout: Double = 2.0) async -> State {
        await withCheckedContinuation { (cont: CheckedContinuation<State, Never>) in
            let box = ResumeBox(cont)
            scheduleTimeout(box: box, fallback: .error("timeout"), seconds: timeout)

            guard let p = proxy(onError: { err in
                box.resume(.error(err.localizedDescription))
            }) else {
                box.resume(.error("no helper"))
                return
            }
            p.helperVersion { [weak self] version in
                self?.lock.lock()
                self?.state = .connected(version: version)
                self?.lock.unlock()
                box.resume(.connected(version: version))
            }
        }
    }

    func heartbeat(timeout: Double = 2.0) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let box = ResumeBox(cont)
            scheduleTimeout(box: box, fallback: false, seconds: timeout)
            guard let p = proxy(onError: { _ in box.resume(false) }) else {
                box.resume(false); return
            }
            p.heartbeat { ok in box.resume(ok) }
        }
    }

    func setFanOverride(index: Int, rpm: Double, timeout: Double = 3.0) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            let box = ResumeBox(cont)
            scheduleTimeout(box: box, fallback: (false, "timeout"), seconds: timeout)
            guard let p = proxy(onError: { err in box.resume((false, err.localizedDescription)) }) else {
                box.resume((false, "no helper")); return
            }
            p.setFanOverride(index: index, rpm: rpm) { ok, msg in
                box.resume((ok, msg))
            }
        }
    }

    func setFanFullSpeed(index: Int, timeout: Double = 3.0) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            let box = ResumeBox(cont)
            scheduleTimeout(box: box, fallback: (false, "timeout"), seconds: timeout)
            guard let p = proxy(onError: { err in box.resume((false, err.localizedDescription)) }) else {
                box.resume((false, "no helper")); return
            }
            p.setFanFullSpeed(index: index) { ok, msg in
                box.resume((ok, msg))
            }
        }
    }

    func setFanAuto(index: Int, timeout: Double = 3.0) async -> (ok: Bool, message: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            let box = ResumeBox(cont)
            scheduleTimeout(box: box, fallback: (false, "timeout"), seconds: timeout)
            guard let p = proxy(onError: { err in box.resume((false, err.localizedDescription)) }) else {
                box.resume((false, "no helper")); return
            }
            p.setFanAuto(index: index) { ok, msg in
                box.resume((ok, msg))
            }
        }
    }

    func overrideStatus(timeout: Double = 2.0) async -> [FanOverrideState] {
        await withCheckedContinuation { (cont: CheckedContinuation<[FanOverrideState], Never>) in
            let box = ResumeBox(cont)
            scheduleTimeout(box: box, fallback: [], seconds: timeout)
            guard let p = proxy(onError: { _ in box.resume([]) }) else {
                box.resume([]); return
            }
            p.overrideStatus { states in box.resume(states) }
        }
    }
}
