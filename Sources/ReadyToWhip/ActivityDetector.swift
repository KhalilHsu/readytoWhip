import AppKit
import Foundation

struct ProcessSnapshot: Hashable {
    let pid: Int32
    let parentPID: Int32
    let cpu: Double
    let processName: String
    let commandLine: String
}

struct WindowSnapshot: Hashable {
    let pid: Int32
    let title: String?
    let ownerName: String?
}

final class ActivityDetector {
    func detect(enabledToolNames: Set<String>? = nil) -> [AIActivity] {
        let now = Date()
        let enabled = enabledToolNames ?? Set(ToolCatalog.supported.map(\.name))
        let needsGenericDesktopDetection = ToolCatalog.supported.contains { tool in
            enabled.contains(tool.name)
                && !tool.bundleIdentifiers.isEmpty
                && tool.name != "Codex Desktop"
                && tool.name != "Antigravity"
        }
        let needsCLIDetection = ToolCatalog.supported.contains { tool in
            enabled.contains(tool.name) && tool.bundleIdentifiers.isEmpty
        }
        let needsProcesses = enabled.contains("Antigravity") || needsGenericDesktopDetection || needsCLIDetection
        let needsWindows = needsGenericDesktopDetection || needsCLIDetection

        let windows = needsWindows ? collectWindows() : [:]
        let processes = needsProcesses ? collectProcesses() : []
        let context = AppRuntimeContext(
            codexPID: enabled.contains("Codex Desktop") ? runningPID(bundleIdentifier: "com.openai.codex", localizedName: "Codex") : nil,
            antigravityPID: enabled.contains("Antigravity") ? runningPID(bundleIdentifier: "com.google.antigravity", localizedName: "Antigravity") : nil,
            processes: processes,
            windows: windows
        )
        let taskStateActivities = TaskStateAdapters.detect(context: context)
            .filter { enabled.contains($0.toolName) }
        let desktopActivities = needsGenericDesktopDetection
            ? detectDesktopApps(windows: windows, processes: processes, now: now)
                .filter { activity in
                    enabled.contains(activity.toolName)
                        && activity.toolName != "Codex Desktop"
                        && activity.toolName != "Antigravity"
                }
            : []
        let cliActivities = needsCLIDetection
            ? detectCLIProcesses(windows: windows, processes: processes, now: now)
                .filter { enabled.contains($0.toolName) }
            : []

        let merged = (taskStateActivities + desktopActivities + cliActivities)
            .filter { $0.status != .idle && $0.status != .unknown }
        return Array(Dictionary(grouping: merged, by: \.id).compactMap { _, items in
            items.sorted { lhs, rhs in
                lhs.status.priority < rhs.status.priority
            }.first
        })
        .sorted {
            if $0.status.priority != $1.status.priority {
                return $0.status.priority < $1.status.priority
            }
            return $0.toolName.localizedCaseInsensitiveCompare($1.toolName) == .orderedAscending
        }
    }

    private func detectDesktopApps(windows: [Int32: [WindowSnapshot]], processes: [ProcessSnapshot], now: Date) -> [AIActivity] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }

            guard let tool = ToolCatalog.desktopTool(
                for: app.bundleIdentifier,
                localizedName: app.localizedName
            ) else {
                return nil
            }

            let pid = app.processIdentifier
            let appWindows = relatedWindows(for: app, windows: windows)

            let lowerName = app.localizedName?.lowercased() ?? ""
            let noiseKeywords = ["service", "helper", "crashpad", "panel", "webcontent", "codexbar"]
            if noiseKeywords.contains(where: { lowerName.contains($0) }) {
                return nil
            }

            let title = bestWindowTitle(from: appWindows)
            let relatedProcesses = relatedProcesses(for: app, tool: tool, processes: processes)
            let status = inferDesktopStatus(app: app, windows: appWindows, processes: relatedProcesses)
            let projectName = title ?? app.localizedName ?? "Unknown"

            return AIActivity(
                id: "app-\(pid)-\(tool.id)",
                toolName: tool.name,
                bundleIdentifier: app.bundleIdentifier,
                processIdentifier: pid,
                source: .desktopApp,
                status: status,
                projectName: projectName,
                windowTitle: title,
                commandLine: nil,
                lastUpdated: now
            )
        }
    }

    private func runningPID(bundleIdentifier: String, localizedName: String) -> Int32? {
        NSWorkspace.shared.runningApplications.first { app in
            if app.bundleIdentifier == bundleIdentifier {
                return true
            }
            return app.localizedName?.localizedCaseInsensitiveContains(localizedName) == true
        }?.processIdentifier
    }

    private func detectCLIProcesses(windows: [Int32: [WindowSnapshot]], processes: [ProcessSnapshot], now: Date) -> [AIActivity] {
        processes.compactMap { process in
            guard !isNoise(process) else { return nil }
            guard let tool = ToolCatalog.cliTool(
                for: process.commandLine,
                processName: process.processName
            ) else {
                return nil
            }

            let terminalWindow = nearestTerminalWindow(for: process, windows: windows)
            let title = terminalWindow?.title
            let status = inferCLIStatus(process: process, terminalTitle: title)
            let projectName = inferProjectName(from: title, fallback: nil)
            
            let id = terminalWindow != nil ? "cli-window-\(terminalWindow!.pid)-\(tool.id)" : "cli-headless-\(tool.id)"

            return AIActivity(
                id: id,
                toolName: tool.name,
                bundleIdentifier: terminalBundleIdentifier(for: process),
                processIdentifier: process.pid,
                source: .cli,
                status: status,
                projectName: projectName,
                windowTitle: title,
                commandLine: process.commandLine,
                lastUpdated: now
            )
        }
    }

    private func collectWindows() -> [Int32: [WindowSnapshot]] {
        let options = CGWindowListOption([.optionAll, .excludeDesktopElements])
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        let snapshots = rawWindows.compactMap { info -> WindowSnapshot? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            let title = info[kCGWindowName as String] as? String
            let owner = info[kCGWindowOwnerName as String] as? String
            
            return WindowSnapshot(pid: pid, title: title?.nilIfBlank, ownerName: owner?.nilIfBlank)
        }

        return Dictionary(grouping: snapshots, by: \.pid)
    }

    private func getAccessibilityTitle(for pid: Int32) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        
        // 尝试获取主窗口
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &value)
        if result == .success, let windowRef = value as! AXUIElement? {
            var titleValue: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(windowRef, kAXTitleAttribute as CFString, &titleValue)
            if titleResult == .success, let title = titleValue as? String {
                return title
            }
        }
        
        // 如果没有焦点窗口，尝试遍历所有窗口
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

    private func collectProcesses() -> [ProcessSnapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pcpu=,args="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            parsePSLine(String(line))
        }
    }

    private func parsePSLine(_ line: String) -> ProcessSnapshot? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let cpu = Double(parts[2])
        else {
            return nil
        }

        let args = parts[3]
        let command = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? args

        return ProcessSnapshot(
            pid: pid,
            parentPID: ppid,
            cpu: cpu,
            processName: URL(fileURLWithPath: command).lastPathComponent,
            commandLine: args
        )
    }

    private func relatedWindows(for app: NSRunningApplication, windows: [Int32: [WindowSnapshot]]) -> [WindowSnapshot] {
        let direct = windows[app.processIdentifier] ?? []
        let appName = app.localizedName?.nilIfBlank
        let ownerMatched = windows.values
            .flatMap { $0 }
            .filter { snapshot in
                guard let appName, let owner = snapshot.ownerName else { return false }
                return owner.localizedCaseInsensitiveContains(appName)
            }
        return Array(Set(direct + ownerMatched))
    }

    private func relatedProcesses(for app: NSRunningApplication, tool: ToolDefinition, processes: [ProcessSnapshot]) -> [ProcessSnapshot] {
        let appName = app.localizedName?.lowercased() ?? tool.name.lowercased()
        let bundlePath = app.bundleURL?.path.lowercased()
        return processes.filter { process in
            let command = process.commandLine.lowercased()
            if let bundlePath, command.contains(bundlePath) {
                return true
            }
            if command.contains("/applications/\(appName).app/") {
                return true
            }
            if command.contains("/applications/\(tool.name.lowercased()).app/") {
                return true
            }
            return tool.processNameHints.contains { process.processName.localizedCaseInsensitiveContains($0) }
                || tool.commandHints.contains { process.commandLine.localizedCaseInsensitiveContains($0) }
        }
    }

    private func nearestTerminalWindow(for process: ProcessSnapshot, windows: [Int32: [WindowSnapshot]]) -> WindowSnapshot? {
        let terminalOwners = ["Terminal", "iTerm2", "Warp", "Ghostty", "WezTerm"]
        return windows.values
            .flatMap { $0 }
            .first { snapshot in
                guard let owner = snapshot.ownerName else { return false }
                return terminalOwners.contains { owner.localizedCaseInsensitiveContains($0) }
                    && (snapshot.title?.localizedCaseInsensitiveContains(process.processName) == true
                        || snapshot.title?.localizedCaseInsensitiveContains("codex") == true
                        || snapshot.title?.localizedCaseInsensitiveContains("claude") == true
                        || snapshot.title?.localizedCaseInsensitiveContains("gemini") == true)
            }
    }

    private func terminalBundleIdentifier(for process: ProcessSnapshot) -> String? {
        guard let parent = NSRunningApplication(processIdentifier: process.parentPID) else {
            return nil
        }
        return parent.bundleIdentifier
    }

    private func bestWindowTitle(from windows: [WindowSnapshot]) -> String? {
        // 排除掉那些明显是辅助窗口的标题
        let noiseKeywords = ["settings", "preferences", "about", "open", "save", "panel", "service", "widget", "helper", "viewservice"]
        
        let meaningfulWindows = windows.filter { window in
            guard let title = window.title?.lowercased() else { return false }
            return !title.isEmpty && !noiseKeywords.contains(where: { title.contains($0) })
        }
        
        // 优先找包含分隔符的标题，这通常是 "项目 - 文件" 的格式
        let workspaceWindows = meaningfulWindows.filter { window in
            let title = window.title ?? ""
            return title.contains(" — ") || title.contains(" - ") || title.contains(" | ") || title.contains(" (")
        }
        
        return (workspaceWindows.isEmpty ? (meaningfulWindows.isEmpty ? windows : meaningfulWindows) : workspaceWindows)
            .compactMap(\.title)
            .sorted { $0.count > $1.count }
            .first
    }

    private func inferDesktopStatus(app: NSRunningApplication, windows: [WindowSnapshot], processes: [ProcessSnapshot]) -> ActivityStatus {
        let text = ([app.localizedName, app.bundleIdentifier] + windows.map(\.title) + processes.map(\.commandLine)).compactMap { $0 }.joined(separator: " ")
        let cpu = processes.reduce(0) { $0 + $1.cpu }
        if cpu >= 3 {
            return .working
        }
        return inferStatus(from: text, fallback: app.isActive ? .working : .idle)
    }

    private func inferCLIStatus(process: ProcessSnapshot, terminalTitle: String?) -> ActivityStatus {
        let text = [process.commandLine, terminalTitle].compactMap { $0 }.joined(separator: " ")
        return inferStatus(from: text, fallback: .working)
    }

    private func inferStatus(from text: String, fallback: ActivityStatus) -> ActivityStatus {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            return .failed
        }
        if lower.contains("waiting") || lower.contains("needs input") || lower.contains("approve") || lower.contains("confirm") {
            return .waiting
        }
        if lower.contains("done") || lower.contains("complete") || lower.contains("finished") || lower.contains("lgtm") {
            return .done
        }
        if lower.contains("running") || lower.contains("working") || lower.contains("thinking") || lower.contains("generating") || lower.contains("processing") || lower.contains("streaming") {
            return .working
        }
        return fallback
    }

    private func inferProjectName(from title: String?, fallback: String?) -> String? {
        guard let title = title?.nilIfBlank else { return fallback?.nilIfBlank }

        // 核心提取逻辑：
        // 1. 提取括号里的内容 (通常是路径或项目)
        if let match = title.range(of: #"(?<=\().*?(?=\))"#, options: .regularExpression) {
            let candidate = String(title[match])
            if looksLikeProjectName(candidate) { return candidate }
        }
        
        // 2. 取分隔符后的内容 (很多 App 把项目名放后面，如 "File - Project")
        let separators = [" — ", " - ", " | "]
        for sep in separators {
            let parts = title.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            if parts.count > 1 {
                // 如果最后一部分是应用名，我们取倒数第二个
                let last = parts.last!
                if last.localizedCaseInsensitiveContains(fallback ?? "") || last.count < 3 {
                    return parts[parts.count - 2]
                }
                return last
            }
        }

        return looksLikeProjectName(title) ? title : fallback?.nilIfBlank
    }

    private func looksLikeProjectName(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let lower = value.lowercased()
        let noise = ["helper", "service", "webcontent", "crashpad"]
        return !noise.contains { lower.contains($0) }
    }

    private func isNoise(_ process: ProcessSnapshot) -> Bool {
        let lower = process.commandLine.lowercased()
        if lower.contains("readytowhip") {
            return true
        }
        if lower.contains("/applications/codex.app/contents/frameworks") {
            return true
        }
        if lower.contains("codex app-server") {
            return true
        }
        if lower.contains("chrome_crashpad_handler") {
            return true
        }
        if lower.contains("grep") || lower.contains("/bin/ps") {
            return true
        }
        if lower.contains("google chrome") || lower.contains("chrome helper") {
            return true
        }
        if lower.contains("codexbar") || lower.contains("codex login") {
            return true
        }
        return false
    }
}
