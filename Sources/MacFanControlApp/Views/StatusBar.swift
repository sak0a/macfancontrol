import SwiftUI
import MacFanControlCore

struct StatusBar: View {
    @ObservedObject var vm: DashboardViewModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text("Helper:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(vm.installStatus.shortText)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)

            installButtons

            Spacer()

            if let err = vm.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(err)
                Button {
                    vm.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let err = vm.smcOpenError {
                Text("SMC: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("\(vm.sensors.count) sensors · \(vm.fans.count) fans")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Install controls

    @ViewBuilder
    private var installButtons: some View {
        if vm.isInstalling {
            ProgressView().controlSize(.small)
        } else {
            switch vm.installStatus {
            case .unknown:
                EmptyView()
            case .notInstalled:
                Button("Install helper…") {
                    Task { await vm.installHelper() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .installedButUnreachable:
                Button("Repair helper…") {
                    Task { await vm.installHelper() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Uninstall") {
                    Task { await vm.uninstallHelper() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .running:
                Menu {
                    Button("Reinstall / update…") {
                        Task { await vm.installHelper() }
                    }
                    Button("Uninstall helper…", role: .destructive) {
                        Task { await vm.uninstallHelper() }
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var indicatorColor: Color {
        switch vm.installStatus {
        case .running:                return .green
        case .installedButUnreachable: return .orange
        case .notInstalled:           return .gray
        case .unknown:                return .gray
        }
    }
}
