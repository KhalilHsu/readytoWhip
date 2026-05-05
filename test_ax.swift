import AppKit

func getAccessibilityTitle(for pid: Int32) -> String? {
    let appRef = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    
    let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &value)
    if result == .success, let windowRef = value as! AXUIElement? {
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(windowRef, kAXTitleAttribute as CFString, &titleValue)
        if titleResult == .success, let title = titleValue as? String {
            return title
        }
    }
    
    var windowListValue: CFTypeRef?
    let listResult = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowListValue)
    if listResult == .success, let windows = windowListValue as? [AXUIElement], let firstWindow = windows.first {
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(firstWindow, kAXTitleAttribute as CFString, &titleValue)
        if titleResult == .success, let title = titleValue as? String {
            return title
        }
    }
    
    return nil
}

for app in NSWorkspace.shared.runningApplications {
    if app.localizedName?.lowercased().contains("antigravity") == true {
        if let title = getAccessibilityTitle(for: app.processIdentifier) {
            print("AX Title (\(app.processIdentifier)): '\(title)'")
        } else {
            print("AX Title (\(app.processIdentifier)): nil")
        }
    }
}
