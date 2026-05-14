import Foundation

enum ActivityPrivacy {
    private static let sensitiveKeywords = [
        "bytedance",
        "字节",
        "feishu",
        "lark"
    ]

    static func redactedProjectName(_ text: String?) -> String? {
        guard let normalized = normalizedText(text) else { return nil }
        let candidate = projectLikeComponent(from: normalized) ?? normalized
        return truncate(redactSensitiveText(candidate), limit: 48)
    }

    static func redactedWindowTitle(_ text: String?) -> String? {
        guard let normalized = normalizedText(text) else { return nil }
        let candidate = titleLikeComponent(from: normalized) ?? normalized
        if shouldHideFreeformText(candidate, original: normalized) {
            return "detail hidden"
        }
        return truncate(redactSensitiveText(candidate), limit: 72)
    }

    static func redactedCommandLine(_ text: String?) -> String? {
        guard let normalized = normalizedText(text) else { return nil }
        let lower = normalized.lowercased()

        if lower.hasPrefix("thread ")
            || lower.hasPrefix("session ")
            || lower.hasPrefix("cpu ")
            || lower.hasPrefix("language server pid ")
        {
            return truncate(redactSensitiveText(normalized), limit: 72)
        }

        let executable = commandBasename(normalized)
        guard !executable.isEmpty else {
            return "command hidden"
        }
        return "\(executable) [command hidden]"
    }

    static func dumpFields(for activity: AIActivity, raw: Bool) -> [String] {
        if raw {
            return [
                activity.status.rawValue,
                activity.toolName,
                activity.projectName ?? "",
                activity.windowTitle ?? "",
                activity.commandLine ?? ""
            ]
        }

        return [
            activity.status.rawValue,
            activity.toolName,
            redactedProjectName(activity.projectName) ?? "",
            redactedWindowTitle(activity.windowTitle) ?? "",
            redactedCommandLine(activity.commandLine) ?? ""
        ]
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func redactSensitiveText(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var redacted = text.replacingOccurrences(of: home, with: "~")
        redacted = redacted.replacingOccurrences(
            of: #"/Users/[^/\s]+"#,
            with: "/Users/[user]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"\b[0-9a-fA-F]{8,}\b"#,
            with: "[id]",
            options: .regularExpression
        )

        for keyword in sensitiveKeywords {
            redacted = redacted.replacingOccurrences(
                of: keyword,
                with: "[REDACTED]",
                options: [.caseInsensitive, .regularExpression]
            )
        }

        return redacted
    }

    private static func projectLikeComponent(from text: String?) -> String? {
        guard let text else { return nil }
        if looksLikePath(text) {
            return pathTail(from: text)
        }
        return splitComponents(text).last(where: isMeaningfulComponent)
    }

    private static func titleLikeComponent(from text: String?) -> String? {
        guard let text else { return nil }
        if looksLikePath(text) {
            return pathTail(from: text)
        }

        let components = splitComponents(text).filter(isMeaningfulComponent)
        if let candidate = components.last {
            return candidate
        }
        return text
    }

    private static func splitComponents(_ text: String) -> [String] {
        let separators = [" — ", " - ", " | ", " · ", ":", "\n"]
        return separators
            .reduce([text]) { partial, separator in
                partial.flatMap { value in
                    value.components(separatedBy: separator)
                }
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isMeaningfulComponent(_ value: String) -> Bool {
        let lower = value.lowercased()
        let noise = [
            "terminal",
            "iterm2",
            "warp",
            "ghostty",
            "wezterm",
            "cursor",
            "codex",
            "claude",
            "gemini",
            "antigravity",
            "readytowhip"
        ]
        return !noise.contains(where: { lower == $0 })
    }

    private static func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            || value.hasPrefix("~/")
            || value.hasPrefix("file://")
            || value.contains("/Users/")
    }

    private static func shouldHideFreeformText(_ candidate: String, original: String) -> Bool {
        if looksLikePath(candidate) {
            return false
        }
        if candidate.count <= 32 {
            return false
        }
        if candidate.contains(".swift") || candidate.contains(".md") || candidate.contains(".ts") || candidate.contains(".js") {
            return false
        }
        return splitComponents(original).count <= 1
    }

    private static func pathTail(from value: String) -> String {
        let resolved: String
        if value.hasPrefix("file://"), let decoded = value.removingPercentEncoding {
            resolved = decoded.replacingOccurrences(of: "file://", with: "")
        } else {
            resolved = value.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        let tail = URL(fileURLWithPath: resolved).lastPathComponent
        return tail.isEmpty ? value : tail
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }

    private static func commandBasename(_ commandLine: String) -> String {
        let first = commandLine.split(separator: " ", maxSplits: 1).first.map(String.init) ?? commandLine
        return URL(fileURLWithPath: first).lastPathComponent.lowercased()
    }
}
