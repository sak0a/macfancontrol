import SwiftUI
import MacFanControlCore

struct FansView: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var showProfileEditor: Bool
    @Binding var editingProfile: FanProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fans").font(.title2).bold()
                Spacer()
                if vm.hasTakenControl {
                    Button("Release control") {
                        Task { await vm.releaseControl() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Take fan control…") {
                        NotificationCenter.default.post(name: .showTakeControlSheet, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.installStatus.isRunning)
                    .help(vm.installStatus.isRunning
                         ? "Put fans under this app's control"
                         : "Install the helper first (see status bar)")
                }
            }
            .padding(.horizontal)

            // --- Profile picker ---
            ProfilePickerSection(
                vm: vm,
                showProfileEditor: $showProfileEditor,
                editingProfile: $editingProfile
            )
            .padding(.horizontal)

            if !vm.fanReadingsValid {
                Label(
                    "Some fan readings report 0 — the M5 Max manual-ownership latch is active. " +
                    "Fan is still physically spinning. A reboot restores auto monitoring.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal)
            }

            if vm.fans.isEmpty {
                Text("No fans detected.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.fans, id: \.index) { fan in
                        FanRow(
                            fan: fan,
                            override: vm.overrides[fan.index],
                            hasControl: vm.hasTakenControl,
                            vm: vm
                        )
                    }
                }
                .padding(.horizontal)
            }
            Spacer()
        }
        .padding(.vertical)
    }
}

private struct FanRow: View {
    let fan: FanReading
    let override: FanOverrideState?
    let hasControl: Bool
    let vm: DashboardViewModel

    @State private var sliderValue: Double = 0
    @State private var statusMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fan \(fan.index)").font(.headline)
                Spacer()
                modePill
                Text("\(Int(fan.actualRPM)) rpm")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 4) {
                Text("min \(Int(fan.minRPM))")
                Text("·")
                Text("max \(Int(fan.maxRPM))")
                Text("·")
                Text("target \(Int(fan.targetRPM))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if hasControl {
                VStack(spacing: 6) {
                    HStack {
                        Slider(
                            value: $sliderValue,
                            in: effectiveRange,
                            step: 50
                        ) {
                            Text("Target")
                        }
                        Text("\(Int(sliderValue))")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }

                    HStack {
                        Button("Set") {
                            Task {
                                statusMessage = await vm.setFan(fan.index, toRPM: sliderValue)
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Full speed") {
                            Task {
                                statusMessage = await vm.setFanFull(fan.index)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Auto") {
                            Task {
                                statusMessage = await vm.setFanAuto(fan.index)
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if vm.profileActive {
                        Text("Profile will re-apply on next tick")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            sliderValue = fan.targetRPM > 0 ? fan.targetRPM : max(fan.minRPM, 2000)
        }
    }

    private var effectiveRange: ClosedRange<Double> {
        let lo = max(fan.minRPM, 500)
        let hi = max(fan.maxRPM, lo + 100)
        return lo...hi
    }

    @ViewBuilder
    private var modePill: some View {
        if let ov = override {
            switch ov.mode {
            case .auto:
                pill("auto", .secondary)
            case .custom:
                pill("custom \(Int(ov.targetRPM))", .blue)
            case .fullSpeed:
                pill("full", .orange)
            }
        } else if fan.mode == 1 {
            pill("manual", .secondary)
        } else {
            pill("auto", .secondary)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct ProfilePickerSection: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var showProfileEditor: Bool
    @Binding var editingProfile: FanProfile?

    /// Binding-compatible selection: nil means "None".
    private var selectedID: Binding<UUID?> {
        Binding(
            get: { vm.profileActive ? vm.profileStore.activeProfileID : nil },
            set: { newID in
                if let id = newID {
                    vm.activateProfile(id)
                } else {
                    Task { await vm.deactivateProfile() }
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Profile:")
                .font(.subheadline)

            Picker("Profile", selection: selectedID) {
                Text("None").tag(UUID?.none)
                ForEach(vm.profileStore.profiles) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .disabled(!vm.hasTakenControl)
            .help(vm.hasTakenControl
                  ? "Select a fan profile to auto-manage fans"
                  : "Take fan control first")

            if let active = vm.profileStore.activeProfile {
                Button("Edit") {
                    editingProfile = active
                    showProfileEditor = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("+ New") {
                editingProfile = nil
                showProfileEditor = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
    }
}

extension Notification.Name {
    static let showTakeControlSheet = Notification.Name("showTakeControlSheet")
}
