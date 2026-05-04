import AppKit

if CommandLine.arguments.contains("--dump-activities") {
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
    exit(0)
}

// 强制创建一个 AppDelegate 实例并保持引用
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate

// 立即设置为普通应用（这样一定能看到 Dock 图标，方便我们调试）
NSApp.setActivationPolicy(.accessory)

print("🚀 [Main] Starting NSApplicationMain...")
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
