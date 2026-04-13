import Foundation
import MacFanControlCore

// MARK: - Privilege guard

guard getuid() == 0 else {
    FileHandle.standardError.write(Data(
        "MacFanControlHelper must run as root (launchd daemon).\n".utf8
    ))
    exit(1)
}

// MARK: - XPC listener delegate

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        // Accept only connections from the real console user's uid. We are
        // not using setCodeSigningRequirement because the binary is ad-hoc
        // signed; defense in depth is the uid check.
        let clientUID = newConnection.effectiveUserIdentifier
        let consoleUID = getConsoleUID()
        if clientUID != consoleUID {
            NSLog("helper: rejecting connection from uid=\(clientUID) (console uid=\(consoleUID))")
            return false
        }

        let iface = NSXPCInterface(with: FanHelperProtocol.self)

        // Whitelist classes decoded in the reply of overrideStatus.
        let classes = NSSet(objects: FanOverrideState.self, NSArray.self)
        iface.setClasses(classes as! Set<AnyHashable>,
                         for: #selector(FanHelperProtocol.overrideStatus(reply:)),
                         argumentIndex: 0,
                         ofReply: true)

        newConnection.exportedInterface = iface
        newConnection.exportedObject = service

        newConnection.invalidationHandler = {
            NSLog("helper: client connection invalidated")
        }
        newConnection.interruptionHandler = {
            NSLog("helper: client connection interrupted")
        }

        newConnection.resume()
        NSLog("helper: accepted connection from uid=\(clientUID)")
        return true
    }

    private func getConsoleUID() -> uid_t {
        // SCDynamicStoreCopyConsoleUser lives in SystemConfiguration but we
        // don't want to pull that in. Shell out to `stat -f "%u" /dev/console`
        // which is stable on macOS.
        let task = Process()
        task.launchPath = "/usr/bin/stat"
        task.arguments = ["-f", "%u", "/dev/console"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let uid = uid_t(str) {
                return uid
            }
        } catch {
            NSLog("helper: failed to stat /dev/console: \(error)")
        }
        return 0
    }
}

// MARK: - Main

NSLog("helper: starting (uid=\(getuid())), mach service=\(HelperConstants.machServiceName)")

let service = HelperService()
service.start()

let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// Reapply override on wake. `NSWorkspace.didWakeNotification` is the AppKit
// variant; in a daemon we use DistributedNotificationCenter + a darwin notify.
// Simpler: just observe via NotificationCenter on IOKit power — for now, rely
// on the reconciliation loop to reapply when writes succeed post-wake.

NSLog("helper: listener resumed, entering run loop")
RunLoop.current.run()
