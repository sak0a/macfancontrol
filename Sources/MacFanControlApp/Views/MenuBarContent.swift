import SwiftUI
import AppKit
import MacFanControlCore

/// Dropdown shown when the user clicks the menu bar icon.
/// Using `.menu` style means child views should be plain Buttons and Text
/// that SwiftUI maps to NSMenuItems. Live-updating labels work via the
/// observed view model.
struct MenuBarContent: View {
    @ObservedObject var vm: DashboardViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // ---- Status line ----
        Text(helperStatusLine)

        if !vm.fans.isEmpty {
            Divider()
            ForEach(vm.fans, id: \.index) { fan in
                Text(fanLine(fan))
            }
        }

        // ---- Hottest sensor summary ----
        if let hottest = vm.sensors.max(by: { $0.celsius < $1.celsius }) {
            Divider()
            Text(String(format: "Hottest: %@  %.1f°C", hottest.label, hottest.celsius))
        }

        // ---- Active profile ----
        if vm.profileActive, let profile = vm.profileStore.activeProfile {
            Divider()
            Text("Profile: \(profile.name)")
        }

        Divider()

        // ---- Actions ----
        if vm.installStatus.isRunning {
            if vm.hasTakenControl {
                Button("Release fan control") {
                    Task { await vm.releaseControl() }
                }
                Menu("Set fan…") {
                    ForEach(vm.fans, id: \.index) { fan in
                        Menu("Fan \(fan.index)") {
                            Button("Full speed (\(Int(fan.maxRPM)) rpm)") {
                                Task { _ = await vm.setFanFull(fan.index) }
                            }
                            Button("Auto") {
                                Task { _ = await vm.setFanAuto(fan.index) }
                            }
                        }
                    }
                }
                if !vm.profileStore.profiles.isEmpty {
                    Menu("Profiles") {
                        Button("None") {
                            Task { await vm.deactivateProfile() }
                        }
                        Divider()
                        ForEach(vm.profileStore.profiles) { p in
                            Button {
                                vm.activateProfile(p.id)
                            } label: {
                                if p.id == vm.profileStore.activeProfileID && vm.profileActive {
                                    Text("✓ \(p.name)")
                                } else {
                                    Text("  \(p.name)")
                                }
                            }
                        }
                    }
                }
            } else {
                Button("Take fan control…") {
                    activateApp()
                    openWindow(id: "main")
                    NotificationCenter.default.post(name: .showTakeControlSheet, object: nil)
                }
            }
        } else if case .notInstalled = vm.installStatus {
            Button("Install helper…") {
                Task { await vm.installHelper() }
            }
        } else if case .installedButUnreachable = vm.installStatus {
            Button("Repair helper…") {
                Task { await vm.installHelper() }
            }
        }

        Divider()

        Button("Open dashboard") {
            activateApp()
            openWindow(id: "main")
        }
        .keyboardShortcut("o")

        Button("Quit MacFanControl") {
            AppDelegate.shouldReallyQuit = true
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers

    private var helperStatusLine: String {
        switch vm.installStatus {
        case .running(let v):           return "Helper: \(v)"
        case .installedButUnreachable:  return "Helper: installed (unreachable)"
        case .notInstalled:             return "Helper: not installed"
        case .unknown:                  return "Helper: checking…"
        }
    }

    private func fanLine(_ fan: FanReading) -> String {
        let rpm = Int(fan.actualRPM)
        let tag: String
        if let ov = vm.overrides[fan.index] {
            switch ov.mode {
            case .custom:    tag = "custom \(Int(ov.targetRPM))"
            case .fullSpeed: tag = "full"
            case .auto:      tag = "auto"
            }
        } else {
            tag = fan.mode == 1 ? "manual" : "auto"
        }
        return "Fan \(fan.index): \(rpm) rpm · \(tag)"
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
