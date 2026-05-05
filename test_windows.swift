import AppKit

let options = CGWindowListOption([.optionAll, .excludeDesktopElements])
guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

for info in rawWindows {
    guard let owner = info[kCGWindowOwnerName as String] as? String else { continue }
    if owner.lowercased().contains("antigravity") {
        let title = info[kCGWindowName as String] as? String ?? ""
        print("Antigravity Window: '\(title)'")
    }
}
