import Foundation

enum PromptOutputStream {
    case stdout
    case stderr
}

struct PromptCLIProcessLaunch {
    let process: Process
    let executablePath: String
    let commandPreview: String
}

enum PromptCLIRunnerError: LocalizedError {
    case executableNotFound(String, [String])
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name, let candidates):
            let tried = candidates.joined(separator: ", ")
            return "\(name) command was not found. Tried: \(tried)"
        case .launchFailed(let message):
            return message
        }
    }
}

final class PromptCLIRunner {
    private let fileManager = FileManager.default

    func availability(for tool: PromptCLITool) -> PromptToolAvailability {
        PromptToolAvailability(executablePath: resolveExecutable(candidates: tool.executableCandidates)?.path)
    }

    func start(
        tool: PromptCLITool,
        prompt: String,
        workingDirectory: URL,
        configuration: PromptRunConfiguration,
        onOutput: @escaping @Sendable (PromptOutputStream, String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> PromptCLIProcessLaunch {
        guard let executableURL = resolveExecutable(candidates: tool.executableCandidates) else {
            throw PromptCLIRunnerError.executableNotFound(tool.name, tool.executableCandidates)
        }

        let arguments = tool.arguments(prompt: prompt, workingDirectory: workingDirectory, configuration: configuration)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = processEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onOutput(.stdout, Self.cleanedOutput(text))
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onOutput(.stderr, Self.cleanedOutput(text))
        }

        process.terminationHandler = { finishedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            onTermination(finishedProcess.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw PromptCLIRunnerError.launchFailed(error.localizedDescription)
        }

        return PromptCLIProcessLaunch(
            process: process,
            executablePath: executableURL.path,
            commandPreview: commandPreview(executablePath: executableURL.path, arguments: arguments)
        )
    }

    func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    func resolveExecutable(candidates: [String]) -> URL? {
        for candidate in candidates {
            if let url = resolveAbsoluteOrRelativePath(candidate) {
                return url
            }
            if let url = resolveFromPath(candidate) {
                return url
            }
        }
        return nil
    }

    private func resolveAbsoluteOrRelativePath(_ candidate: String) -> URL? {
        let expanded = (candidate as NSString).expandingTildeInPath
        guard expanded.contains("/") else { return nil }
        guard fileManager.isExecutableFile(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private func resolveFromPath(_ executableName: String) -> URL? {
        guard !executableName.contains("/") else { return nil }
        for directory in searchPathDirectories() {
            let path = directory.appendingPathComponent(executableName).path
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func searchPathDirectories() -> [URL] {
        let fallback = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Users/\(NSUserName())/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let paths = (fallback + inherited).reduce(into: [String]()) { result, path in
            guard !result.contains(path) else { return }
            result.append(path)
        }
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = searchPathDirectories().map(\.path).joined(separator: ":")
        environment["PATH"] = path
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        return environment
    }

    private func commandPreview(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanedOutput(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }
}
