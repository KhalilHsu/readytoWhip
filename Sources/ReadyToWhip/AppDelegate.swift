import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let store = ActivityStore()
    private var statusItem: NSStatusItem?
    private var panelController: FloatingPanelController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump-activities") {
            dumpActivitiesAndQuit()
            return
        }

        print("🚀 [Debug] App is launching...")
        NSApp.setActivationPolicy(.accessory)
        
        print("🚀 [Debug] Starting ActivityStore...")
        store.start()
        
        print("🚀 [Debug] Creating Menu Bar Item...")
        createMenuBarItem()
        
        print("🚀 [Debug] Creating Floating Panel...")
        createFloatingPanel()
        
        print("🚀 [Debug] Launch sequence complete!")
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    private func createMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🔴 AI MONITOR"

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
        let controller = FloatingPanelController(store: store)
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
            let view = SettingsView(settings: SettingsStore.shared, onRefresh: { [weak self] in
                self?.store.refresh()
                self?.store.start()
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
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

    private func dumpActivitiesAndQuit() {
        let activities = ActivityDetector().detect()
        print("ReadyToWhip detected \(activities.count) activities")
        for activity in activities {
            print([
                activity.status.rawValue,
                activity.toolName,
                activity.projectName ?? "",
                activity.windowTitle ?? "",
                activity.commandLine ?? ""
            ].joined(separator: "\t"))
        }
        NSApp.terminate(nil)
    }
}
