import SwiftUI
import MacFanControlCore

struct ProfileEditorSheet: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var isPresented: Bool
    /// nil = new profile, non-nil = editing existing.
    let editingProfile: FanProfile?

    @State private var name: String = ""
    @State private var rules: [FanRule] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(editingProfile == nil ? "New Profile" : "Edit Profile")
                    .font(.title3).bold()
                Spacer()
            }
            .padding()

            Divider()

            // Name
            HStack {
                Text("Name:")
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Rules list
            if rules.isEmpty {
                Text("No rules yet. Add one below.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($rules) { $rule in
                            RuleRow(
                                rule: $rule,
                                sensors: vm.visibleSensors,
                                fans: vm.fans,
                                onDelete: { rules.removeAll { $0.id == rule.id } }
                            )
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Add Rule") {
                    let defaultSensor = vm.visibleSensors.first?.key ?? "TPMP"
                    let defaultMin = vm.fans.first?.minRPM ?? 2317
                    rules.append(FanRule(
                        sensorKey: defaultSensor,
                        fanIndex: 0,
                        thresholdCelsius: 60,
                        targetRPM: max(defaultMin, 3000)
                    ))
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 340)
        .onAppear {
            if let p = editingProfile {
                name = p.name
                rules = p.rules
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if var existing = editingProfile {
            existing.name = trimmedName
            existing.rules = rules
            vm.updateProfile(existing)
        } else {
            let profile = FanProfile(name: trimmedName, rules: rules)
            vm.addProfile(profile)
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: FanRule
    let sensors: [SensorReading]
    let fans: [FanReading]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            // Sensor picker
            Picker("Sensor", selection: $rule.sensorKey) {
                ForEach(sensors, id: \.key) { s in
                    Text("\(s.label) (\(s.key))")
                        .tag(s.key)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)

            // Fan picker
            Picker("Fan", selection: $rule.fanIndex) {
                ForEach(fans, id: \.index) { f in
                    Text("Fan \(f.index)").tag(f.index)
                }
            }
            .labelsHidden()
            .frame(width: 70)

            // Threshold
            VStack(spacing: 0) {
                Text("\(Int(rule.thresholdCelsius)) C")
                    .font(.system(.caption, design: .monospaced))
                Slider(value: $rule.thresholdCelsius, in: 30...105, step: 1)
                    .frame(width: 80)
            }

            // RPM
            VStack(spacing: 0) {
                Text("\(Int(rule.targetRPM)) rpm")
                    .font(.system(.caption, design: .monospaced))
                Slider(value: $rule.targetRPM, in: rpmRange, step: 50)
                    .frame(width: 80)
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var rpmRange: ClosedRange<Double> {
        let fan = fans.first { $0.index == rule.fanIndex }
        let lo = max(fan?.minRPM ?? 500, 500)
        let hi = max(fan?.maxRPM ?? 8000, lo + 100)
        return lo...hi
    }
}
