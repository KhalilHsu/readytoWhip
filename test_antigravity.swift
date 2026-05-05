import Foundation

let supportRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Antigravity").path
let root = "\(supportRoot)/User/workspaceStorage"
guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else {
    print("No dirs found in \(root)")
    exit(1)
}

for dir in dirs {
    let path = "\(root)/\(dir)/workspace.json"
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        continue
    }

    let uri = (json["folder"] as? String) ?? (json["workspace"] as? String)
    let statePath = "\(root)/\(dir)/state.vscdb"
    let modifiedAt = ((try? FileManager.default.attributesOfItem(atPath: statePath))?[.modificationDate] as? Date)
        ?? ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
        ?? .distantPast
    
    print("Workspace: \(uri ?? "nil")")
    print("  modifiedAt: \(modifiedAt)")
    print("  age (hours): \(Date().timeIntervalSince(modifiedAt) / 3600)")
}
