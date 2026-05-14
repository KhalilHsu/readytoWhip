import AppKit
import Foundation
import SQLite3

struct AppRuntimeContext {
    let codexPID: Int32?
    let cursorPID: Int32?
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
        CodexCLITaskStateAdapter(),
        CursorTaskStateAdapter(),
        AntigravityTaskStateAdapter(),
        GeminiTaskStateAdapter(),
        ClaudeCodeTaskStateAdapter()
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

private struct CodexRolloutSignal {
    let status: ActivityStatus
    let lastEventAt: TimeInterval?
    let summary: String?
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
            let rolloutAge = rolloutStatus?.lastEventAt.map { now - $0 } ?? .greatestFiniteMagnitude
            let status = codexStatus(
                rolloutStatus: rolloutStatus,
                updatedAge: updatedAge,
                logAge: logAge,
                rolloutAge: rolloutAge
            )
            guard status != .idle else { return nil }

            let lastUpdated = max(thread.updatedAt, max(lastLog, rolloutStatus?.lastEventAt ?? 0))
            let title = compactCodexTitle(thread.title)

            return AIActivity(
                id: "codex-thread-\(thread.id)",
                toolName: "Codex Desktop",
                bundleIdentifier: "com.openai.codex",
                processIdentifier: appPID ?? -1,
                source: .desktopApp,
                status: status,
                projectName: projectName(cwd: thread.cwd, title: title),
                windowTitle: rolloutStatus?.summary ?? title,
                commandLine: "thread \(thread.id.prefix(8)) · \(ageText(seconds: now - lastUpdated))",
                lastUpdated: Date(timeIntervalSince1970: lastUpdated)
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
        limit 16
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

    private func inferFromRollout(path: String) -> CodexRolloutSignal? {
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

        let lines = text.split(separator: "\n").suffix(220).map(String.init).reversed()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let eventType = json["type"] as? String
            let eventAt = parseCodexTimestamp(json["timestamp"] as? String)
            let payload = json["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if eventType == "event_msg" {
                if payloadType == "task_complete" {
                    return CodexRolloutSignal(status: .done, lastEventAt: eventAt, summary: "Task complete")
                }
                if payloadType == "agent_message",
                   let phase = payload?["phase"] as? String,
                   phase.localizedCaseInsensitiveContains("final") {
                    return CodexRolloutSignal(status: .done, lastEventAt: eventAt, summary: "Final answer")
                }
                if payloadType == "approval_request" || payloadType == "tool_approval_request" {
                    return CodexRolloutSignal(status: .waiting, lastEventAt: eventAt, summary: "Needs approval")
                }
                continue
            }

            guard eventType == "response_item" else { continue }

            if payloadType == "message" {
                let role = payload?["role"] as? String
                let phase = payload?["phase"] as? String
                if role == "assistant", phase?.localizedCaseInsensitiveContains("final") == true {
                    return CodexRolloutSignal(status: .done, lastEventAt: eventAt, summary: "Final answer")
                }
                if role == "user" {
                    return CodexRolloutSignal(status: .working, lastEventAt: eventAt, summary: "New user request")
                }
                continue
            }

            if payloadType == "function_call" || payloadType == "function_call_output" || payloadType == "reasoning" {
                return CodexRolloutSignal(status: .working, lastEventAt: eventAt, summary: codexSummary(payload: payload))
            }

            if payloadType == "custom_tool_call" {
                return CodexRolloutSignal(status: .working, lastEventAt: eventAt, summary: payload?["name"] as? String)
            }

            if payloadType == "local_shell_call" {
                return CodexRolloutSignal(
                    status: .working,
                    lastEventAt: eventAt,
                    summary: "Shell command"
                )
            }
        }

        return nil
    }

    private func codexStatus(
        rolloutStatus: CodexRolloutSignal?,
        updatedAge: TimeInterval,
        logAge: TimeInterval,
        rolloutAge: TimeInterval
    ) -> ActivityStatus {
        if let rolloutStatus {
            switch rolloutStatus.status {
            case .working:
                if rolloutAge <= 2 * 60 || logAge <= 45 {
                    return .working
                }
            case .waiting:
                if rolloutAge <= 30 * 60 {
                    return .waiting
                }
            case .done:
                if rolloutAge <= 10 * 60 {
                    return .done
                }
            case .failed:
                if rolloutAge <= 30 * 60 {
                    return .failed
                }
            case .idle, .unknown:
                break
            }
        }
        if logAge <= 45 {
            return .working
        }
        if updatedAge <= 60 {
            return .working
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

    private func compactCodexTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 {
            return trimmed
        }
        if let firstLine = trimmed.split(separator: "\n").first {
            return String(firstLine.prefix(80))
        }
        return String(trimmed.prefix(80))
    }

    private func codexSummary(payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        if let name = payload["name"] as? String {
            return name
        }
        switch payload["type"] as? String {
        case "function_call_output":
            return "Tool result"
        case "reasoning":
            return "Reasoning"
        default:
            return payload["type"] as? String
        }
    }
}

private final class CodexCLITaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    func detect(context: AppRuntimeContext) -> [AIActivity] {
        detectCLITool(
            toolName: "Codex CLI",
            toolID: "codex-cli",
            processes: context.processes,
            windows: context.windows,
            matcher: isCodexCLIProcess
        )
    }
}

private final class ClaudeCodeTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    func detect(context: AppRuntimeContext) -> [AIActivity] {
        detectCLITool(
            toolName: "Claude Code",
            toolID: "claude-code",
            processes: context.processes,
            windows: context.windows,
            matcher: isClaudeCodeProcess
        )
    }
}

private final class CursorTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    func detect(context: AppRuntimeContext) -> [AIActivity] {
        guard let appPID = context.cursorPID else { return [] }

        let windows = appWindows(appPID: appPID, ownerHint: "Cursor", windows: context.windows)
            .filter { isMeaningfulWindowTitle($0.title) }
        let related = context.processes.filter { process in
            let command = process.commandLine.lowercased()
            return command.contains("/applications/cursor.app/")
                || process.processName.localizedCaseInsensitiveContains("Cursor")
        }
        let cpu = related.reduce(0) { $0 + $1.cpu }
        let title = bestSessionTitle(from: windows.map(\.title)) ?? latestVSCodeWorkspaceName(appSupportName: "Cursor")

        guard title != nil || cpu >= 1.0 else { return [] }

        let status: ActivityStatus
        if cpu >= 5.0 || textLooksWorking([title, related.map(\.commandLine).joined(separator: " ")]) {
            status = .working
        } else {
            status = .waiting
        }

        return [
            AIActivity(
                id: "cursor-app-\(appPID)",
                toolName: "Cursor",
                bundleIdentifier: "com.cursor.Cursor",
                processIdentifier: appPID,
                source: .desktopApp,
                status: status,
                projectName: inferProjectNameFromTitle(title) ?? title,
                windowTitle: title,
                commandLine: cpu > 0 ? "cpu \(String(format: "%.1f", cpu))%" : nil,
                lastUpdated: Date()
            )
        ]
    }
}

private final class AntigravityTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    private var supportRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity").path
    }

    /// Detect active Antigravity sessions using LOG CONTENT as the primary signal
    /// (modeled after Codex's structured-data approach), not CPU heuristics.
    func detect(context: AppRuntimeContext) -> [AIActivity] {
        let appPID = context.antigravityPID

        // App must be running
        guard appPID != nil else { return [] }

        let logSignal = latestLogSignal()
        let signalAge = logSignal.lastSignalDate.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // Must have recent agent activity — if no log signal within 10 minutes, nothing to show
        guard signalAge <= 10 * 60 else { return [] }

        // Find the active workspace
        let allWorkspaces = workspaces()
        guard !allWorkspaces.isEmpty else { return [] }

        // Try window title matching first
        let windows = appWindows(appPID: appPID!, ownerHint: "Antigravity", windows: context.windows)
        let activeWindowTitles = windows.compactMap(\.title).filter { isMeaningfulWindowTitle($0) }
        let windowMatched = allWorkspaces.filter { workspace in
            activeWindowTitles.contains { title in
                title.localizedCaseInsensitiveContains(workspace.name)
                    || title.localizedCaseInsensitiveContains(workspace.folderPath)
            }
        }

        // Use window-matched workspace, or fall back to most recently modified
        // (logs are global; the active workspace is the one being edited right now)
        let activeWorkspace: AntigravityWorkspace
        if let matched = windowMatched.first {
            activeWorkspace = matched
        } else if let recent = allWorkspaces
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .first {
            activeWorkspace = recent
        } else {
            return []
        }

        // Determine status purely from log signals
        let status = antigravityStatus(signal: logSignal)
        guard status != .idle else { return [] }

        let lastUpdated = logSignal.lastSignalDate ?? logSignal.date ?? Date()

        return [AIActivity(
            id: "antigravity-workspace-\(activeWorkspace.storageID)",
            toolName: "Antigravity",
            bundleIdentifier: "com.google.antigravity",
            processIdentifier: appPID ?? -1,
            source: .desktopApp,
            status: status,
            projectName: activeWorkspace.name,
            windowTitle: logSignal.summary,
            commandLine: logSignal.detail,
            lastUpdated: lastUpdated
        )]
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

    // MARK: - Log signal reading

    private func latestLogSignal() -> AntigravityLogSignal {
        // Prioritize ls-main.log — it has the richest AI activity signals
        let logsRoot = "\(supportRoot)/logs"
        guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: logsRoot) else {
            return AntigravityLogSignal(date: nil, summary: "No logs", detail: nil, lastSignalDate: nil)
        }

        // Only check the most recent session
        guard let latestSession = sessions.sorted(by: >).first else {
            return AntigravityLogSignal(date: nil, summary: "No logs", detail: nil, lastSignalDate: nil)
        }

        let sessionRoot = "\(logsRoot)/\(latestSession)"
        // ls-main.log is the primary signal source (contains planner_generator, streamGenerateContent)
        let primaryLog = "\(sessionRoot)/ls-main.log"
        if FileManager.default.fileExists(atPath: primaryLog) {
            let signal = parseLogFile(path: primaryLog)
            if signal.lastSignalDate != nil {
                return signal
            }
        }

        // Fallback: check other log files
        let fallbackFiles = [
            "\(sessionRoot)/cloudcode.log",
            "\(sessionRoot)/agent-window-console.log"
        ]
        for path in fallbackFiles where FileManager.default.fileExists(atPath: path) {
            let signal = parseLogFile(path: path)
            if signal.lastSignalDate != nil {
                return signal
            }
        }

        return AntigravityLogSignal(date: nil, summary: "No recent activity", detail: nil, lastSignalDate: nil)
    }

    /// Parse a single log file and extract the most recent meaningful signal.
    private func parseLogFile(path: String) -> AntigravityLogSignal {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date
        else {
            return AntigravityLogSignal(date: nil, summary: "Unreadable", detail: nil, lastSignalDate: nil)
        }

        let tail = tailText(path: path, maxBytes: 48_000)
        // Scan last 200 lines (not 50) to avoid signals being buried under noise
        let lines = tail.split(separator: "\n").suffix(200).map(String.init).reversed()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        for line in lines {
            // Only process lines with actual signal keywords — skip noise
            let signal: String? = {
                if line.localizedCaseInsensitiveContains("UNAVAILABLE")
                    || line.localizedCaseInsensitiveContains("No capacity") {
                    return "No model capacity"
                }
                if line.localizedCaseInsensitiveContains("quota exceeded") {
                    return "Quota exceeded"
                }
                if line.localizedCaseInsensitiveContains("Requesting planner")
                    || line.localizedCaseInsensitiveContains("planner_generator") {
                    return "Thinking..."
                }
                if line.localizedCaseInsensitiveContains("streamGenerateContent") {
                    return "Generating..."
                }
                if line.localizedCaseInsensitiveContains("consumeAgentStateStream") {
                    return "Agent stream active"
                }
                return nil
            }()

            guard let signal else { continue }

            // Parse timestamp from the beginning of the line: "2026-05-14 15:31:17.308 ..."
            let timestamp = String(line.prefix(23))
            let signalDate = formatter.date(from: timestamp)

            return AntigravityLogSignal(
                date: modified,
                summary: signal,
                detail: URL(fileURLWithPath: path).lastPathComponent,
                lastSignalDate: signalDate ?? modified
            )
        }

        return AntigravityLogSignal(date: modified, summary: "No recent activity", detail: nil, lastSignalDate: nil)
    }

    // MARK: - Status determination (purely log-based, no CPU)

    /// Determine status purely from log content and recency.
    /// Modeled after Codex's approach of reading structured event data.
    private func antigravityStatus(signal: AntigravityLogSignal) -> ActivityStatus {
        let signalAge = signal.lastSignalDate.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        // How recently the log FILE was written to (not the signal timestamp inside it)
        let fileAge = signal.date.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // 1. Error in the most recent signal
        let isError = signal.summary.contains("No model capacity")
            || signal.summary.contains("Quota exceeded")
        if isError && signalAge <= 5 * 60 {
            return .failed
        }

        // 2. Active AI work — the log file is STILL being written to (within 30 seconds)
        //    Unlike Codex which has "task_complete" events, Antigravity logs just stop
        //    writing when done. So file-modification recency = liveness.
        let isWorkSignal = signal.summary.contains("Thinking")
            || signal.summary.contains("Generating")
            || signal.summary.contains("Agent stream active")
        if isWorkSignal && fileAge <= 30 {
            return .working
        }

        // 3. Had work recently, log file stopped being written → done
        if isWorkSignal && signalAge <= 10 * 60 {
            return .done
        }

        // 4. No recent signal → idle
        return .idle
    }
}


private final class GeminiTaskStateAdapter: ToolStateAdapter, @unchecked Sendable {
    private var tmpRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp").path
    }

    func detect(context: AppRuntimeContext) -> [AIActivity] {
        let geminiProcesses = context.processes.filter(isGeminiCLIProcess)
        guard !geminiProcesses.isEmpty else { return [] }

        guard let userDirs = try? FileManager.default.contentsOfDirectory(atPath: tmpRoot) else { return [] }
        
        // Collect all candidate sessions with their freshness
        var candidates: [(userDir: String, sessionId: String, lastMsg: String, lastUpdate: Date, sessionPath: String?)] = []
        
        for userDir in userDirs {
            let logsPath = "\(tmpRoot)/\(userDir)/logs.json"
            guard let logsAttrs = try? FileManager.default.attributesOfItem(atPath: logsPath),
                  let logsModDate = logsAttrs[.modificationDate] as? Date else {
                continue
            }
            
            // Skip sessions whose logs.json hasn't been touched in over 10 minutes
            // — these are definitely not the active session
            let logsAge = abs(logsModDate.timeIntervalSinceNow)
            guard logsAge < 10 * 60 else { continue }
            
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
            let lastLogDate = formatter.date(from: timestampStr) ?? logsModDate
            
            // Find the session chat file for more precise timing
            let chatsDir = "\(tmpRoot)/\(userDir)/chats"
            var lastUpdate = max(lastLogDate, logsModDate)
            var sessionPath: String? = nil
            
            if let chatFiles = try? FileManager.default.contentsOfDirectory(atPath: chatsDir),
               let sessionFile = chatFiles.first(where: { $0.contains(sessionId) }) {
                let path = "\(chatsDir)/\(sessionFile)"
                sessionPath = path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let modDate = attrs[.modificationDate] as? Date {
                    lastUpdate = max(lastUpdate, modDate)
                }
            }
            
            candidates.append((userDir, sessionId, lastMsg, lastUpdate, sessionPath))
        }
        
        // No recent sessions → nothing to show
        guard !candidates.isEmpty else { return [] }
        
        // Sort by most recent first — typically only one session is active
        candidates.sort { $0.lastUpdate > $1.lastUpdate }
        
        var activities: [AIActivity] = []
        for candidate in candidates {
            let timeAge = abs(candidate.lastUpdate.timeIntervalSinceNow)
            
            // Determine working state from the session file content (not global CPU)
            var isWorking = false
            if let sessionPath = candidate.sessionPath {
                let tail = tailText(path: sessionPath, maxBytes: 8000)
                if tail.contains("\"toolCalls\":") && !tail.contains("\"status\":\"success\"") {
                    isWorking = true
                } else if tail.contains("thoughts") && !tail.contains("\"content\":") {
                    isWorking = true
                }
                // Session file modified within 5 seconds → actively writing
                if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionPath),
                   let modDate = attrs[.modificationDate] as? Date,
                   abs(modDate.timeIntervalSinceNow) < 5 {
                    isWorking = true
                }
            }
            
            let status: ActivityStatus
            if isWorking || timeAge < 10 {
                status = .working
            } else if timeAge < 5 * 60 {
                status = .done
            } else {
                // > 5 minutes old → not worth showing
                continue
            }
            
            // Read project name
            var projectName = "Unknown Project"
            if let rootData = FileManager.default.contents(atPath: "\(tmpRoot)/\(candidate.userDir)/.project_root"),
               let rootPath = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if rootPath == FileManager.default.homeDirectoryForCurrentUser.path {
                    projectName = "Home (~)"
                } else {
                    projectName = URL(fileURLWithPath: rootPath).lastPathComponent
                }
            }
            // Fallback to process CWD
            if projectName == "Unknown Project", let pid = geminiProcesses.first?.pid {
                if let cwd = getProcessCWD(pid: pid), cwd != "/" {
                    if cwd == FileManager.default.homeDirectoryForCurrentUser.path {
                        projectName = "Home (~)"
                    } else {
                        projectName = URL(fileURLWithPath: cwd).lastPathComponent
                    }
                }
            }
            
            activities.append(AIActivity(
                id: "gemini-\(candidate.sessionId)",
                toolName: "Gemini CLI",
                bundleIdentifier: nil,
                processIdentifier: geminiProcesses.first?.pid ?? -1,
                source: .cli,
                status: status,
                projectName: projectName,
                windowTitle: candidate.lastMsg,
                commandLine: "session \(candidate.sessionId.prefix(8))",
                lastUpdated: candidate.lastUpdate
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
    let lastSignalDate: Date?
}

private func detectCLITool(
    toolName: String,
    toolID: String,
    processes: [ProcessSnapshot],
    windows: [Int32: [WindowSnapshot]],
    matcher: (ProcessSnapshot) -> Bool
) -> [AIActivity] {
    let candidates = processes.filter { matcher($0) && !isGeneralProcessNoise($0) }
    guard !candidates.isEmpty else { return [] }

    let grouped = Dictionary(grouping: candidates) { process -> String in
        if let terminal = nearestTerminalWindow(for: process, windows: windows) {
            return "terminal-\(terminal.pid)"
        }
        if let cwd = getProcessCWD(pid: process.pid), !cwd.isEmpty {
            return "cwd-\(cwd)"
        }
        return "pid-\(process.pid)"
    }

    return grouped.compactMap { key, items in
        guard let process = items.sorted(by: { $0.cpu > $1.cpu }).first else { return nil }
        let terminal = nearestTerminalWindow(for: process, windows: windows)
        let cwd = getProcessCWD(pid: process.pid)
        let title = terminal?.title?.nilIfBlank
        let text = ([title, cwd] + items.map(\.commandLine)).compactMap { $0 }.joined(separator: " ")
        let cpu = items.reduce(0) { $0 + $1.cpu }
        let status = cliStatus(text: text, cpu: cpu)

        return AIActivity(
            id: "\(toolID)-\(key)",
            toolName: toolName,
            bundleIdentifier: terminalBundleIdentifier(for: process),
            processIdentifier: process.pid,
            source: .cli,
            status: status,
            projectName: inferProjectNameFromTitle(title) ?? projectNameFromCWD(cwd),
            windowTitle: title,
            commandLine: process.commandLine,
            lastUpdated: Date()
        )
    }
}

private func cliStatus(text: String, cpu: Double) -> ActivityStatus {
    let lower = text.lowercased()
    if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
        return .failed
    }
    if cpu >= 1.0 || textLooksWorking([text]) {
        return .working
    }
    if lower.contains("approve") || lower.contains("confirm") || lower.contains("permission") || lower.contains("waiting") || lower.contains("needs input") {
        return .waiting
    }
    return .waiting
}

private func isCodexCLIProcess(_ process: ProcessSnapshot) -> Bool {
    let lower = process.commandLine.lowercased()
    let executable = executableBasename(process.commandLine)
    guard !lower.contains("/applications/codex.app/"),
          !lower.contains(".app/contents/"),
          !lower.contains("codex computer use.app"),
          !lower.contains("codex app-server"),
          !lower.contains("codexbar"),
          !lower.contains("codex login"),
          !lower.contains("codex auth"),
          !lower.contains("node_repl")
    else {
        return false
    }

    return executable == "codex"
        || lower.contains("/@openai/codex/")
        || lower.contains("/node_modules/@openai/codex/")
        || lower.contains("/bin/codex")
}

private func isGeminiCLIProcess(_ process: ProcessSnapshot) -> Bool {
    let lower = process.commandLine.lowercased()
    let executable = executableBasename(process.commandLine)
    guard !lower.contains("/applications/"),
          !lower.contains("/.gemini/antigravity"),
          !lower.contains("antigravity"),
          !lower.contains("google chrome"),
          !lower.contains("chrome helper")
    else {
        return false
    }

    return executable == "gemini"
        || lower.contains("@google/gemini-cli")
        || lower.contains("/node_modules/gemini")
        || lower.contains("/bin/gemini")
}

private func isClaudeCodeProcess(_ process: ProcessSnapshot) -> Bool {
    let lower = process.commandLine.lowercased()
    let executable = executableBasename(process.commandLine)
    guard !lower.contains("/applications/"),
          !lower.contains("claude login"),
          !lower.contains("claude auth")
    else {
        return false
    }

    return executable == "claude"
        || lower.contains("@anthropic-ai/claude-code")
        || lower.contains("/node_modules/claude")
        || lower.contains("/bin/claude")
}

private func isGeneralProcessNoise(_ process: ProcessSnapshot) -> Bool {
    let lower = process.commandLine.lowercased()
    return lower.contains("readytowhip")
        || lower.contains("/bin/ps")
        || lower.contains(" rg ")
        || lower.hasSuffix("/rg")
        || lower.contains("grep")
        || lower.contains("crashpad")
}

private func executableBasename(_ commandLine: String) -> String {
    let first = commandLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? commandLine
    return URL(fileURLWithPath: first).lastPathComponent.lowercased()
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

private func appWindows(appPID: Int32, ownerHint: String, windows: [Int32: [WindowSnapshot]]) -> [WindowSnapshot] {
    let direct = windows[appPID] ?? []
    let ownerMatched = windows.values
        .flatMap { $0 }
        .filter { $0.ownerName?.localizedCaseInsensitiveContains(ownerHint) == true }
    return Array(Set(direct + ownerMatched))
}

private func isMeaningfulWindowTitle(_ title: String?) -> Bool {
    guard let title = title?.nilIfBlank?.lowercased() else { return false }
    let noise = ["settings", "preferences", "about", "open", "save", "panel", "service", "helper", "viewservice", "crashpad"]
    return !noise.contains { title.contains($0) }
}

private func bestSessionTitle(from titles: [String?]) -> String? {
    let meaningful = titles.compactMap { $0?.nilIfBlank }.filter { isMeaningfulWindowTitle($0) }
    return meaningful
        .sorted { lhs, rhs in
            if lhs.contains(" — ") != rhs.contains(" — ") {
                return lhs.contains(" — ")
            }
            return lhs.count > rhs.count
        }
        .first
}

private func inferProjectNameFromTitle(_ title: String?) -> String? {
    guard let title = title?.nilIfBlank else { return nil }
    let separators = [" — ", " - ", " | "]
    for separator in separators {
        let parts = title.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.count > 1 {
            return parts.last
        }
    }
    return title
}

private func textLooksWorking(_ values: [String?]) -> Bool {
    let lower = values.compactMap { $0 }.joined(separator: " ").lowercased()
    return lower.contains("running")
        || lower.contains("working")
        || lower.contains("thinking")
        || lower.contains("generating")
        || lower.contains("streaming")
        || lower.contains("processing")
}

private func projectNameFromCWD(_ cwd: String?) -> String? {
    guard let cwd = cwd?.nilIfBlank, cwd != "/" else { return nil }
    if cwd == FileManager.default.homeDirectoryForCurrentUser.path {
        return "Home (~)"
    }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

private func latestVSCodeWorkspaceName(appSupportName: String) -> String? {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(appSupportName)/User/workspaceStorage")
        .path
    guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }

    return dirs.compactMap { dir -> (String, Date)? in
        let workspacePath = "\(root)/\(dir)/workspace.json"
        let statePath = "\(root)/\(dir)/state.vscdb"
        guard let data = FileManager.default.contents(atPath: workspacePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folderPath = filePath(from: (json["folder"] as? String) ?? (json["workspace"] as? String))
        else {
            return nil
        }

        let modified = ((try? FileManager.default.attributesOfItem(atPath: statePath))?[.modificationDate] as? Date)
            ?? ((try? FileManager.default.attributesOfItem(atPath: workspacePath))?[.modificationDate] as? Date)
            ?? .distantPast
        return (URL(fileURLWithPath: folderPath).lastPathComponent, modified)
    }
    .sorted { $0.1 > $1.1 }
    .first?
    .0
}

private func parseCodexTimestamp(_ value: String?) -> TimeInterval? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date.timeIntervalSince1970
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)?.timeIntervalSince1970
}

private func newerDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        return max(lhs, rhs)
    case let (lhs?, nil):
        return lhs
    case let (nil, rhs?):
        return rhs
    case (nil, nil):
        return nil
    }
}

private func getProcessCWD(pid: Int32) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-F", "n"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    
    do {
        try process.run()
        guard waitForProcessExit(process, timeout: 1.2) else {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                return path.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    } catch {
        return nil
    }
    
    return nil
}

private func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        group.leave()
    }
    return group.wait(timeout: .now() + timeout) == .success
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
