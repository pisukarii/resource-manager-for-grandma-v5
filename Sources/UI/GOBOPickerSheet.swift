import SwiftUI
import AppKit

/// Pick a GOBO image from the ones that ship with grandMA3 (thousands, by
/// manufacturer), with a search box and a manufacturer filter. Double-click
/// (or select + 「選択」) to use one; 「ファイルから選ぶ...」 falls back to any image file.
struct GOBOPickerSheet: View {
    let title: String
    var onPick: (URL) -> Void
    var onChooseFile: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var all: [DefaultGOBO] = []
    @State private var isLoading = true
    @State private var query: String
    @State private var folder: String?
    @State private var results: [DefaultGOBO] = []
    @State private var selection: DefaultGOBO?

    /// `initialQuery` / `initialFolder` start the sheet already filtered (previews and screenshots).
    init(title: String, initialQuery: String = "", initialFolder: String? = nil,
         onPick: @escaping (URL) -> Void, onChooseFile: @escaping () -> Void) {
        self.title = title
        self.onPick = onPick
        self.onChooseFile = onChooseFile
        _query = State(initialValue: initialQuery)
        _folder = State(initialValue: initialFolder)
    }

    private var folderCounts: [(name: String, count: Int)] {
        Dictionary(grouping: all, by: \.folder)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { a, b in
                let order = ["System", "Generic"]
                let ia = order.firstIndex(of: a.name) ?? order.count
                let ib = order.firstIndex(of: b.name) ?? order.count
                if ia != ib { return ia < ib }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("名前・メーカーで検索(スペースで複数語)", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Picker("メーカー", selection: $folder) {
                    Text("すべてのメーカー").tag(String?.none)
                    Divider()
                    ForEach(folderCounts, id: \.name) { item in
                        Text("\(item.name) (\(item.count))").tag(String?.some(item.name))
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }

            ZStack {
                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("GOBOを読み込み中...").font(.callout).foregroundStyle(.secondary)
                    }
                } else if all.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                        Text("デフォルトのGOBOが見つかりません").foregroundStyle(.secondary)
                        Text("grandMA3 onPC(~/MALightingTechnology)のgobosフォルダを探しています。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if results.isEmpty {
                    Text("一致するGOBOがありません").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                            ForEach(results) { gobo in
                                cell(gobo)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if !isLoading {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("ファイルから選ぶ...") {
                    dismiss()
                    onChooseFile()
                }
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("選択") { pick(selection) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .task {
            let found = await Task.detached(priority: .userInitiated) { GOBOLibrary.scan() }.value
            all = found
            results = GOBOLibrary.filter(found, query: query, folder: folder)
            isLoading = false
        }
        .onChange(of: query) { refilter() }
        .onChange(of: folder) { refilter() }
    }

    private var summary: String {
        if let selection {
            return "選択中: \(selection.folder) / \(selection.name)"
        }
        return results.count == all.count
            ? "\(all.count.formatted())件"
            : "\(results.count.formatted())件 / 全\(all.count.formatted())件"
    }

    private func refilter() {
        results = GOBOLibrary.filter(all, query: query, folder: folder)
        if let selection, !results.contains(selection) { self.selection = nil }
    }

    private func pick(_ gobo: DefaultGOBO?) {
        guard let gobo else { return }
        dismiss()
        onPick(gobo.url)
    }

    private func cell(_ gobo: DefaultGOBO) -> some View {
        let selected = selection == gobo
        return VStack(spacing: 3) {
            GOBOThumbnail(url: gobo.url)
                .frame(width: 64, height: 64)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2),
                                  lineWidth: selected ? 2.5 : 1))
            Text(gobo.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(gobo.folder)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 84)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick(gobo) }
        .onTapGesture { selection = gobo }
        .help("\(gobo.folder) / \(gobo.name)")
    }
}

/// A 64px GOBO image, loaded on demand and cached (thousands scroll past).
private struct GOBOThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            if let loaded {
                Self.cache.setObject(loaded, forKey: url as NSURL)
                image = loaded
            }
        }
    }
}
