import Combine
import Foundation

@MainActor
final class PromptHubStore: ObservableObject {
    @Published private(set) var runs: [PromptCLIRun] = []
    @Published private(set) var availability: [PromptCLIToolID: PromptToolAvailability] = [:]
    @Published var selectedToolID: PromptCLIToolID = .antigravity
    @Published var selectedRunID: UUID?
    @Published var promptDraft: String = ""
    @Published var workingDirectoryPath: String
    @Published var selectedModelIDs: [PromptCLIToolID: String]
    @Published var selectedReasoningIDs: [PromptCLIToolID: String]

    let tools = PromptCLITools.all

    private let runner = PromptCLIRunner()
    private var processes: [UUID: Process] = [:]

    init() {
        workingDirectoryPath = Self.defaultWorkingDirectory().path
        selectedModelIDs = Dictionary(uniqueKeysWithValues: PromptCLITools.all.map { tool in
            (tool.id, tool.defaultModel.id)
        })
        selectedReasoningIDs = Dictionary(uniqueKeysWithValues: PromptCLITools.all.map { tool in
            (tool.id, tool.defaultModel.defaultReasoningID)
        })
        refreshAvailability()
    }

    var selectedTool: PromptCLITool {
        PromptCLITools.tool(for: selectedToolID)
    }

    var selectedRun: PromptCLIRun? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    var isRunningSelectedTool: Bool {
        runs.contains { $0.tool.id == selectedToolID && $0.status == .running }
    }

    var selectedModel: PromptModelOption {
        selectedTool.modelOption(for: selectedModelIDs[selectedToolID] ?? selectedTool.defaultModel.id)
    }

    var selectedReasoningOptions: [PromptReasoningOption] {
        selectedModel.reasoningOptions
    }

    var selectedConfiguration: PromptRunConfiguration {
        selectedTool.configuration(
            modelID: selectedModelIDs[selectedToolID] ?? selectedTool.defaultModel.id,
            reasoningID: selectedReasoningIDs[selectedToolID] ?? selectedModel.defaultReasoningID
        )
    }

    var canSendPrompt: Bool {
        let hasPrompt = !promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCommand = availability[selectedToolID]?.isAvailable == true
        let selectedRunIsIdle = selectedRun?.status != .running
        return hasPrompt && hasCommand && selectedRunIsIdle
    }

    func selectTool(_ toolID: PromptCLIToolID) {
        selectedToolID = toolID
        normalizeSelection(for: toolID)
        selectedRunID = nil
    }

    func selectRun(_ runID: UUID) {
        guard let run = runs.first(where: { $0.id == runID }) else { return }
        selectedRunID = runID
        selectedToolID = run.tool.id
        normalizeSelection(for: run.tool.id)
    }

    func setSelectedModelID(_ modelID: String) {
        selectedModelIDs[selectedToolID] = modelID
        let model = selectedTool.modelOption(for: modelID)
        let currentReasoningID = selectedReasoningIDs[selectedToolID]
        if currentReasoningID == nil || !model.reasoningOptions.contains(where: { $0.id == currentReasoningID }) {
            selectedReasoningIDs[selectedToolID] = model.defaultReasoningID
        }
        selectedRunID = nil
    }

    func setSelectedReasoningID(_ reasoningID: String) {
        selectedReasoningIDs[selectedToolID] = reasoningID
        selectedRunID = nil
    }

    func newConversation() {
        selectedRunID = nil
    }

    func refreshAvailability() {
        var refreshed: [PromptCLIToolID: PromptToolAvailability] = [:]
        for tool in tools {
            refreshed[tool.id] = runner.availability(for: tool)
        }
        availability = refreshed
    }

    func sendPrompt() {
        let prompt = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let tool = selectedTool
        let configuration = selectedConfiguration
        let existingRunID = reusableSelectedRunID(for: tool.id)
        promptDraft = ""

        if let existingRunID {
            updateRun(existingRunID) { run in
                run.prompt = prompt
                run.messages.append(PromptHubMessage(role: .user, text: prompt))
            }
            selectedRunID = existingRunID
            promoteRun(existingRunID)
            guard let run = selectedRun else { return }
            let executionPrompt = executionPrompt(for: run)
            start(
                runID: run.id,
                tool: run.tool,
                prompt: executionPrompt,
                workingDirectory: run.workingDirectory,
                configuration: run.configuration
            )
        } else {
            let run = PromptCLIRun(
                tool: tool,
                prompt: prompt,
                workingDirectory: resolvedWorkingDirectory(),
                configuration: configuration
            )

            runs.insert(run, at: 0)
            selectedRunID = run.id
            start(runID: run.id, tool: tool, prompt: prompt, workingDirectory: run.workingDirectory, configuration: configuration)
        }
    }

    func cancelSelectedRun() {
        guard let selectedRunID else { return }
        cancel(runID: selectedRunID)
    }

    func cancel(runID: UUID) {
        guard let process = processes[runID] else { return }
        runner.terminate(process)
        updateRun(runID) { run in
            run.status = .cancelled
            run.endedAt = Date()
            run.messages.append(PromptHubMessage(role: .diagnostic, text: "Cancelled by user."))
        }
        processes[runID] = nil
    }

    private func start(runID: UUID, tool: PromptCLITool, prompt: String, workingDirectory: URL, configuration: PromptRunConfiguration) {
        updateRun(runID) { run in
            run.status = .running
            run.startedAt = Date()
        }

        do {
            let launch = try runner.start(
                tool: tool,
                prompt: prompt,
                workingDirectory: workingDirectory,
                configuration: configuration,
                onOutput: { [weak self] stream, text in
                    DispatchQueue.main.async {
                        self?.appendOutput(text, stream: stream, to: runID)
                    }
                },
                onTermination: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.finish(runID: runID, termination: status)
                    }
                }
            )
            processes[runID] = launch.process
            updateRun(runID) { run in
                run.resolvedExecutablePath = launch.executablePath
                run.commandPreview = launch.commandPreview
            }
            refreshAvailability()
        } catch {
            updateRun(runID) { run in
                run.status = .failed
                run.endedAt = Date()
                run.messages.append(
                    PromptHubMessage(
                        role: .diagnostic,
                        text: error.localizedDescription
                    )
                )
            }
            refreshAvailability()
        }
    }

    private func appendOutput(_ text: String, stream: PromptOutputStream, to runID: UUID) {
        guard !text.isEmpty else { return }
        updateRun(runID) { run in
            switch stream {
            case .stdout:
                if run.messages.last?.role == .assistant, let index = run.messages.indices.last {
                    run.messages[index].text += text
                } else {
                    run.messages.append(PromptHubMessage(role: .assistant, text: text))
                }
            case .stderr:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if run.messages.last?.role == .diagnostic, let index = run.messages.indices.last {
                    run.messages[index].text += text
                } else {
                    run.messages.append(PromptHubMessage(role: .diagnostic, text: text))
                }
            }
        }
    }

    private func finish(runID: UUID, termination: PromptCLITermination) {
        processes[runID] = nil
        updateRun(runID) { run in
            guard run.status == .running || run.status == .queued else { return }
            run.exitCode = termination.status
            run.endedAt = Date()
            run.status = termination.status == 0 ? .done : .failed

            if let finalMessage = termination.finalMessage {
                run.messages.append(PromptHubMessage(role: .assistant, text: finalMessage))
            }

            let hasAssistantOutput = run.messages.contains {
                $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if termination.status != 0, let diagnosticOutput = termination.diagnosticOutput {
                run.messages.append(PromptHubMessage(role: .diagnostic, text: diagnosticOutput))
            } else if termination.status == 0 && !hasAssistantOutput {
                run.messages.append(
                    PromptHubMessage(
                        role: .diagnostic,
                        text: "\(run.tool.shortName) finished without stdout. The prompt may have opened in the provider app instead of returning text."
                    )
                )
            }
        }
    }

    private func reusableSelectedRunID(for toolID: PromptCLIToolID) -> UUID? {
        guard let selectedRunID,
              processes[selectedRunID] == nil,
              let run = runs.first(where: { $0.id == selectedRunID }),
              run.tool.id == toolID,
              run.status != .running
        else {
            return nil
        }
        return selectedRunID
    }

    private func promoteRun(_ runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }), index != 0 else { return }
        let run = runs.remove(at: index)
        runs.insert(run, at: 0)
    }

    private func executionPrompt(for run: PromptCLIRun) -> String {
        let chatMessages = run.messages.filter { $0.role == .user || $0.role == .assistant }
        guard chatMessages.count > 1 else {
            return run.latestUserPrompt
        }

        let transcript = chatMessages.map { message in
            switch message.role {
            case .user:
                return "User: \(message.text)"
            case .assistant:
                return "Assistant: \(message.text)"
            case .diagnostic:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        return """
        Continue the following conversation. Use the earlier messages as context and answer only the latest user message. Do not repeat the transcript.

        \(transcript)
        """
    }

    private func updateRun(_ runID: UUID, mutate: (inout PromptCLIRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        mutate(&runs[index])
    }

    private func normalizeSelection(for toolID: PromptCLIToolID) {
        let tool = PromptCLITools.tool(for: toolID)
        let model = tool.modelOption(for: selectedModelIDs[toolID] ?? tool.defaultModel.id)
        selectedModelIDs[toolID] = model.id
        let reasoningID = selectedReasoningIDs[toolID] ?? model.defaultReasoningID
        if model.reasoningOptions.contains(where: { $0.id == reasoningID }) {
            selectedReasoningIDs[toolID] = reasoningID
        } else {
            selectedReasoningIDs[toolID] = model.defaultReasoningID
        }
    }

    private func resolvedWorkingDirectory() -> URL {
        let expanded = (workingDirectoryPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: expanded)
        }
        return Self.defaultWorkingDirectory()
    }

    private static func defaultWorkingDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["READYTOWHIP_DEFAULT_CWD"],
            environment["PWD"],
            FileManager.default.homeDirectoryForCurrentUser.path
        ].compactMap { $0?.nilIfBlank }

        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
