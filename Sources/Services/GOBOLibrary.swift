import Foundation

/// One of the GOBO images that ship with grandMA3 (and the fixture libraries
/// it installs): `<version>/shared/lib_fixture_types/gobos/<folder>/<name>.png`.
struct DefaultGOBO: Identifiable, Hashable, Sendable {
    /// "folder/name", lowercased — the same GOBO in several installed versions counts once.
    let id: String
    /// The manufacturer folder ("Martin"), or "System" (MA's own) / "Generic".
    let folder: String
    /// File name without extension (and without a "Folder@" prefix).
    let name: String
    let url: URL

    /// What a search matches against: folder and name, lowercased.
    let searchKey: String

    init(folder: String, name: String, url: URL) {
        self.folder = folder
        self.name = name
        self.url = url
        self.id = "\(folder)/\(name)".lowercased()
        self.searchKey = "\(folder) \(name)".lowercased()
    }
}

/// Reads the default GOBO images off the installed grandMA3 onPC versions.
/// Names are mostly numeric IDs, so the manufacturer folder is what makes
/// them findable — a search matches both.
enum GOBOLibrary {
    /// Folders MA lists first: its own images, then the generic set.
    private static let leadingFolders = ["System", "Generic"]

    /// Installed `gobos` folders, newest version first.
    static func goboFolders() -> [URL] {
        let fm = FileManager.default
        let root = MA3LocalDetector.malightingRoot
        guard let versions = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return versions
            .filter { $0.lastPathComponent.hasPrefix("gma3_") && $0.lastPathComponent.dropFirst(5).first?.isNumber == true }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("shared/lib_fixture_types/gobos", isDirectory: true) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    /// Every default GOBO image, without duplicates (the newest installed
    /// version's copy wins). Walks ~10k files, so call it off the main thread.
    nonisolated static func scan() -> [DefaultGOBO] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [DefaultGOBO] = []
        for gobos in goboFolders() {
            guard let folders = try? fm.contentsOfDirectory(
                at: gobos, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for folderURL in folders {
                guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let files = try? fm.contentsOfDirectory(
                        at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                let folder = folderURL.lastPathComponent
                for file in files where file.pathExtension.lowercased() == "png" {
                    var name = file.deletingPathExtension().lastPathComponent
                    if name.hasPrefix("\(folder)@") { name.removeFirst(folder.count + 1) }
                    let item = DefaultGOBO(folder: folder, name: name, url: file)
                    if seen.insert(item.id).inserted { result.append(item) }
                }
            }
        }
        return result.sorted { a, b in
            let ra = leadingFolders.firstIndex(of: a.folder) ?? leadingFolders.count
            let rb = leadingFolders.firstIndex(of: b.folder) ?? leadingFolders.count
            if ra != rb { return ra < rb }
            if a.folder != b.folder { return a.folder.localizedStandardCompare(b.folder) == .orderedAscending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Items whose folder or name contains every space-separated word of `query`.
    nonisolated static func filter(_ items: [DefaultGOBO], query: String, folder: String?) -> [DefaultGOBO] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            if let folder, item.folder != folder { return false }
            return words.allSatisfy { item.searchKey.contains($0) }
        }
    }
}
