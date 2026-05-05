import AppKit

let options = CGWindowListOption([.optionAll, .excludeDesktopElements])
guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

let terminalOwners = ["Terminal", "iTerm2", "Warp", "Ghostty", "WezTerm"]
for info in rawWindows {
    guard let owner = info[kCGWindowOwnerName as String] as? String else { continue }
    if terminalOwners.contains(where: { owner.localizedCaseInsensitiveContains($0) }) {
        let title = info[kCGWindowName as String] as? String ?? ""
        let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? -1
        print("Terminal (\(owner), PID \(pid)): '\(title)'")
    }
}
