import SwiftUI

struct PromptHubView: View {
    @ObservedObject var store: PromptHubStore

    var body: some View {
        NavigationSplitView {
            PromptHubSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            PromptConversationPane(store: store)
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New conversation")

                Button {
                    store.refreshAvailability()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh CLI availability")

                if store.selectedRun?.status == .running {
                    Button {
                        store.cancelSelectedRun()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop selected run")
                }
            }
        }
    }
}

private struct PromptHubSidebar: View {
    @ObservedObject var store: PromptHubStore

    var body: some View {
        List {
            Section("Tools") {
                ForEach(store.tools) { tool in
                    PromptToolRow(
                        tool: tool,
                        availability: store.availability[tool.id],
                        isSelected: store.selectedRunID == nil && store.selectedToolID == tool.id
                    ) {
                        store.selectTool(tool.id)
                    }
                }
            }

            if !store.runs.isEmpty {
                Section("Chats") {
                    ForEach(store.runs) { run in
                        PromptRunRow(
                            run: run,
                            isSelected: store.selectedRunID == run.id
                        ) {
                            store.selectRun(run.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt Hub")
                    .font(.system(size: 22, weight: .semibold))
                Text("ReadyToWhip")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }
}

private struct PromptToolRow: View {
    let tool: PromptCLITool
    let availability: PromptToolAvailability?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(nsColor: tool.accentColor))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.shortName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(availability?.isAvailable == true ? "Available" : "Not found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Circle()
                    .fill(availability?.isAvailable == true ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PromptRunRow: View {
    let run: PromptCLIRun
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: run.status.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: run.status.color))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(run.tool.shortName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(run.status.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(run.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PromptConversationPane: View {
    @ObservedObject var store: PromptHubStore

    var body: some View {
        VStack(spacing: 0) {
            PromptConversationHeader(store: store)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.bar)

            Divider()

            PromptMessageTimeline(run: store.selectedRun, tool: store.selectedTool)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            PromptComposer(store: store)
                .padding(16)
                .background(.regularMaterial)
        }
    }
}

private struct PromptConversationHeader: View {
    @ObservedObject var store: PromptHubStore

    private var tool: PromptCLITool { store.selectedTool }
    private var availability: PromptToolAvailability? { store.availability[tool.id] }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: tool.accentColor).opacity(0.16))
                Image(systemName: tool.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(nsColor: tool.accentColor))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(tool.name)
                        .font(.system(size: 16, weight: .semibold))
                    PromptStatusBadge(status: store.selectedRun?.status)
                }

                Text(availability?.displayText ?? "Checking command")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Picker("Tool", selection: Binding(
                    get: { store.selectedToolID },
                    set: { store.selectTool($0) }
                )) {
                    ForEach(store.tools) { tool in
                        Label(tool.shortName, systemImage: tool.systemImage).tag(tool.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 118)

                Picker("Model", selection: Binding(
                    get: { store.selectedModel.id },
                    set: { store.setSelectedModelID($0) }
                )) {
                    ForEach(store.selectedTool.modelOptions) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 152)

                Picker("Thinking", selection: Binding(
                    get: { store.selectedConfiguration.reasoningID },
                    set: { store.setSelectedReasoningID($0) }
                )) {
                    ForEach(store.selectedReasoningOptions) { effort in
                        Text(effort.displayName).tag(effort.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 112)
            }
        }
    }
}

private struct PromptStatusBadge: View {
    let status: PromptRunStatus?

    var body: some View {
        if let status {
            HStack(spacing: 4) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(status.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color(nsColor: status.color))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: status.color).opacity(0.12), in: Capsule())
        }
    }
}

private struct PromptMessageTimeline: View {
    let run: PromptCLIRun?
    let tool: PromptCLITool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let run {
                        PromptRunMetadata(run: run)
                            .id("metadata-\(run.id)")

                        ForEach(run.messages) { message in
                            PromptMessageBubble(message: message, tool: run.tool)
                                .id(message.id)
                        }
                    } else {
                        PromptEmptyTimeline(tool: tool)
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .onChange(of: run?.messages) { _, messages in
                guard let last = messages?.last else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct PromptRunMetadata: View {
    let run: PromptCLIRun

    var body: some View {
        VStack(spacing: 6) {
            Text(run.tool.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(run.configuration.modelDisplayName) · \(run.configuration.reasoningDisplayName)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            if let commandPreview = run.commandPreview {
                Text(commandPreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 620)
        .padding(.vertical, 4)
    }
}

private struct PromptEmptyTimeline: View {
    let tool: PromptCLITool

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: tool.accentColor).opacity(0.12))
                Image(systemName: tool.systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(nsColor: tool.accentColor))
            }
            .frame(width: 72, height: 72)

            Text(tool.name)
                .font(.system(size: 20, weight: .semibold))
            Text("New conversation")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PromptMessageBubble: View {
    let message: PromptHubMessage
    let tool: PromptCLITool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 64)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                Text(message.text.trimmingCharacters(in: .newlines))
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .foregroundStyle(foregroundStyle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 64)
            }
        }
    }

    private var label: String {
        switch message.role {
        case .user: "You"
        case .assistant: tool.shortName
        case .diagnostic: "System"
        }
    }

    private var foregroundStyle: Color {
        switch message.role {
        case .user: .white
        case .assistant: Color(nsColor: .labelColor)
        case .diagnostic: Color(nsColor: .secondaryLabelColor)
        }
    }

    private var backgroundStyle: Color {
        switch message.role {
        case .user: Color.accentColor
        case .assistant: Color(nsColor: .controlBackgroundColor)
        case .diagnostic: Color(nsColor: .systemOrange).opacity(0.12)
        }
    }
}

private struct PromptComposer: View {
    @ObservedObject var store: PromptHubStore

    private var canSend: Bool {
        store.canSendPrompt
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Working directory", text: $store.workingDirectoryPath)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                Button {
                    chooseDirectory()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.borderless)
                .help("Choose working directory")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.promptDraft)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 74, maxHeight: 150)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                    if store.promptDraft.isEmpty {
                        Text("Message \(store.selectedTool.shortName)")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 17)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                )

                Button {
                    store.sendPrompt()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send")
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (store.workingDirectoryPath as NSString).expandingTildeInPath)

        if panel.runModal() == .OK, let url = panel.url {
            store.workingDirectoryPath = url.path
        }
    }
}
