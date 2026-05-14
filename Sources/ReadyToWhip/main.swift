import AppKit

if CommandLine.arguments.contains("--dump-activities") {
    let activities = ActivityDetector().detect()
    let dumpRaw = CommandLine.arguments.contains("--dump-raw")
    print("ReadyToWhip detected \(activities.count) activities")
    for activity in activities {
        print(ActivityPrivacy.dumpFields(for: activity, raw: dumpRaw).joined(separator: "\t"))
    }
    exit(0)
}

// 强制创建一个 AppDelegate 实例并保持引用
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate

NSApp.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
