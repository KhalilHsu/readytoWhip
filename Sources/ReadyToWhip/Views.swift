import AppKit
import SwiftUI

struct FloatingWidgetView: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                activityList
            }
        }
        .frame(width: 360, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 10) {
            statusDots
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("AI Activity")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: store.isExpanded ? "chevron.down" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            store.isExpanded.toggle()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    // No-op: Just to intercept movement and prevent tap gesture from firing
                }
        )
    }

    private var statusDots: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(nsColor: ActivityStatus.working.systemColor))
                .frame(width: 8, height: 8)
                .opacity(store.workingCount > 0 ? 1 : 0.25)
            Circle()
                .fill(Color(nsColor: ActivityStatus.waiting.systemColor))
                .frame(width: 8, height: 8)
                .opacity(store.waitingCount > 0 ? 1 : 0.25)
            Circle()
                .fill(Color(nsColor: ActivityStatus.done.systemColor))
                .frame(width: 8, height: 8)
                .opacity(store.doneCount > 0 ? 1 : 0.25)
        }
    }

    private var summary: String {
        if store.activities.isEmpty {
            return "No AI activity"
        }
        return "\(store.workingCount) working · \(store.waitingCount) waiting"
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Detected Sessions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            if store.activities.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.groupedActivities(), id: \.0) { status, items in
                            ActivityGroupView(status: status, items: items, store: store)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
    }
}

struct ActivityGroupView: View {
    let status: ActivityStatus
    let items: [AIActivity]
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: status.systemColor))
                    .frame(width: 7, height: 7)
                Text(status.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            ForEach(items) { activity in
                ActivityRowView(activity: activity) {
                    store.jump(to: activity)
                }
            }
        }
    }
}

struct ActivityRowView: View {
    let activity: AIActivity
    let onJump: () -> Void

    var body: some View {
        Button(action: onJump) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: activity.status.systemColor))
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(activity.toolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(activity.source.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: Capsule())
                    }

                    Text(activity.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let title = activity.windowTitle, title != activity.subtitle {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch activity.source {
        case .desktopApp: "app"
        case .cli: "terminal"
        case .terminalSession: "terminal"
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No supported AI tools detected")
                .font(.system(size: 12, weight: .semibold))
            Text("Open Codex, Cursor, Antigravity, Gemini CLI, or Claude Code to see sessions here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI Activity Settings")
                .font(.system(size: 20, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text("Monitored Tools")
                    .font(.system(size: 13, weight: .semibold))

                ForEach(ToolCatalog.supported) { tool in
                    Toggle(tool.name, isOn: Binding(
                        get: { settings.isEnabled(toolName: tool.name) },
                        set: { enabled in
                            settings.setEnabled(enabled, toolName: tool.name)
                            onRefresh()
                        }
                    ))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Refresh")
                    .font(.system(size: 13, weight: .semibold))
                Picker("Refresh interval", selection: Binding(
                    get: { settings.refreshInterval },
                    set: { value in
                        settings.refreshInterval = value
                        onRefresh()
                    }
                )) {
                    Text("3 seconds").tag(TimeInterval(3))
                    Text("5 seconds").tag(TimeInterval(5))
                    Text("10 seconds").tag(TimeInterval(10))
                    Text("30 seconds").tag(TimeInterval(30))
                }
                .pickerStyle(.segmented)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 360, alignment: .topLeading)
    }
}
