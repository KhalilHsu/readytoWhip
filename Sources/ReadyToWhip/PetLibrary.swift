import AppKit
import Foundation

enum PetRenderMode: String, Codable, Hashable {
    case generated
    case spriteSheet
}

struct PetPackManifest: Identifiable, Hashable {
    let id: String
    let displayName: String
    let creatorName: String
    let summary: String
    let renderMode: PetRenderMode
    let accentColor: NSColor
    let secondaryColor: NSColor
    let highlightColor: NSColor
    let sourceURL: URL?
    let previewImageURL: URL?
    let spriteSheetURL: URL?
    let framePixelSize: CGSize
    let spriteRows: [PetAnimationState: Int]
    let framesPerState: [PetAnimationState: Int]

    var sourceLabel: String {
        sourceURL == nil ? "Built-in" : "Community"
    }
}

@MainActor
final class PetLibrary: ObservableObject {
    @Published private(set) var packs: [PetPackManifest] = []
    @Published var selectedPetID: String {
        didSet {
            defaults.set(selectedPetID, forKey: Keys.selectedPetID)
        }
    }

    var selectedPack: PetPackManifest {
        packs.first(where: { $0.id == selectedPetID }) ?? packs[0]
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let selectedPetID = "selectedPetID"
    }

    init() {
        selectedPetID = defaults.string(forKey: Keys.selectedPetID) ?? "kunkun"
        reload()
    }

    func reload() {
        let discovered = Self.builtInPacks() + Self.loadExternalPacks()
        packs = discovered
        if !packs.contains(where: { $0.id == selectedPetID }) {
            selectedPetID = packs.first(where: { $0.id == "kunkun" })?.id ?? packs.first?.id ?? "whippy"
        }
    }

    func select(_ pack: PetPackManifest) {
        selectedPetID = pack.id
    }

    func revealPetsFolder() {
        let directory = Self.communityPetsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    static func communityPetsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadyToWhip/Pets", isDirectory: true)
    }

    static func codexPetsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }

    private static func builtInPacks() -> [PetPackManifest] {
        [
            PetPackManifest(
                id: "whippy",
                displayName: "Whippy",
                creatorName: "ReadyToWhip",
                summary: "Calm helper with a bright tracking pulse.",
                renderMode: .generated,
                accentColor: NSColor(red: 0.31, green: 0.78, blue: 0.65, alpha: 1),
                secondaryColor: NSColor(red: 0.10, green: 0.23, blue: 0.19, alpha: 1),
                highlightColor: NSColor(red: 0.94, green: 1.00, blue: 0.84, alpha: 1),
                sourceURL: nil,
                previewImageURL: nil,
                spriteSheetURL: nil,
                framePixelSize: CGSize(width: 192, height: 208),
                spriteRows: Self.defaultSpriteRows,
                framesPerState: Self.defaultFramesPerState
            ),
            PetPackManifest(
                id: "miso",
                displayName: "Miso",
                creatorName: "ReadyToWhip",
                summary: "Warm studio buddy tuned for focus states.",
                renderMode: .generated,
                accentColor: NSColor(red: 0.98, green: 0.64, blue: 0.31, alpha: 1),
                secondaryColor: NSColor(red: 0.32, green: 0.16, blue: 0.11, alpha: 1),
                highlightColor: NSColor(red: 1.00, green: 0.94, blue: 0.80, alpha: 1),
                sourceURL: nil,
                previewImageURL: nil,
                spriteSheetURL: nil,
                framePixelSize: CGSize(width: 192, height: 208),
                spriteRows: Self.defaultSpriteRows,
                framesPerState: Self.defaultFramesPerState
            ),
            PetPackManifest(
                id: "pico",
                displayName: "Pico",
                creatorName: "ReadyToWhip",
                summary: "Sharp, playful scout for active sessions.",
                renderMode: .generated,
                accentColor: NSColor(red: 0.49, green: 0.56, blue: 0.98, alpha: 1),
                secondaryColor: NSColor(red: 0.11, green: 0.12, blue: 0.29, alpha: 1),
                highlightColor: NSColor(red: 0.88, green: 0.91, blue: 1.00, alpha: 1),
                sourceURL: nil,
                previewImageURL: nil,
                spriteSheetURL: nil,
                framePixelSize: CGSize(width: 192, height: 208),
                spriteRows: Self.defaultSpriteRows,
                framesPerState: Self.defaultFramesPerState
            )
        ]
    }

    private static func loadExternalPacks() -> [PetPackManifest] {
        let directories = [communityPetsDirectory(), codexPetsDirectory()]
        try? FileManager.default.createDirectory(at: communityPetsDirectory(), withIntermediateDirectories: true)
        var discovered: [String: PetPackManifest] = [:]

        for directory in directories {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in children {
                guard let pack = loadPack(at: url) else { continue }
                discovered[pack.id] = pack
            }
        }

        return Array(discovered.values)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func loadPack(at url: URL) -> PetPackManifest? {
            let manifestURL = url.appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }

            let slug = (raw["slug"] as? String)?.nilIfBlank ?? url.lastPathComponent
            let displayName = (raw["displayName"] as? String)?.nilIfBlank
                ?? (raw["name"] as? String)?.nilIfBlank
                ?? slug
            let creatorName = (raw["creatorName"] as? String)?.nilIfBlank
                ?? (raw["author"] as? String)?.nilIfBlank
                ?? "Community"
            let summary = (raw["summary"] as? String)?.nilIfBlank
                ?? (raw["description"] as? String)?.nilIfBlank
                ?? "Community pet pack"
            let accent = NSColor(hex: (raw["accentColor"] as? String) ?? "#67CDB2") ?? .systemTeal
            let secondary = NSColor(hex: (raw["secondaryColor"] as? String) ?? "#1D2B2A") ?? .labelColor
            let highlight = NSColor(hex: (raw["highlightColor"] as? String) ?? "#F3FCE5") ?? .white

            let spriteSheetURL =
                ["spritesheet.webp", "spritesheet.png"]
                .map { url.appendingPathComponent($0) }
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            let previewImageURL =
                ["artwork.png", "artwork.webp", "preview.png", "preview.webp"]
                .map { url.appendingPathComponent($0) }
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })

            let framePixelSize = parseFramePixelSize(raw: raw, spriteSheetURL: spriteSheetURL)

            return PetPackManifest(
                id: slug,
                displayName: displayName,
                creatorName: creatorName,
                summary: summary,
                renderMode: spriteSheetURL == nil ? .generated : .spriteSheet,
                accentColor: accent,
                secondaryColor: secondary,
                highlightColor: highlight,
                sourceURL: url,
                previewImageURL: previewImageURL,
                spriteSheetURL: spriteSheetURL,
                framePixelSize: framePixelSize,
                spriteRows: defaultSpriteRows,
                framesPerState: defaultFramesPerState
            )
    }

    private static let defaultSpriteRows: [PetAnimationState: Int] = [
        .idle: 0,
        .running: 7,
        .waiting: 6,
        .waving: 3,
        .failed: 5
    ]

    private static let defaultFramesPerState: [PetAnimationState: Int] = [
        .idle: 6,
        .running: 6,
        .waiting: 6,
        .waving: 4,
        .failed: 8
    ]

    private static func parseFramePixelSize(raw: [String: Any], spriteSheetURL: URL?) -> CGSize {
        if let width = raw["frameWidth"] as? Double,
           let height = raw["frameHeight"] as? Double {
            return CGSize(width: width, height: height)
        }

        if let spriteSheetURL,
           let image = NSImage(contentsOf: spriteSheetURL) {
            let imageSize = image.size
            if imageSize.width > 0, imageSize.height > 0 {
                return CGSize(width: imageSize.width / 8.0, height: imageSize.height / 9.0)
            }
        }

        return CGSize(width: 192, height: 208)
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }

        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
