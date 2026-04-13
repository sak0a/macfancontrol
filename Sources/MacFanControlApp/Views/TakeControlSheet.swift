import SwiftUI

struct TakeControlSheet: View {
    @Binding var isPresented: Bool
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Take fan control?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2).bold()
                .foregroundStyle(.orange)

            Text("""
On this MacBook Pro (Apple M5 Max, macOS 26), the SMC enters a manual-ownership \
latch as soon as anything writes a fan. Consequences you should understand:
""")

            Label("The fan will obey your target while the app runs.", systemImage: "checkmark.circle")

            Label("Releasing control or quitting the app sets mode=auto, but the driver-level latch persists until reboot. Auto-mode RPM/target readings may show 0 even though the fan is still physically spinning under thermal control.", systemImage: "info.circle")

            Label("A simple reboot fully restores pristine state.", systemImage: "arrow.clockwise")

            Label("Targets are clamped to the hardware-reported min/max per fan.", systemImage: "lock.shield")

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Take control") {
                    isPresented = false
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
