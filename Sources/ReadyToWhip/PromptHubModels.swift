import AppKit
import Foundation

enum PromptCLIToolID: String, CaseIterable, Codable, Hashable, Identifiable {
    case antigravity
    case codex

    var id: String { rawValue }
}

struct PromptReasoningOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct PromptModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let reasoningOptions: [PromptReasoningOption]
    let defaultReasoningID: String

    func reasoningOption(for id: String) -> PromptReasoningOption {
        reasoningOptions.first { $0.id == id }
            ?? reasoningOptions.first { $0.id == defaultReasoningID }
            ?? reasoningOptions[0]
    }
}

struct PromptRunConfiguration: Hashable {
    let modelID: String
    let modelDisplayName: String
    let reasoningID: String
    let reasoningDisplayName: String
}

struct PromptCLITool: Identifiable, Hashable {
    let id: PromptCLIToolID
    let name: String
    let shortName: String
    let systemImage: String
    let accentColor: NSColor
    let executableCandidates: [String]

    var capturesFinalMessage: Bool {
        id == .codex
    }

    var streamsLiveOutput: Bool {
        id != .codex
    }

    var supportsNativeContinuation: Bool {
        true
    }

    func arguments(
        prompt: String,
        workingDirectory: URL,
        configuration: PromptRunConfiguration,
        finalMessageURL: URL?,
        nativeSessionID: String?
    ) -> [String] {
        switch id {
        case .antigravity:
            var arguments = [
                "--model", agyModelArgument(configuration: configuration),
                "--print", prompt
            ]
            if nativeSessionID != nil {
                arguments.insert("--continue", at: 0)
            }
            return arguments
        case .codex:
            let baseOptions = [
                "-m", configuration.modelID,
                "-c", "model_reasoning_effort=\(configuration.reasoningID)",
                "-c", "sandbox_mode=workspace-write",
                "--skip-git-repo-check"
            ]
            var arguments: [String]
            if let nativeSessionID {
                arguments = ["exec", "resume"] + baseOptions + [nativeSessionID, prompt]
            } else {
                arguments = [
                    "exec"
                ] + baseOptions + [
                    "--cd", workingDirectory.path,
                    "--sandbox", "workspace-write",
                    "--color", "never",
                    prompt
                ]
            }
            if let finalMessageURL {
                arguments.insert(contentsOf: ["--output-last-message", finalMessageURL.path], at: arguments.count - 1)
            }
            return arguments
        }
    }

    var modelOptions: [PromptModelOption] {
        switch id {
        case .antigravity:
            return [
                PromptModelOption(
                    id: "Gemini 3.5 Flash",
                    displayName: "Gemini 3.5 Flash",
                    reasoningOptions: [
                        PromptReasoningOption(id: "Low", displayName: "Low"),
                        PromptReasoningOption(id: "Medium", displayName: "Medium"),
                        PromptReasoningOption(id: "High", displayName: "High")
                    ],
                    defaultReasoningID: "High"
                ),
                PromptModelOption(
                    id: "Gemini 3.1 Pro",
                    displayName: "Gemini 3.1 Pro",
                    reasoningOptions: [
                        PromptReasoningOption(id: "Low", displayName: "Low"),
                        PromptReasoningOption(id: "High", displayName: "High")
                    ],
                    defaultReasoningID: "High"
                ),
                PromptModelOption(
                    id: "Claude Sonnet 4.6",
                    displayName: "Claude Sonnet 4.6",
                    reasoningOptions: [
                        PromptReasoningOption(id: "Thinking", displayName: "Thinking")
                    ],
                    defaultReasoningID: "Thinking"
                ),
                PromptModelOption(
                    id: "Claude Opus 4.6",
                    displayName: "Claude Opus 4.6",
                    reasoningOptions: [
                        PromptReasoningOption(id: "Thinking", displayName: "Thinking")
                    ],
                    defaultReasoningID: "Thinking"
                ),
                PromptModelOption(
                    id: "GPT-OSS 120B",
                    displayName: "GPT-OSS 120B",
                    reasoningOptions: [
                        PromptReasoningOption(id: "Medium", displayName: "Medium")
                    ],
                    defaultReasoningID: "Medium"
                )
            ]
        case .codex:
            let reasoning = [
                PromptReasoningOption(id: "low", displayName: "Low"),
                PromptReasoningOption(id: "medium", displayName: "Medium"),
                PromptReasoningOption(id: "high", displayName: "High"),
                PromptReasoningOption(id: "xhigh", displayName: "Extra High")
            ]
            return [
                PromptModelOption(id: "gpt-5.5", displayName: "GPT-5.5", reasoningOptions: reasoning, defaultReasoningID: "medium"),
                PromptModelOption(id: "gpt-5.4", displayName: "GPT-5.4", reasoningOptions: reasoning, defaultReasoningID: "medium"),
                PromptModelOption(id: "gpt-5.4-mini", displayName: "GPT-5.4-Mini", reasoningOptions: reasoning, defaultReasoningID: "low"),
                PromptModelOption(id: "gpt-5.2", displayName: "GPT-5.2", reasoningOptions: reasoning, defaultReasoningID: "medium")
            ]
        }
    }

    var defaultModel: PromptModelOption {
        modelOptions[0]
    }

    func modelOption(for id: String) -> PromptModelOption {
        modelOptions.first { $0.id == id } ?? defaultModel
    }

    func configuration(modelID: String, reasoningID: String) -> PromptRunConfiguration {
        let model = modelOption(for: modelID)
        let reasoning = model.reasoningOption(for: reasoningID)
        return PromptRunConfiguration(
            modelID: model.id,
            modelDisplayName: model.displayName,
            reasoningID: reasoning.id,
            reasoningDisplayName: reasoning.displayName
        )
    }

    var fallbackExecutableName: String {
        executableCandidates.first?.components(separatedBy: "/").last ?? name
    }

    private func agyModelArgument(configuration: PromptRunConfiguration) -> String {
        "\(configuration.modelDisplayName) (\(configuration.reasoningDisplayName))"
    }
}

enum PromptCLITools {
    static let all: [PromptCLITool] = [
        PromptCLITool(
            id: .antigravity,
            name: "agy CLI",
            shortName: "agy",
            systemImage: "sparkles.rectangle.stack",
            accentColor: .systemPurple,
            executableCandidates: [
                "agy",
                "/Users/\(NSUserName())/.local/bin/agy"
            ]
        ),
        PromptCLITool(
            id: .codex,
            name: "Codex CLI",
            shortName: "Codex",
            systemImage: "terminal",
            accentColor: .systemBlue,
            executableCandidates: ["codex"]
        )
    ]

    static func tool(for id: PromptCLIToolID) -> PromptCLITool {
        all.first { $0.id == id } ?? all[0]
    }
}

enum PromptRunStatus: String, Codable, Hashable {
    case queued = "Queued"
    case running = "Running"
    case done = "Done"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "waveform"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .queued: .secondaryLabelColor
        case .running: .systemBlue
        case .done: .systemGreen
        case .failed: .systemRed
        case .cancelled: .systemOrange
        }
    }
}

enum PromptMessageRole: String, Codable, Hashable {
    case user
    case assistant
    case diagnostic
}

struct PromptHubMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: PromptMessageRole
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: PromptMessageRole, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct PromptCLIRun: Identifiable, Hashable {
    let id: UUID
    let tool: PromptCLITool
    var prompt: String
    let workingDirectory: URL
    let configuration: PromptRunConfiguration
    var status: PromptRunStatus
    var messages: [PromptHubMessage]
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var resolvedExecutablePath: String?
    var commandPreview: String?
    var nativeSessionID: String?

    init(tool: PromptCLITool, prompt: String, workingDirectory: URL, configuration: PromptRunConfiguration) {
        self.id = UUID()
        self.tool = tool
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.configuration = configuration
        self.status = .queued
        self.messages = [
            PromptHubMessage(role: .user, text: prompt)
        ]
        self.startedAt = Date()
    }

    var title: String {
        let trimmed = latestUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled prompt" }
        return trimmed.count > 52 ? String(trimmed.prefix(52)) + "..." : trimmed
    }

    var latestUserPrompt: String {
        messages.last(where: { $0.role == .user })?.text ?? prompt
    }

    var statusLine: String {
        if let exitCode {
            return "\(status.rawValue) · exit \(exitCode)"
        }
        return status.rawValue
    }
}

struct PromptToolAvailability: Hashable {
    var executablePath: String?
    var isAvailable: Bool { executablePath != nil }

    var displayText: String {
        executablePath ?? "Command not found"
    }
}
