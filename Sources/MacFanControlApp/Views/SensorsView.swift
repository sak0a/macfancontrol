import SwiftUI
import MacFanControlCore

struct SensorsView: View {
    @ObservedObject var vm: DashboardViewModel

    private var grouped: [(SensorCategory, [SensorReading])] {
        let dict = Dictionary(grouping: vm.visibleSensors, by: { $0.category })
        return SensorCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat in
                guard let list = dict[cat], !list.isEmpty else { return nil }
                return (cat, list.sorted {
                    if $0.isFeatured != $1.isFeatured { return $0.isFeatured }
                    return $0.label.lowercased() < $1.label.lowercased()
                })
            }
    }

    private var hiddenCount: Int {
        max(0, vm.sensors.count - vm.visibleSensors.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Temperatures")
                    .font(.title2).bold()
                Spacer()
                if vm.showAllSensors {
                    Button {
                        vm.showAllSensors = false
                    } label: {
                        Label("Show featured only", systemImage: "star.fill")
                    }
                    .controlSize(.small)
                } else if hiddenCount > 0 {
                    Button {
                        vm.showAllSensors = true
                    } label: {
                        Label("Show all (\(vm.sensors.count))", systemImage: "list.bullet")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.top)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if vm.visibleSensors.isEmpty {
                        Text("No temperature sensors reporting.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        ForEach(grouped, id: \.0) { cat, list in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(cat.displayName)
                                    .font(.headline)
                                    .padding(.horizontal)

                                VStack(spacing: 1) {
                                    ForEach(list, id: \.key) { s in
                                        SensorRow(reading: s)
                                    }
                                }
                                .background(.quaternary.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

private struct SensorRow: View {
    let reading: SensorReading

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(reading.label)
                    .font(.body)
                if reading.isFeatured && reading.label != reading.key {
                    Text(reading.key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(String(format: "%.1f°C", reading.celsius))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(colorForTemp(reading.celsius))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func colorForTemp(_ c: Double) -> Color {
        switch c {
        case ..<40:  return .green
        case ..<60:  return .primary
        case ..<80:  return .orange
        default:     return .red
        }
    }
}
