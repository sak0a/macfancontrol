import SwiftUI
import AppKit
import MacFanControlCore

@main
struct MacFanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var showTakeControl: Bool = false
    @State private var showProfileEditor: Bool = false
    @State private var editingProfile: FanProfile? = nil

    var body: some Scene {
        // ---- Main window ----
        WindowGroup("MacFanControl", id: "main") {
            DashboardRoot(
                vm: appDelegate.vm,
                showTakeControl: $showTakeControl,
                showProfileEditor: $showProfileEditor,
                editingProfile: $editingProfile
            )
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // ---- Status bar menu ----
        MenuBarExtra("MacFanControl", systemImage: "gauge.medium") {
            MenuBarContent(vm: appDelegate.vm)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Top-level window content. Kept as its own view so the SwiftUI scene
/// graph has a stable root even if the window closes and reopens.
struct DashboardRoot: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var showTakeControl: Bool
    @Binding var showProfileEditor: Bool
    @Binding var editingProfile: FanProfile?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SensorsView(vm: vm)
                    .frame(minWidth: 320)
                FansView(
                    vm: vm,
                    showProfileEditor: $showProfileEditor,
                    editingProfile: $editingProfile
                )
                .frame(minWidth: 380)
            }
            StatusBar(vm: vm)
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(isPresented: $showTakeControl) {
            TakeControlSheet(isPresented: $showTakeControl) {
                Task { await vm.takeControl() }
            }
        }
        .sheet(isPresented: $showProfileEditor) {
            ProfileEditorSheet(
                vm: vm,
                isPresented: $showProfileEditor,
                editingProfile: editingProfile
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTakeControlSheet)) { _ in
            showTakeControl = true
        }
    }
}

// MARK: - App delegate

/// Owns the view model so its lifecycle is tied to the application,
/// not to any individual SwiftUI scene. This keeps the menu-bar extra
/// alive when the main window is closed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let vm: DashboardViewModel
    /// Set to `true` only from the explicit "Quit" action in the menu bar.
    static var shouldReallyQuit = false

    override init() {
        self.vm = DashboardViewModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        vm.start()

        // Watch for window visibility changes to toggle Dock icon.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.shouldReallyQuit {
            vm.stop()
            return .terminateNow
        }
        // Cmd+Q / app-menu Quit → close the main window, stay in menu bar.
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.close()
        }
        hideFromDock()
        return .terminateCancel
    }

    @objc private func windowDidBecomeMain(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.canBecomeMain else { return }
        // Delay slightly so the window finishes closing before we hide the Dock icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            let hasVisibleMain = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !hasVisibleMain {
                hideFromDock()
            }
        }
    }

    private func hideFromDock() {
        NSApp.setActivationPolicy(.accessory)
    }
}
