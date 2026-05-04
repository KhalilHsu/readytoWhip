import AppKit
import Foundation

enum ActivityStatus: String, CaseIterable, Codable, Hashable {
    case working = "Working"
    case done = "Done"
    case waiting = "Waiting"
    case failed = "Failed"
    case idle = "Idle"
    case unknown = "Unknown"

    var displayName: String { rawValue }

    var priority: Int {
        switch self {
        case .working: 0
        case .waiting: 1
        case .failed: 2
        case .done: 3
        case .idle: 4
        case .unknown: 5
        }
    }

    var systemColor: NSColor {
        switch self {
        case .working: .systemBlue
        case .waiting: .systemOrange
        case .failed: .systemRed
        case .done: .systemGreen
        case .idle: .tertiaryLabelColor
        case .unknown: .secondaryLabelColor
        }
    }
}

enum ActivitySource: String, Codable, Hashable {
    case desktopApp = "Desktop App"
    case cli = "CLI"
    case terminalSession = "Terminal"
}

struct AIActivity: Identifiable, Codable, Hashable {
    let id: String
    let toolName: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
    let source: ActivitySource
    let status: ActivityStatus
    let projectName: String?
    let windowTitle: String?
    let commandLine: String?
    let lastUpdated: Date

    var subtitle: String {
        let project = projectName?.nilIfBlank ?? windowTitle?.nilIfBlank ?? source.rawValue
        return project
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
