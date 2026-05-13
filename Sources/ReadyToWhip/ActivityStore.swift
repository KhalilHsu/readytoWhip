import AppKit
import Combine
import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var activities: [AIActivity] = []
    @Published var isExpanded = false
    @Published var lastRefresh: Date?

    private let detector = ActivityDetector()
    private var timer: Timer?
    private var isRefreshing = false

    var workingCount: Int { activities.filter { $0.status == .working }.count }
    var waitingCount: Int { activities.filter { $0.status == .waiting }.count }
    var doneCount: Int { activities.filter { $0.status == .done }.count }
    var failedCount: Int { activities.filter { $0.status == .failed }.count }
    var activeCount: Int { activities.filter { $0.status != .idle && $0.status != .unknown }.count }

    var headlineActivity: AIActivity? {
        activities.sorted {
            if $0.status.priority == $1.status.priority {
                return $0.lastUpdated > $1.lastUpdated
            }
            return $0.status.priority < $1.status.priority
        }.first
    }

    var petState: PetAnimationState {
        if failedCount > 0 {
            return .failed
        }
        if workingCount > 0 {
            return .running
        }
        if waitingCount > 0 {
            return .waiting
        }
        if doneCount > 0 {
            return .waving
        }
        return .idle
    }

    var bubbleMessage: String {
        guard let headlineActivity else {
            return "Waiting for your next AI session."
        }

        switch headlineActivity.status {
        case .working:
            return "\(headlineActivity.toolName) is active in \(headlineActivity.subtitle)."
        case .waiting:
            return "\(headlineActivity.toolName) is waiting for input."
        case .done:
            return "\(headlineActivity.toolName) wrapped up recently."
        case .failed:
            return "\(headlineActivity.toolName) may need attention."
        case .idle, .unknown:
            return "Monitoring supported tools in the background."
        }
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: SettingsStore.shared.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let disabledTools = SettingsStore.shared.disabledTools
        let enabledTools = Set(ToolCatalog.supported.map(\.name)).subtracting(disabledTools)
        DispatchQueue.global(qos: .userInitiated).async {
            let detected = ActivityDetector().detect(enabledToolNames: enabledTools)

            DispatchQueue.main.async { [weak self] in
                self?.activities = detected
                self?.lastRefresh = Date()
                self?.isRefreshing = false
            }
        }
    }

    func groupedActivities() -> [(ActivityStatus, [AIActivity])] {
        ActivityStatus.allCases.compactMap { status in
            let items = activities.filter { $0.status == status }
            return items.isEmpty ? nil : (status, items)
        }
    }

    func jump(to activity: AIActivity) {
        if let app = NSRunningApplication(processIdentifier: activity.processIdentifier) {
            app.activate(options: [.activateAllWindows])
            return
        }

        guard let bundleIdentifier = activity.bundleIdentifier else { return }
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleIdentifier }?
            .activate(options: [.activateAllWindows])
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    @Published var disabledTools: Set<String> {
        didSet { defaults.set(Array(disabledTools), forKey: Keys.disabledTools) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let disabledTools = "disabledTools"
    }

    private init() {
        let savedInterval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = savedInterval > 0 ? savedInterval : 5
        disabledTools = Set(defaults.stringArray(forKey: Keys.disabledTools) ?? [])
    }

    func isEnabled(toolName: String) -> Bool {
        !disabledTools.contains(toolName)
    }

    func setEnabled(_ enabled: Bool, toolName: String) {
        if enabled {
            disabledTools.remove(toolName)
        } else {
            disabledTools.insert(toolName)
        }
    }
}
