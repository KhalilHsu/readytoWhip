import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let store = ActivityStore()
    private let petLibrary = PetLibrary()
    private var statusItem: NSStatusItem?
    private var panelController: FloatingPanelController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        createMenuBarItem()
        createFloatingPanel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.promptForScreenRecordingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    private func createMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI Monitor")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Widget", action: #selector(showWidget), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func createFloatingPanel() {
        let controller = FloatingPanelController(store: store, petLibrary: petLibrary)
        controller.show()
        panelController = controller
    }

    @objc private func showWidget() {
        panelController?.show()
    }

    @objc private func refresh() {
        store.refresh()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: SettingsStore.shared, petLibrary: petLibrary, onRefresh: { [weak self] in
                self?.store.refresh()
                self?.store.start()
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "AI Activity Settings"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Screen Recording permission (needed by CGWindowListCopyWindowInfo for window titles)

    private func promptForScreenRecordingIfNeeded() {
        // CGPreflightScreenCaptureAccess returns true when already authorised (macOS 10.15+)
        if #available(macOS 10.15, *) {
            guard !CGPreflightScreenCaptureAccess() else { return }
        } else {
            return  // Older macOS doesn't gate this
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = "ReadyToWhip reads window titles to identify which projects your AI tools are working on. Without Screen Recording permission, project names may not appear correctly."
        alert.addButton(withTitle: "Open Settings")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
