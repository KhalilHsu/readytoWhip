import Foundation

struct ToolDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifiers: Set<String>
    let processNameHints: Set<String>
    let commandHints: Set<String>
}

enum ToolCatalog {
    static let supported: [ToolDefinition] = [
        ToolDefinition(
            id: "codex-desktop",
            name: "Codex Desktop",
            bundleIdentifiers: ["com.openai.chat", "com.openai.codex", "com.openai.Codex"],
            processNameHints: ["Codex"], // 移除小写的 codex，减少误伤
            commandHints: []
        ),
        ToolDefinition(
            id: "codex-cli",
            name: "Codex CLI",
            bundleIdentifiers: [],
            processNameHints: ["codex"],
            commandHints: ["codex"]
        ),
        ToolDefinition(
            id: "cursor",
            name: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"],
            processNameHints: ["Cursor"],
            commandHints: ["cursor"]
        ),
        ToolDefinition(
            id: "antigravity",
            name: "Antigravity",
            bundleIdentifiers: ["com.google.antigravity", "com.electron.antigravity"],
            processNameHints: ["Antigravity"],
            commandHints: ["Antigravity.app"]
        ),
        ToolDefinition(
            id: "gemini-cli",
            name: "Gemini CLI",
            bundleIdentifiers: [],
            processNameHints: ["gemini"],
            commandHints: ["gemini"]
        ),
        ToolDefinition(
            id: "claude-code",
            name: "Claude Code",
            bundleIdentifiers: [],
            processNameHints: ["claude"],
            commandHints: ["claude"]
        )
    ]

    static func desktopTool(for bundleIdentifier: String?, localizedName: String?) -> ToolDefinition? {
        supported.first { tool in
            if let bundleIdentifier, tool.bundleIdentifiers.contains(bundleIdentifier) {
                return true
            }
            if let localizedName {
                return tool.processNameHints.contains { localizedName.localizedCaseInsensitiveContains($0) }
            }
            return false
        }
    }

    static func cliTool(for commandLine: String, processName: String) -> ToolDefinition? {
        supported.first { tool in
            guard tool.bundleIdentifiers.isEmpty else {
                return false
            }
            return tool.commandHints.contains { commandLine.localizedCaseInsensitiveContains($0) }
                || tool.processNameHints.contains { processName.localizedCaseInsensitiveContains($0) }
        }
    }
}
