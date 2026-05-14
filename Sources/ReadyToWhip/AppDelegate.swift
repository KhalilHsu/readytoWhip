import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let store = ActivityStore()
    private let petLibrary = PetLibrary()
    private var statusItem: NSStatusItem?
    private var panelController: FloatingPanelController?
    private var settingsWindow: NSWindow?
    private var didPromptAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        createMenuBarItem()
        createFloatingPanel()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.promptForAccessibilityIfNeeded()
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

    private func promptForAccessibilityIfNeeded() {
        guard !didPromptAccessibility else { return }
        guard !AXIsProcessTrusted() else { return }
        didPromptAccessibility = true

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility Permission Needed"
        alert.informativeText = "ReadyToWhip uses window titles and focused-window metadata to track live sessions. Without Accessibility permission, app and terminal detection may be incomplete."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
