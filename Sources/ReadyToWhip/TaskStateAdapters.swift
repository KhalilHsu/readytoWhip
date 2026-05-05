import AppKit
import Foundation
import SQLite3

struct AppRuntimeContext {
    let codexPID: Int32?
    let antigravityPID: Int32?
    let processes: [ProcessSnapshot]
    let windows: [Int32: [WindowSnapshot]]
}

protocol ToolStateAdapter: Sendable {
    func detect(context: AppRuntimeContext) -> [AIActivity]
}

enum TaskStateAdapters {
    static let adapters: [ToolStateAdapter] = [
        CodexTaskStateAdapter(),
        AntigravityTaskStateAdapter(),
        GeminiTaskStateAdapter()
    ]

    static func detect(context: AppRuntimeContext) -> [AIActivity] {
        adapters.flatMap { $0.detect(context: context) }
    }
}

private struct CodexThreadRow {
    let id: String
    let title: String
    let cwd: String
    let rolloutPath: String
    let updatedAt: TimeInterval
}

private final class CodexTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    private var stateDB: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
    }
    private var logsDB: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/logs_2.sqlite").path
    }

    func detect(context: AppRuntimeContext) -> [AIActivity] {
        let appPID = context.codexPID
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

private final class AntigravityTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    private var supportRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity").path
    }

    func detect(context: AppRuntimeContext) -> [AIActivity] {
        let appPID = context.antigravityPID
        let processes = context.processes
        guard appPID != nil || FileManager.default.fileExists(atPath: supportRoot) else {
            return []
        }

        let logSignal = latestLogSignal()
        return workspaces().compactMap { workspace in
            let process = languageServerProcess(for: workspace, processes: processes)
            let workspaceAge = Date().timeIntervalSince(workspace.modifiedAt)
            
            // Only surface workspaces touched recently OR running an active language server process
            guard process != nil || workspaceAge <= 2 * 60 * 60 else {
                return nil
            }

            let status = antigravityStatus(workspace: workspace, process: process, signal: logSignal)
            let lastUpdated = max(workspace.modifiedAt, logSignal.date ?? .distantPast)
            let activeFile = activeFilename(storageID: workspace.storageID)

            return AIActivity(
                id: "antigravity-workspace-\(workspace.storageID)",
                toolName: "Antigravity",
                bundleIdentifier: "com.google.antigravity",
                processIdentifier: process?.pid ?? appPID ?? -1,
                source: .desktopApp,
                status: status,
                projectName: workspace.name,
                windowTitle: status == .failed ? logSignal.summary : (activeFile ?? workspace.name),
                commandLine: process.map { "language server pid \($0.pid) · cpu \(String(format: "%.1f", $0.cpu))%" } ?? logSignal.detail,
                lastUpdated: lastUpdated == .distantPast ? Date() : lastUpdated
            )
        }
    }

    private func activeFilename(storageID: String) -> String? {
        let dbPath = "\(supportRoot)/User/workspaceStorage/\(storageID)/state.vscdb"
        let query = "SELECT value FROM ItemTable WHERE key = 'memento/workbench.parts.editor'"
        guard let jsonStr = runSQLite(database: dbPath, query: query).first,
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let editorPart = json["editorpart.state"] as? [String: Any],
              let serializedGrid = editorPart["serializedGrid"] as? [String: Any],
              let root = serializedGrid["root"] as? [String: Any],
              let rootData = root["data"] as? [[String: Any]],
              let firstLeaf = rootData.first(where: { $0["type"] as? String == "leaf" }),
              let leafData = firstLeaf["data"] as? [String: Any],
              let editors = leafData["editors"] as? [[String: Any]],
              let mru = leafData["mru"] as? [Int],
              let activeIndex = mru.first,
              editors.indices.contains(activeIndex)
        else {
            return nil
        }
        
        let activeEditor = editors[activeIndex]
        if let valueStr = activeEditor["value"] as? String,
           let valueData = valueStr.data(using: .utf8),
           let valueJson = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
            
            if let resourceJSON = valueJson["resourceJSON"] as? [String: Any],
               let fsPath = resourceJSON["fsPath"] as? String {
                return URL(fileURLWithPath: fsPath).lastPathComponent
            }
            
            if let ariStr = valueJson["ari"] as? String,
               let ariData = ariStr.data(using: .utf8),
               let ariJson = try? JSONSerialization.jsonObject(with: ariData) as? [String: Any],
               let sourceUri = ariJson["sourceUri"] as? String {
                return URL(fileURLWithPath: sourceUri).lastPathComponent
            }
        }
        
        return nil
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
    }

    private func latestLogSignal() -> AntigravityLogSignal {
        let candidates = latestLogFiles()
        var best = AntigravityLogSignal(date: nil, summary: "No recent agent log", detail: nil, containsFatalError: false, containsWork: false)

        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date
            else {
                continue
            }

            let tail = tailText(path: path, maxBytes: 32_000)
            let isFatal = tail.localizedCaseInsensitiveContains("UNAVAILABLE")
                || tail.localizedCaseInsensitiveContains("No capacity available")
                || tail.localizedCaseInsensitiveContains("quota exceeded")
            
            let hasWork = tail.localizedCaseInsensitiveContains("POST v1internal")
                || tail.localizedCaseInsensitiveContains("Language server started")
                || tail.localizedCaseInsensitiveContains("agent")
            
            let isNewer = modified > (best.date ?? .distantPast)

            best = AntigravityLogSignal(
                date: isNewer ? modified : best.date,
                summary: isNewer ? summarizeAntigravityLog(tail: tail) : best.summary,
                detail: isNewer ? URL(fileURLWithPath: path).lastPathComponent : best.detail,
                containsFatalError: best.containsFatalError || isFatal,
                containsWork: best.containsWork || hasWork
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
        if let process, process.cpu >= 2.0 {
            return .working
        }
        // Fresh log with active work signals → agent is still running
        if logAge <= 2 * 60 && signal.containsWork {
            return .working
        }
        // Log existed but has gone quiet (2–15 min ago) and no process → agent just finished
        if logAge > 2 * 60 && logAge <= 15 * 60 && signal.containsWork && process == nil {
            return .done
        }
        // Process is idle but workspace is still warm
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

private final class GeminiTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    private var tmpRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp").path
    }

    func detect(context: AppRuntimeContext) -> [AIActivity] {
        let geminiProcesses = context.processes.filter { $0.commandLine.contains("gemini") && !$0.commandLine.contains("ReadyToWhip") && !$0.commandLine.contains("grep") }
        guard !geminiProcesses.isEmpty else { return [] }

        guard let userDirs = try? FileManager.default.contentsOfDirectory(atPath: tmpRoot) else { return [] }
        
        var activities: [AIActivity] = []
        for userDir in userDirs {
            let logsPath = "\(tmpRoot)/\(userDir)/logs.json"
            guard let data = FileManager.default.contents(atPath: logsPath),
                  let logs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let lastLog = logs.last,
                  let sessionId = lastLog["sessionId"] as? String,
                  let lastMsg = lastLog["message"] as? String,
                  let timestampStr = lastLog["timestamp"] as? String else {
                continue
            }
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let lastLogDate = formatter.date(from: timestampStr) ?? Date()
            
            // Look for the session jsonl file to check if it's done
            let chatsDir = "\(tmpRoot)/\(userDir)/chats"
            var isWorking = false
            var lastUpdate = lastLogDate
            
            if let chatFiles = try? FileManager.default.contentsOfDirectory(atPath: chatsDir) {
                if let sessionFile = chatFiles.first(where: { $0.contains(sessionId) }) {
                    let sessionPath = "\(chatsDir)/\(sessionFile)"
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionPath),
                       let modDate = attrs[.modificationDate] as? Date {
                        lastUpdate = max(lastUpdate, modDate)
                        let tail = tailText(path: sessionPath, maxBytes: 8000)
                        if tail.contains("\"toolCalls\":") && !tail.contains("\"status\":\"success\"") {
                            isWorking = true
                        } else if tail.contains("thoughts") && !tail.contains("\"content\":") {
                            isWorking = true
                        } else if abs(modDate.timeIntervalSinceNow) < 5 {
                            isWorking = true
                        }
                    }
                }
            }
            
            // Check CPU
            let cpu = geminiProcesses.reduce(0) { $0 + $1.cpu }
            if cpu > 1.0 {
                isWorking = true
            }
            
            // Read project root
            var projectName = "Unknown Project"
            if let rootData = FileManager.default.contents(atPath: "\(tmpRoot)/\(userDir)/.project_root"),
               let rootPath = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                projectName = URL(fileURLWithPath: rootPath).lastPathComponent
            }
            
            let timeAge = abs(lastUpdate.timeIntervalSinceNow)
            let status: ActivityStatus
            if isWorking || timeAge < 10 {
                status = .working
            } else if timeAge < 120 {
                status = .done
            } else if timeAge < 600 {
                status = .waiting
            } else {
                status = .idle
            }
            
            activities.append(AIActivity(
                id: "gemini-\(sessionId)",
                toolName: "Gemini CLI",
                bundleIdentifier: nil,
                processIdentifier: geminiProcesses.first?.pid ?? -1,
                source: .cli,
                status: status,
                projectName: projectName,
                windowTitle: lastMsg,
                commandLine: "session \(sessionId.prefix(8)) · cpu \(String(format: "%.1f", cpu))%",
                lastUpdated: lastUpdate
            ))
        }
        
        return activities
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
    var db: OpaquePointer?
    guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return []
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        return []
    }
    defer { sqlite3_finalize(statement) }

    var results: [String] = []
    let columnCount = sqlite3_column_count(statement)
    
    while sqlite3_step(statement) == SQLITE_ROW {
        var row: [String] = []
        for i in 0..<columnCount {
            if let cString = sqlite3_column_text(statement, i) {
                row.append(String(cString: cString))
            } else {
                row.append("")
            }
        }
        results.append(row.joined(separator: "\t"))
    }
    
    return results
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
