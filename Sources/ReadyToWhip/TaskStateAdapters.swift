import AppKit
import Foundation

struct AppRuntimeContext {
    let codexPID: Int32?
    let antigravityPID: Int32?
    let processes: [ProcessSnapshot]
}

enum TaskStateAdapters {
    static func detect(context: AppRuntimeContext) -> [AIActivity] {
        CodexTaskStateAdapter().detect(appPID: context.codexPID)
            + AntigravityTaskStateAdapter().detect(appPID: context.antigravityPID, processes: context.processes)
    }
}

private struct CodexThreadRow {
    let id: String
    let title: String
    let cwd: String
    let rolloutPath: String
    let updatedAt: TimeInterval
}

private final class CodexTaskStateAdapter {
    private let stateDB = "/Users/khalil/.codex/state_5.sqlite"
    private let logsDB = "/Users/khalil/.codex/logs_2.sqlite"

    func detect(appPID: Int32?) -> [AIActivity] {
        guard FileManager.default.fileExists(atPath: stateDB) else { return [] }

        let threads = latestThreads()
        guard !threads.isEmpty else { return [] }

        let recentLogs = latestLogTimestamps()
        let now = Date().timeIntervalSince1970

        return threads.compactMap { thread in
            let lastLog = recentLogs[thread.id] ?? 0
            let rolloutStatus = inferFromRollout(path: thread.rolloutPath)
            let updatedAge = now - thread.updatedAt
            let logAge = lastLog > 0 ? now - lastLog : .greatestFiniteMagnitude
            let status = codexStatus(
                rolloutStatus: rolloutStatus,
                updatedAge: updatedAge,
                logAge: logAge
            )

            return AIActivity(
                id: "codex-thread-\(thread.id)",
                toolName: "Codex Desktop",
                bundleIdentifier: "com.openai.codex",
                processIdentifier: appPID ?? -1,
                source: .desktopApp,
                status: status,
                projectName: projectName(cwd: thread.cwd, title: thread.title),
                windowTitle: thread.title,
                commandLine: "thread \(thread.id.prefix(8)) · \(ageText(seconds: min(updatedAge, logAge)))",
                lastUpdated: Date(timeIntervalSince1970: max(thread.updatedAt, lastLog))
            )
        }
    }

    private func latestThreads() -> [CodexThreadRow] {
        let query = """
        select id,
               replace(title, char(9), ' '),
               replace(cwd, char(9), ' '),
               replace(rollout_path, char(9), ' '),
               coalesce(updated_at_ms, updated_at * 1000) / 1000.0
        from threads
        where archived = 0
        order by coalesce(updated_at_ms, updated_at * 1000) desc
        limit 8
        """

        return runSQLite(database: stateDB, query: query).compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5, let updatedAt = TimeInterval(parts[4]) else { return nil }
            return CodexThreadRow(
                id: parts[0],
                title: parts[1],
                cwd: parts[2],
                rolloutPath: parts[3],
                updatedAt: updatedAt
            )
        }
    }

    private func latestLogTimestamps() -> [String: TimeInterval] {
        guard FileManager.default.fileExists(atPath: logsDB) else { return [:] }

        let query = """
        select thread_id, max(ts)
        from logs
        where thread_id is not null
        group by thread_id
        order by max(ts) desc
        limit 32
        """

        var result: [String: TimeInterval] = [:]
        for line in runSQLite(database: logsDB, query: query) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let ts = TimeInterval(parts[1]) else { continue }
            result[parts[0]] = ts
        }
        return result
    }

    private func inferFromRollout(path: String) -> ActivityStatus? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path)
        else {
            return nil
        }

        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > 96_000 ? size - 96_000 : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n").suffix(160).map(String.init).reversed()
        for line in lines {
            if line.contains("\"type\":\"task_complete\"")
                || line.contains("\"phase\":\"final_answer\"")
                || line.contains("\"phase\":\"final\"") {
                return .done
            }
            if line.contains("\"type\":\"function_call\"")
                || line.contains("\"type\":\"function_call_output\"")
                || line.contains("\"type\":\"reasoning\"")
                || line.contains("\"type\":\"task_started\"")
                || line.contains("\"status\":\"in_progress\"")
                || line.contains("exec_command")
                || line.contains("apply_patch") {
                return .working
            }
            if line.contains("\"type\":\"user_message\"") || line.contains("\"role\":\"user\"") {
                return .waiting
            }
        }

        return nil
    }

    private func codexStatus(rolloutStatus: ActivityStatus?, updatedAge: TimeInterval, logAge: TimeInterval) -> ActivityStatus {
        if let rolloutStatus, updatedAge <= 15 * 60 {
            return rolloutStatus
        }
        if logAge <= 30 {
            return .working
        }
        if updatedAge <= 5 * 60 {
            return .waiting
        }
        return .idle
    }

    private func projectName(cwd: String, title: String) -> String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        if !last.isEmpty && last != "/" {
            return last
        }
        return title
    }
}

private final class AntigravityTaskStateAdapter {
    private let supportRoot = "/Users/khalil/Library/Application Support/Antigravity"

    func detect(appPID: Int32?, processes: [ProcessSnapshot]) -> [AIActivity] {
        guard appPID != nil || FileManager.default.fileExists(atPath: supportRoot) else {
            return []
        }

        let logSignal = latestLogSignal()
        return workspaces().map { workspace in
            let process = languageServerProcess(for: workspace, processes: processes)
            let status = antigravityStatus(workspace: workspace, process: process, signal: logSignal)
            let lastUpdated = max(workspace.modifiedAt, logSignal.date ?? .distantPast)

            return AIActivity(
                id: "antigravity-workspace-\(workspace.storageID)",
                toolName: "Antigravity",
                bundleIdentifier: "com.google.antigravity",
                processIdentifier: process?.pid ?? appPID ?? -1,
                source: .desktopApp,
                status: status,
                projectName: workspace.name,
                windowTitle: status == .failed ? logSignal.summary : workspace.folderPath,
                commandLine: process.map { "language server pid \($0.pid) · cpu \(String(format: "%.1f", $0.cpu))%" } ?? logSignal.detail,
                lastUpdated: lastUpdated == .distantPast ? Date() : lastUpdated
            )
        }
    }

    private func workspaces() -> [AntigravityWorkspace] {
        let root = "\(supportRoot)/User/workspaceStorage"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }

        return dirs.compactMap { dir in
            let path = "\(root)/\(dir)/workspace.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            let uri = (json["folder"] as? String) ?? (json["workspace"] as? String)
            guard let folderPath = filePath(from: uri) else { return nil }
            let statePath = "\(root)/\(dir)/state.vscdb"
            let modifiedAt = ((try? FileManager.default.attributesOfItem(atPath: statePath))?[.modificationDate] as? Date)
                ?? ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
                ?? .distantPast

            return AntigravityWorkspace(
                storageID: dir,
                folderPath: folderPath,
                name: URL(fileURLWithPath: folderPath).lastPathComponent,
                modifiedAt: modifiedAt
            )
        }
        .filter { !$0.name.isEmpty }
        // Only surface workspaces touched in the last 2 hours to avoid showing
        // all historical projects a user has ever opened in Antigravity.
        .filter { Date().timeIntervalSince($0.modifiedAt) <= 2 * 60 * 60 }
    }

    private func latestLogSignal() -> AntigravityLogSignal {
        let candidates = latestLogFiles()
        var best = AntigravityLogSignal(date: nil, summary: "No recent agent log", detail: nil, containsFatalError: false, containsWork: false)

        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > (best.date ?? .distantPast)
            else {
                continue
            }

            let tail = tailText(path: path, maxBytes: 32_000)
            best = AntigravityLogSignal(
                date: modified,
                summary: summarizeAntigravityLog(tail: tail),
                detail: URL(fileURLWithPath: path).lastPathComponent,
                containsFatalError: tail.localizedCaseInsensitiveContains("UNAVAILABLE")
                    || tail.localizedCaseInsensitiveContains("No capacity available")
                    || tail.localizedCaseInsensitiveContains("quota exceeded"),
                containsWork: tail.localizedCaseInsensitiveContains("POST v1internal")
                    || tail.localizedCaseInsensitiveContains("Language server started")
                    || tail.localizedCaseInsensitiveContains("agent")
            )
        }

        return best
    }

    private func latestLogFiles() -> [String] {
        let logsRoot = "\(supportRoot)/logs"
        guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: logsRoot) else {
            return []
        }

        return sessions
            .sorted(by: >)
            .prefix(3)
            .flatMap { session -> [String] in
                let sessionRoot = "\(logsRoot)/\(session)"
                var files = [
                    "\(sessionRoot)/cloudcode.log",
                    "\(sessionRoot)/agent-window-console.log",
                    "\(sessionRoot)/ls-main.log"
                ]

                if let windows = try? FileManager.default.contentsOfDirectory(atPath: sessionRoot) {
                    for window in windows where window.hasPrefix("window") {
                        files.append("\(sessionRoot)/\(window)/exthost/google.antigravity/Antigravity.log")
                    }
                }

                return files
            }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func languageServerProcess(for workspace: AntigravityWorkspace, processes: [ProcessSnapshot]) -> ProcessSnapshot? {
        let workspaceID = "file" + workspace.folderPath.replacingOccurrences(of: "/", with: "_")
        return processes
            .filter { process in
                process.commandLine.contains("language_server_macos")
                    && process.commandLine.contains("--workspace_id \(workspaceID)")
            }
            .sorted { $0.cpu > $1.cpu }
            .first
    }

    private func antigravityStatus(workspace: AntigravityWorkspace, process: ProcessSnapshot?, signal: AntigravityLogSignal) -> ActivityStatus {
        let workspaceAge = Date().timeIntervalSince(workspace.modifiedAt)
        let logAge = signal.date.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // Only mark failed if BOTH the log and the workspace are fresh,
        // preventing a single global log signal from tainting old workspaces.
        if logAge <= 2 * 60 && workspaceAge <= 5 * 60 && signal.containsFatalError && process == nil {
            return .failed
        }
        if let process, process.cpu >= 0.5 {
            return .working
        }
        // Tightened from 10 min → 5 min to reduce ghost entry duration.
        if process != nil || workspaceAge <= 5 * 60 {
            return .waiting
        }
        return .idle
    }

    private func summarizeAntigravityLog(tail: String) -> String {
        let lines = tail.split(separator: "\n").suffix(20).map(String.init).reversed()
        for line in lines {
            if line.localizedCaseInsensitiveContains("UNAVAILABLE") {
                return "No model capacity"
            }
            if line.localizedCaseInsensitiveContains("Language server started") {
                return "Language server active"
            }
            if line.localizedCaseInsensitiveContains("POST v1internal") {
                return "Cloud Code request"
            }
            if line.localizedCaseInsensitiveContains("Failed to get status") {
                return "Status probe failed"
            }
        }
        return lines.first?.nilIfBlank ?? "Antigravity"
    }
}

private struct AntigravityWorkspace {
    let storageID: String
    let folderPath: String
    let name: String
    let modifiedAt: Date
}

private struct AntigravityLogSignal {
    let date: Date?
    let summary: String
    let detail: String?
    let containsFatalError: Bool
    let containsWork: Bool
}

private func runSQLite(database: String, query: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-readonly", "-separator", "\t", database, query]

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
    return output.split(separator: "\n").map(String.init)
}

private func filePath(from uri: String?) -> String? {
    guard let uri else { return nil }
    if let url = URL(string: uri), url.isFileURL {
        return url.path
    }
    if uri.hasPrefix("file://") {
        return uri
            .replacingOccurrences(of: "file://", with: "")
            .removingPercentEncoding
    }
    return uri.removingPercentEncoding
}

private func tailText(path: String, maxBytes: UInt64) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    let offset = size > maxBytes ? size - maxBytes : 0
    try? handle.seek(toOffset: offset)
    let data = handle.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

private func ageText(seconds: TimeInterval) -> String {
    if seconds < 60 {
        return "\(Int(seconds))s ago"
    }
    if seconds < 3600 {
        return "\(Int(seconds / 60))m ago"
    }
    return "\(Int(seconds / 3600))h ago"
}
