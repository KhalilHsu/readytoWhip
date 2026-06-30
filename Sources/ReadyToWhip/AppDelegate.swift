import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let logger = Logger(subsystem: "rip.readytowhip.activity", category: "AppDelegate")
    private let store = ActivityStore()
    private let promptHubStore = PromptHubStore()
    private let petLibrary = PetLibrary()
    private var statusItem: NSStatusItem?
    private var panelController: FloatingPanelController?
    private var settingsWindow: NSWindow?
    private var promptHubWindow: NSWindow?
    private var didStartApplication = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("applicationDidFinishLaunching")
        startApplication()
    }

    func startApplication() {
        guard !didStartApplication else { return }
        didStartApplication = true
        logger.info("startApplication")
        NSApp.setActivationPolicy(.accessory)
        createMenuBarItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.showPromptHub()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showPromptHub()
        }

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
        menu.addItem(NSMenuItem(title: "Prompt Hub...", action: #selector(showPromptHub), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func createFloatingPanel() {
        store.start()
        let controller = FloatingPanelController(store: store, petLibrary: petLibrary)
        controller.show()
        panelController = controller
    }

    @objc private func showWidget() {
        if panelController == nil {
            createFloatingPanel()
        } else {
            panelController?.show()
        }
    }

    @objc private func showPromptHub() {
        logger.info("showPromptHub begin existingWindow=\(self.promptHubWindow == nil ? "no" : "yes")")
        if promptHubWindow == nil {
            let view = PromptHubView(store: promptHubStore)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "ReadyToWhip Prompt Hub"
            window.contentView = NSHostingView(rootView: view)
            window.minSize = NSSize(width: 860, height: 560)
            window.center()
            promptHubWindow = window
            logger.info("showPromptHub created window")
        }

        promptHubStore.refreshAvailability()
        promptHubWindow?.makeKeyAndOrderFront(nil)
        promptHubWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        logger.info("showPromptHub ordered window")
    }

    @objc private func refresh() {
        store.refresh()
        promptHubStore.refreshAvailability()
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
        // First check standard API. If it returns true, we definitely have permission.
        // If it returns false, it might be the macOS 14+ bug, so we fallback to the heuristic test.
        if CGPreflightScreenCaptureAccess() { return }
        guard !canReadWindowTitles() else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = "ReadyToWhip reads window titles to identify which projects your AI tools are working on. Without Screen Recording permission, project names may not appear correctly."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Functional test fallback: can we actually read window titles from other processes?
    private func canReadWindowTitles() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        // Use .optionAll to catch off-screen or hidden windows on empty desktops
        let options = CGWindowListOption([.optionAll, .excludeDesktopElements])
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != myPID else {
                return false
            }
            // If we can read a non-nil window name from another process, permission is granted
            return info[kCGWindowName as String] as? String != nil
        }
    }
}
