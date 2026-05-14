import AppKit
import SwiftUI

@MainActor
private final class SpriteSheetCache {
    static let shared = SpriteSheetCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct FloatingWidgetView: View {
    @ObservedObject var store: ActivityStore
    @ObservedObject var petLibrary: PetLibrary
    @State private var manualStateOverride: PetAnimationState? = nil
    @State private var globalEventMonitor: Any?
    @State private var lastToggleTime: Date = .distantPast

    private func togglePopover() {
        let now = Date()
        // Prevent rapid toggling that could cause multiple popovers/windows to spawn
        guard now.timeIntervalSince(lastToggleTime) > 0.3 else { return }
        lastToggleTime = now
        store.showsPopover.toggle()
    }

    var body: some View {
        let displayState = manualStateOverride ?? store.petState

        VStack(alignment: .leading, spacing: 0) {
            PetMascotView(pack: petLibrary.selectedPack, state: displayState)
                .frame(width: 162, height: 182)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.showsPopover = false
                    let allStates = PetAnimationState.allCases
                    let currentState = manualStateOverride ?? store.petState
                    let currentIndex = allStates.firstIndex(of: currentState) ?? 0
                    let nextIndex = (currentIndex + 1) % allStates.count
                    manualStateOverride = allStates[nextIndex]
                }
                .overlay(alignment: .topTrailing) {
                    PetBadgeView(
                        count: store.activeCount,
                        accentColor: Color(nsColor: store.petState.accentColor)
                    )
                    .contentShape(Circle())
                    .onTapGesture {
                        togglePopover()
                    }
                    .popover(isPresented: $store.showsPopover, arrowEdge: .trailing) {
                        SessionPopoverView(store: store)
                    }
                    .help("Show detected sessions")
                    .offset(x: -10, y: 18)
                }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(width: 180)
        .onChange(of: store.showsPopover) { _, isShown in
            if isShown {
                globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                    store.showsPopover = false
                }
            } else {
                if let monitor = globalEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    globalEventMonitor = nil
                }
            }
        }
    }
}

private struct PetMascotView: View {
    let pack: PetPackManifest
    let state: PetAnimationState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            if pack.renderMode == .spriteSheet,
               let spriteSheetURL = pack.spriteSheetURL {
                SpriteSheetPetView(
                    pack: pack,
                    state: state,
                    timestamp: timeline.date.timeIntervalSinceReferenceDate,
                    spriteSheetURL: spriteSheetURL
                )
            } else if let previewImageURL = pack.previewImageURL,
               let image = NSImage(contentsOf: previewImageURL) {
                CommunityPetPreviewView(
                    pack: pack,
                    state: state,
                    timestamp: timeline.date.timeIntervalSinceReferenceDate,
                    image: image
                )
            } else {
                GeneratedPetView(
                    pack: pack,
                    state: state,
                    timestamp: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
    }
}

private struct SpriteSheetPetView: View {
    let pack: PetPackManifest
    let state: PetAnimationState
    let timestamp: TimeInterval
    let spriteSheetURL: URL

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bounce = CGFloat(sin(timestamp * 2.8)) * (state == .running ? 7 : 3)

            ZStack {
                if let image = croppedSpriteFrame() {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width * 0.64, height: size.height * 0.82)
                        .scaleEffect(x: 1, y: 0.90, anchor: .top)
                        .offset(y: bounce - size.height * 0.03)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func croppedSpriteFrame() -> NSImage? {
        guard let image = SpriteSheetCache.shared.image(for: spriteSheetURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let frameSize = pack.framePixelSize
        guard frameSize.width > 0, frameSize.height > 0 else { return nil }

        let row = pack.spriteRows[state] ?? 0
        let frameCount = max(1, pack.framesPerState[state] ?? 1)
        let frameIndex = Int(timestamp * animationRate).quotientAndRemainder(dividingBy: frameCount).remainder

        let scaleX = CGFloat(cgImage.width) / image.size.width
        let scaleY = CGFloat(cgImage.height) / image.size.height

        let rect = CGRect(
            x: CGFloat(frameIndex) * frameSize.width * scaleX,
            y: CGFloat(cgImage.height) - (CGFloat(row + 1) * frameSize.height * scaleY),
            width: frameSize.width * scaleX,
            height: frameSize.height * scaleY
        ).integral

        guard let cropped = cgImage.cropping(to: rect) else {
            return nil
        }

        return NSImage(cgImage: cropped, size: frameSize)
    }

    private var animationRate: Double {
        switch state {
        case .running: 8
        case .failed: 6
        default: 5
        }
    }
}

private struct PetBadgeView: View {
    let count: Int
    let accentColor: Color

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accentColor, in: Circle())
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accentColor, in: Circle())
        }
    }
}

private struct GeneratedPetView: View {
    let pack: PetPackManifest
    let state: PetAnimationState
    let timestamp: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bounce = bounceAmount
            let tilt = tiltAmount
            let pawLift = pawLiftAmount

            ZStack {
                ZStack {
                    petTail(size: size)
                    petBody(size: size)
                    petFace(size: size)
                    petPaws(size: size, lift: pawLift)
                    petStatusCharm(size: size)
                }
                .rotationEffect(.degrees(tilt))
                .offset(y: bounce)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func petBody(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: pack.accentColor),
                            Color(nsColor: pack.accentColor).opacity(0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size.width * 0.44, height: size.height * 0.58)

            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color.white.opacity(0.24))
                .frame(width: size.width * 0.24, height: size.height * 0.24)
                .offset(y: size.height * 0.06)

            petEar(offsetX: -size.width * 0.13, rotation: -12)
                .offset(y: -size.height * 0.23)
            petEar(offsetX: size.width * 0.13, rotation: 12)
                .offset(y: -size.height * 0.23)
        }
    }

    private func petEar(offsetX: CGFloat, rotation: Double) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: pack.accentColor).opacity(0.94))
            .frame(width: 34, height: 42)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: pack.highlightColor).opacity(0.65))
                    .padding(6)
            )
            .rotationEffect(.degrees(rotation))
            .offset(x: offsetX)
    }

    private func petTail(size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: size.width * 0.60, y: size.height * 0.60))
            path.addCurve(
                to: CGPoint(x: size.width * 0.76, y: size.height * 0.22),
                control1: CGPoint(x: size.width * 0.83, y: size.height * 0.60),
                control2: CGPoint(x: size.width * 0.86, y: size.height * 0.28)
            )
            path.addCurve(
                to: CGPoint(x: size.width * 0.64, y: size.height * 0.12),
                control1: CGPoint(x: size.width * 0.74, y: size.height * 0.15),
                control2: CGPoint(x: size.width * 0.67, y: size.height * 0.10)
            )
        }
        .stroke(
            Color(nsColor: pack.secondaryColor).opacity(0.42),
            style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round)
        )
    }

    private func petFace(size: CGSize) -> some View {
        ZStack {
            faceEyes(size: size)
            faceMouth(size: size)

            Circle()
                .fill(Color.white.opacity(0.42))
                .frame(width: 9, height: 9)
                .offset(x: -size.width * 0.07, y: size.height * 0.02)
            Circle()
                .fill(Color.white.opacity(0.42))
                .frame(width: 9, height: 9)
                .offset(x: size.width * 0.07, y: size.height * 0.02)
        }
        .offset(y: -size.height * 0.06)
    }

    @ViewBuilder
    private func faceEyes(size: CGSize) -> some View {
        switch state {
        case .failed:
            HStack(spacing: size.width * 0.10) {
                Text("×")
                Text("×")
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundStyle(Color(nsColor: pack.secondaryColor))
            .offset(y: -4)
        case .waiting:
            HStack(spacing: size.width * 0.12) {
                Circle()
                    .fill(Color(nsColor: pack.secondaryColor))
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(Color(nsColor: pack.secondaryColor))
                    .frame(width: 8, height: 8)
            }
            .offset(y: -2)
        default:
            HStack(spacing: size.width * 0.12) {
                Capsule()
                    .fill(Color(nsColor: pack.secondaryColor))
                    .frame(width: 12, height: state == .idle ? 10 : 12)
                Capsule()
                    .fill(Color(nsColor: pack.secondaryColor))
                    .frame(width: 12, height: state == .idle ? 10 : 12)
            }
            .offset(y: state == .waving ? -1 : -3)
        }
    }

    @ViewBuilder
    private func faceMouth(size: CGSize) -> some View {
        switch state {
        case .failed:
            Capsule()
                .fill(Color(nsColor: pack.secondaryColor).opacity(0.82))
                .frame(width: 16, height: 5)
                .offset(y: 15)
        case .waiting:
            Circle()
                .fill(Color(nsColor: pack.secondaryColor).opacity(0.82))
                .frame(width: 7, height: 7)
                .offset(y: 14)
        default:
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addQuadCurve(to: CGPoint(x: 18, y: 0), control: CGPoint(x: 9, y: 8))
            }
            .stroke(
                Color(nsColor: pack.secondaryColor).opacity(0.82),
                style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
            )
            .frame(width: 18, height: 10)
            .offset(y: 15)
        }
    }

    private func petPaws(size: CGSize, lift: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: pack.highlightColor).opacity(0.90))
                .frame(width: 20, height: 34)
                .offset(x: -size.width * 0.12, y: size.height * 0.16)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: pack.highlightColor).opacity(0.90))
                .frame(width: 20, height: 34)
                .offset(x: size.width * 0.12, y: size.height * 0.16)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: pack.highlightColor))
                .frame(width: 18, height: 30)
                .offset(x: -size.width * 0.23, y: state == .waving ? -size.height * 0.01 + lift : size.height * 0.04)
                .rotationEffect(.degrees(state == .waving ? -28 : -10))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: pack.highlightColor))
                .frame(width: 18, height: 30)
                .offset(x: size.width * 0.23, y: state == .running ? -size.height * 0.01 - lift : size.height * 0.04)
                .rotationEffect(.degrees(state == .running ? 24 : 10))
        }
    }

    private func petStatusCharm(size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: state.accentColor))
                .frame(width: 26, height: 26)
            Image(systemName: charmSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .offset(x: size.width * 0.22, y: -size.height * 0.18)
    }

    private var bounceAmount: CGFloat {
        switch state {
        case .running:
            return CGFloat(sin(timestamp * 6.2)) * 7
        case .waving:
            return CGFloat(sin(timestamp * 4.2)) * 4
        case .waiting:
            return CGFloat(sin(timestamp * 2.0)) * 2
        case .failed:
            return CGFloat(sin(timestamp * 9.0)) * 1.5
        case .idle:
            return CGFloat(sin(timestamp * 1.6)) * 2
        }
    }

    private var tiltAmount: Double {
        switch state {
        case .failed:
            return sin(timestamp * 10.0) * 2.8
        case .waiting:
            return sin(timestamp * 1.8) * 4.0
        case .running:
            return sin(timestamp * 5.4) * 2.4
        case .waving:
            return sin(timestamp * 4.0) * 3.0
        case .idle:
            return sin(timestamp * 1.4) * 1.2
        }
    }

    private var pawLiftAmount: CGFloat {
        switch state {
        case .waving, .running:
            return CGFloat(abs(sin(timestamp * 6.0))) * 10
        default:
            return 0
        }
    }

    private var charmSymbol: String {
        switch state {
        case .idle: "moon.stars.fill"
        case .running: "bolt.fill"
        case .waiting: "ellipsis"
        case .waving: "sparkles"
        case .failed: "exclamationmark"
        }
    }
}

private struct CommunityPetPreviewView: View {
    let pack: PetPackManifest
    let state: PetAnimationState
    let timestamp: TimeInterval
    let image: NSImage

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bounce = CGFloat(sin(timestamp * 2.4)) * (state == .running ? 8 : 4)

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width * 0.54, height: size.height * 0.74)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .offset(y: bounce)

                ZStack {
                    Circle()
                        .fill(Color(nsColor: state.accentColor))
                        .frame(width: 28, height: 28)
                    Image(systemName: state == .running ? "bolt.fill" : state == .waiting ? "ellipsis" : state == .failed ? "exclamationmark" : "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .offset(x: size.width * 0.20, y: -size.height * 0.18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SessionPopoverView: View {
    @ObservedObject var store: ActivityStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("AI Activity")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(12)

            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 10) {
                Text("Detected Sessions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

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
                    .frame(maxHeight: 320)
                }
            }
            .padding(12)
        }
        .frame(width: 360, alignment: .topLeading)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.30), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
        }
    }

    private var summary: String {
        if store.activities.isEmpty {
            return "No AI activity"
        }
        return "\(store.workingCount) working · \(store.waitingCount) waiting"
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

                VStack(alignment: .leading, spacing: 4) {
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

                    Text(activity.displaySubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let detail = activity.displayDetail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Text(activity.lastUpdatedRelativeText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(9)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var petLibrary: PetLibrary
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI Activity Settings")
                .font(.system(size: 20, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Pet Library")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Open Pets Folder") {
                        petLibrary.revealPetsFolder()
                    }
                    .buttonStyle(.link)
                }

                Picker("Current pet", selection: $petLibrary.selectedPetID) {
                    ForEach(petLibrary.packs) { pack in
                        Text(pack.displayName).tag(pack.id)
                    }
                }
                .pickerStyle(.menu)
            }

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
        .frame(width: 420, height: 390, alignment: .topLeading)
    }
}
