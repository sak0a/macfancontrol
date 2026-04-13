import Foundation
import MacFanControlCore

enum HelperInstallStatus: Equatable {
    case unknown
    case notInstalled
    case installedButUnreachable
    case running(version: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var shortText: String {
        switch self {
        case .unknown:                return "checking…"
        case .notInstalled:           return "not installed"
        case .installedButUnreachable: return "installed (unreachable)"
        case .running(let v):         return v
        }
    }
}

enum HelperInstallError: LocalizedError {
    case missingBundleResources(String)
    case userCancelled
    case scriptFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingBundleResources(let detail):
            return "Helper binary or plist not found in the app bundle. \(detail)"
        case .userCancelled:
            return "Administrator authentication was cancelled."
        case .scriptFailed(let code, let err):
            return "Install script failed (exit \(code)): \(err)"
        }
    }
}

/// Installs/uninstalls the privileged helper via an AppleScript
/// `do shell script ... with administrator privileges` prompt. This is
/// the native GUI password dialog and does not require any entitlements
/// or Developer ID.
final class HelperInstaller: @unchecked Sendable {
    private let client: HelperClient

    init(client: HelperClient) {
        self.client = client
    }

    // MARK: - Status

    func status() async -> HelperInstallStatus {
        let fm = FileManager.default
        let binExists   = fm.fileExists(atPath: HelperConstants.helperBinaryPath)
        let plistExists = fm.fileExists(atPath: HelperConstants.launchdPlistPath)
        guard binExists && plistExists else { return .notInstalled }

        let state = await client.ping(timeout: 1.5)
        if case .connected(let v) = state {
            return .running(version: v)
        }
        return .installedButUnreachable
    }

    // MARK: - Install / Uninstall

    func install() async throws {
        let (srcBin, srcPlist) = try bundleArtifacts()

        let dstBin   = HelperConstants.helperBinaryPath
        let dstPlist = HelperConstants.launchdPlistPath
        let label    = HelperConstants.launchdLabel

        let script = """
        #!/bin/bash
        set -e
        launchctl bootout system '\(dstPlist)' 2>/dev/null || true
        mkdir -p /Library/PrivilegedHelperTools
        cp '\(srcBin)' '\(dstBin)'
        chown root:wheel '\(dstBin)'
        chmod 755 '\(dstBin)'
        cp '\(srcPlist)' '\(dstPlist)'
        chown root:wheel '\(dstPlist)'
        chmod 644 '\(dstPlist)'
        launchctl bootstrap system '\(dstPlist)'
        launchctl enable 'system/\(label)'
        """

        try await runAsRoot(script: script, prompt: "MacFanControl wants to install its fan-control helper.")
        client.reset()
    }

    func uninstall() async throws {
        let script = """
        #!/bin/bash
        set -e
        launchctl bootout system '\(HelperConstants.launchdPlistPath)' 2>/dev/null || true
        rm -f '\(HelperConstants.launchdPlistPath)'
        rm -f '\(HelperConstants.helperBinaryPath)'
        """
        try await runAsRoot(script: script, prompt: "MacFanControl wants to remove its fan-control helper.")
        client.reset()
    }

    // MARK: - Internals

    /// Returns absolute paths to the helper binary and plist bundled inside the .app.
    private func bundleArtifacts() throws -> (bin: String, plist: String) {
        let bundlePath = Bundle.main.bundlePath
        let contentsURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents")
        let binURL = contentsURL.appendingPathComponent("MacOS/\(HelperConstants.launchdLabel)")
        let plistURL = contentsURL
            .appendingPathComponent("Library/LaunchDaemons/\(HelperConstants.launchdLabel).plist")

        let fm = FileManager.default
        guard fm.fileExists(atPath: binURL.path) else {
            throw HelperInstallError.missingBundleResources(
                "Expected \(binURL.path). Run ./scripts/build.sh and launch MacFanControl.app."
            )
        }
        guard fm.fileExists(atPath: plistURL.path) else {
            throw HelperInstallError.missingBundleResources(
                "Expected \(plistURL.path). Rebuild the .app bundle."
            )
        }
        return (binURL.path, plistURL.path)
    }

    private func runAsRoot(script: String, prompt: String) async throws {
        // Write the script to a temp file to avoid shell-escaping pain.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfancontrol-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: tmp.path
        )

        let osaCommand = "/bin/bash '\(tmp.path)'"
        let escaped = osaCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript =
            "do shell script \"\(escaped)\" with prompt \"\(escapedPrompt)\" with administrator privileges"

        try await Self.runOsascript(appleScript)
    }

    private static func runOsascript(_ appleScript: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", appleScript]
                let errPipe = Pipe()
                let outPipe = Pipe()
                task.standardError = errPipe
                task.standardOutput = outPipe

                do {
                    try task.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                task.waitUntilExit()

                let code = task.terminationStatus
                if code == 0 {
                    cont.resume(returning: ())
                    return
                }

                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                if stderr.contains("-128") || stderr.contains("User canceled") {
                    cont.resume(throwing: HelperInstallError.userCancelled)
                } else {
                    cont.resume(throwing: HelperInstallError.scriptFailed(
                        exitCode: code, stderr: stderr
                    ))
                }
            }
        }
    }
}
