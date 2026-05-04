import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel

    init(store: ActivityStore) {
        let content = FloatingWidgetView(store: store)
        let hostingView = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 196, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        
        panel.center()
    }

    private func positionInTopRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame
        let padding: CGFloat = 20
        
        let x = screenFrame.maxX - panelFrame.width - padding
        let y = screenFrame.maxY - panelFrame.height - padding
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }
}
