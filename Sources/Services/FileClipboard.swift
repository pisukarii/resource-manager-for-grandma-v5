import AppKit
import Foundation
import UniformTypeIdentifiers

/// Copy & paste of files — ⌘C / ⌘V and the 編集 menu — between this app's
/// Sources, and with the Finder in both directions.
///
/// * Copy puts the selected rows on the system pasteboard as real file URLs
///   (so the Finder can paste them) plus the app's own reference to the row
///   (so a paste inside the app also works for SFTP, which has no local file).
/// * Paste takes whatever is on the pasteboard — files copied in the Finder,
///   or rows copied here — and copies it into the folder being shown.
enum FileClipboard {
    // MARK: Copy

    /// ⌘C / 編集 > コピー. SwiftUI empties the pasteboard when its copy handler returns, so the
    /// write happens just after that, on the next turn of the run loop.
    @MainActor
    static func copy(_ entries: [FileEntry], in source: any FileSource, transferState: TransferState) {
        guard !entries.isEmpty else { return }
        DispatchQueue.main.async {
            writeToPasteboard(entries, in: source)
            stageForFinderIfNeeded(entries, in: source, transferState: transferState)
        }
    }

    /// Puts `entries` on the system pasteboard: each as one item holding the real file URL
    /// (so the Finder can paste it) and the app's own reference (so a paste in the app can
    /// tell a row from a file, and works for SFTP). Written here rather than handed to SwiftUI
    /// as item providers, because SwiftUI copies every file into a cache folder first.
    @MainActor
    static func writeToPasteboard(_ entries: [FileEntry], in source: any FileSource) {
        let type = NSPasteboard.PasteboardType(UTType.ma3InternalFileRef.identifier)
        let items = entries.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            if let url = source.localFileURL(for: entry.path) {
                item.setString(url.absoluteString, forType: .fileURL)
            }
            if let data = try? JSONEncoder().encode(InternalFileRef(sourceID: source.id, path: entry.path)) {
                item.setData(data, forType: type)
            }
            return item
        }
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }

    /// Rows on an SFTP Source have no file on this Mac for the Finder to paste.
    /// Downloads them to a staging folder, then puts the real files on the
    /// pasteboard — unless something else was copied in the meantime. Rows on
    /// local disk / USB need none of this.
    @MainActor
    static func stageForFinderIfNeeded(_ entries: [FileEntry], in source: any FileSource, transferState: TransferState) {
        let remote = entries.filter { source.localFileURL(for: $0.path) == nil }
        guard !remote.isEmpty else { return }
        let refs = remote.map { InternalFileRef(sourceID: source.id, path: $0.path) }

        Task { @MainActor in
            cleanStaging()
            let root = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var staged: [URL] = []
            transferState.begin(label: "Finderに貼り付けられるよう、\(source.config.name) から取り込み中...")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for (index, entry) in remote.enumerated() {
                    let url = root.appendingPathComponent(entry.name)
                    try await source.copyOut(from: entry.path, to: url) { fraction in
                        Task { @MainActor in transferState.progress = (Double(index) + fraction) / Double(remote.count) }
                    }
                    staged.append(url)
                }
                transferState.finish()
            } catch {
                transferState.finish(error: transferErrorMessage(for: error))
                return
            }
            // Only if the pasteboard still holds what was copied.
            guard pasteboardRefs() == refs.map(Self.key) else { return }
            let items = zip(staged, refs).map { url, ref -> NSPasteboardItem in
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                if let data = try? JSONEncoder().encode(ref) {
                    item.setData(data, forType: NSPasteboard.PasteboardType(UTType.ma3InternalFileRef.identifier))
                }
                return item
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(items)
        }
    }

    private static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardStage", isDirectory: true)
    }

    /// Removes what earlier copies left behind (also called at launch).
    static func cleanStaging() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private static func key(_ ref: InternalFileRef) -> String { "\(ref.sourceID)|\(ref.path.displayPath)" }

    /// The in-app references currently on the pasteboard.
    static func pasteboardRefs() -> [String] {
        let type = NSPasteboard.PasteboardType(UTType.ma3InternalFileRef.identifier)
        return (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            item.data(forType: type).flatMap { try? JSONDecoder().decode(InternalFileRef.self, from: $0) }.map(key)
        }
    }

    // MARK: Paste

    /// What is on the system pasteboard, as paste payloads. The app's own reference wins over the
    /// file URL (it works for SFTP rows too); if its Source is gone, the file URL is used.
    /// (SwiftUI's paste handler only passes on the file URLs, so the pasteboard is read directly.)
    @MainActor
    static func payloadsFromPasteboard(store: SourceStore) -> [DropPayload] {
        let type = NSPasteboard.PasteboardType(UTType.ma3InternalFileRef.identifier)
        var payloads: [DropPayload] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            let url = item.string(forType: .fileURL).flatMap { URL(string: $0) }
            if let data = item.data(forType: type),
               let ref = try? JSONDecoder().decode(InternalFileRef.self, from: data),
               store.source(for: ref.sourceID) != nil || url == nil {
                payloads.append(.internalRef(ref))
            } else if let url {
                payloads.append(.localFile(url))
            }
        }
        return payloads
    }

    /// Copies what was pasted into `destination` on `target`. Unlike a drop onto the
    /// item's own Source, pasting there is fine — a file pasted over itself becomes
    /// "<name> copy", never an overwrite of the original.
    @MainActor
    static func paste(
        _ payloads: [DropPayload],
        into target: any FileSource,
        at destination: RelativePath,
        store: SourceStore,
        transferState: TransferState
    ) async {
        for payload in payloads {
            switch payload {
            case .localFile(let url):
                await pasteLocalFile(url, into: target, at: destination, transferState: transferState)
            case .internalRef(let ref):
                guard let origin = store.source(for: ref.sourceID) else { continue }
                await pasteRow(ref, from: origin, into: target, at: destination, transferState: transferState)
            }
        }
    }

    @MainActor
    private static func pasteLocalFile(
        _ url: URL, into target: any FileSource, at destination: RelativePath, transferState: TransferState
    ) async {
        let name = url.lastPathComponent
        var finalName = name
        let existing = destination.appending(name)
        if await target.exists(existing) {
            if isSameFile(target.localFileURL(for: existing), url) {
                finalName = await uniqueCopyName(for: name, in: destination, on: target)
            } else if !confirmOverwrite(fileName: name, targetName: target.config.name) {
                return
            }
        }

        transferState.begin(label: "\(finalName) を \(target.config.name) へ貼り付け中...")
        do {
            if finalName == name {
                try await target.copyIn(from: url, to: destination) { fraction in
                    Task { @MainActor in transferState.progress = fraction }
                }
            } else {
                try await withTempDirectory { dir in
                    let renamed = dir.appendingPathComponent(finalName)
                    try FileManager.default.copyItem(at: url, to: renamed)
                    try await target.copyIn(from: renamed, to: destination, progress: nil)
                }
            }
            transferState.finish()
        } catch {
            transferState.finish(error: transferErrorMessage(for: error))
        }
    }

    @MainActor
    private static func pasteRow(
        _ ref: InternalFileRef, from origin: any FileSource, into target: any FileSource,
        at destination: RelativePath, transferState: TransferState
    ) async {
        let name = ref.path.components.last ?? ""
        guard !name.isEmpty else { return }
        let parent = RelativePath(components: Array(ref.path.components.dropLast()))
        var finalName = name
        if ref.sourceID == target.id && parent == destination {
            finalName = await uniqueCopyName(for: name, in: destination, on: target)
        } else if await target.exists(destination.appending(name)),
                  !confirmOverwrite(fileName: name, targetName: target.config.name) {
            return
        }

        transferState.begin(label: "\(finalName) を \(target.config.name) へ貼り付け中...")
        do {
            if finalName == name, let local = origin.localFileURL(for: ref.path) {
                // Already a real file on this Mac: no need to go through a temp copy.
                try await target.copyIn(from: local, to: destination) { fraction in
                    Task { @MainActor in transferState.progress = fraction }
                }
            } else {
                try await withTempDirectory { dir in
                    let staged = dir.appendingPathComponent(finalName)
                    try await origin.copyOut(from: ref.path, to: staged) { fraction in
                        Task { @MainActor in transferState.progress = fraction * 0.5 }
                    }
                    try await target.copyIn(from: staged, to: destination) { fraction in
                        Task { @MainActor in transferState.progress = 0.5 + fraction * 0.5 }
                    }
                }
            }
            transferState.finish()
        } catch {
            transferState.finish(error: transferErrorMessage(for: error))
        }
    }

    // MARK: Helpers

    private static func isSameFile(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// "name copy.ext", then "name copy 2.ext", ... — the first one not already taken.
    /// (ASCII on purpose: it ends up on a console's disk.)
    @MainActor
    static func uniqueCopyName(for name: String, in destination: RelativePath, on target: any FileSource) async -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        // A short extension without spaces is a real one; "v2.4 backups" is just a folder name.
        let hasExtension = !ext.isEmpty && ext.count <= 5 && !ext.contains(" ")
        let stem = hasExtension ? ns.deletingPathExtension : name
        func candidate(_ n: Int) -> String {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            return hasExtension ? "\(stem)\(suffix).\(ext)" : "\(stem)\(suffix)"
        }
        var n = 1
        while await target.exists(destination.appending(candidate(n))) { n += 1 }
        return candidate(n)
    }

    private static func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}
