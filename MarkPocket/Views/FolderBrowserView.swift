import SwiftUI

struct FolderBrowserView: View {
    let folder: WatchedFolder
    let subdirectory: URL?
    @Bindable var library: DocumentLibraryStore

    @State private var entries: [FolderEntry] = []
    @State private var searchText = ""
    @State private var isSelectionMode = false
    @State private var selectedEntryURLs: Set<URL> = []
    @State private var pendingDeleteEntry: FolderEntry?
    @State private var showBulkDeleteConfirmation = false
    @State private var renameTargetEntry: FolderEntry?
    @State private var renameDraft = ""
    @State private var showNewNoteSheet = false

    private var filteredEntries: [FolderEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var areAllFilteredSelected: Bool {
        !filteredEntries.isEmpty && filteredEntries.allSatisfy { selectedEntryURLs.contains($0.url) }
    }

    var body: some View {
        List {
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "Markdown ファイルがありません" : "一致するファイルがありません",
                    systemImage: searchText.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "このフォルダ内に `.md` / `.markdown` / `.txt` ファイルが見つかりませんでした。" : "別のキーワードで検索してみてください。")
                )
            } else {
                ForEach(filteredEntries) { entry in
                    entryRow(entry)
                }
            }
        }
        .navigationTitle(subdirectory?.lastPathComponent ?? folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "フォルダ内を検索")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelectionMode {
                    HStack(spacing: 12) {
                        Button(areAllFilteredSelected ? "解除" : "すべて選択") {
                            let visible = Set(filteredEntries.map(\.url))
                            if areAllFilteredSelected {
                                selectedEntryURLs.subtract(visible)
                            } else {
                                selectedEntryURLs.formUnion(visible)
                            }
                        }
                        Button("完了") {
                            exitSelectionMode()
                        }
                        .fontWeight(.medium)
                    }
                } else {
                    Menu {
                        Button {
                            showNewNoteSheet = true
                        } label: {
                            Label("このフォルダに新規メモ作成", systemImage: "square.and.pencil")
                        }

                        Button {
                            selectedEntryURLs.removeAll()
                            isSelectionMode = true
                        } label: {
                            Label("項目を選択して削除", systemImage: "checkmark.circle")
                        }
                        .disabled(filteredEntries.isEmpty)

                        Divider()

                        let excludedCount = library.excludedItemCount(for: folder)
                        if excludedCount > 0 {
                            Button {
                                library.restoreExcludedItems(for: folder)
                                loadEntries()
                            } label: {
                                Label("非表示にした項目を復元 (\(excludedCount))", systemImage: "arrow.uturn.backward")
                            }
                        }

                        Button {
                            loadEntries()
                            library.triggerBackgroundFolderSync()
                        } label: {
                            Label("再読み込み", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                HStack(spacing: 12) {
                    Text("\(selectedEntryURLs.count) 件選択")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        showBulkDeleteConfirmation = true
                    } label: {
                        Label("削除", systemImage: "trash")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .disabled(selectedEntryURLs.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) {
                    Divider()
                }
            }
        }
        .sheet(isPresented: $showNewNoteSheet) {
            NewMarkdownNoteSheet { title, content in
                _ = library.createNote(in: folder, subdirectory: subdirectory, title: title, markdownContent: content, openImmediately: true)
                loadEntries()
            }
        }
        .alert(
            "名前を変更",
            isPresented: Binding(
                get: { renameTargetEntry != nil },
                set: { if !$0 { renameTargetEntry = nil } }
            )
        ) {
            TextField("名前", text: $renameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("変更") {
                if let entry = renameTargetEntry,
                   library.renameFolderEntry(entry, in: folder, to: renameDraft) {
                    loadEntries()
                }
                renameTargetEntry = nil
            }
            Button("キャンセル", role: .cancel) {
                renameTargetEntry = nil
            }
        } message: {
            Text("ファイルの場合は拡張子を省略すると元の拡張子が維持されます。")
        }
        .confirmationDialog(
            pendingDeleteEntry.map { "「\($0.name)」をアプリから削除しますか？" } ?? "",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = pendingDeleteEntry {
                Button(entry.isDirectory ? "フォルダごとアプリから削除" : "アプリから削除", role: .destructive) {
                    if library.deleteFolderEntry(entry, in: folder) {
                        loadEntries()
                    }
                    pendingDeleteEntry = nil
                }
            }
            Button("キャンセル", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            if let entry = pendingDeleteEntry {
                Text(entry.isDirectory
                     ? "このフォルダ内の項目をアプリ内の表示・一覧からのみ削除します。iCloud Drive や連携元のファイル自体は削除されません。"
                     : "アプリ内の一覧・表示からのみ削除します。iCloud Drive や連携元のファイル自体は削除されません。")
            }
        }
        .confirmationDialog(
            "選択した \(selectedEntryURLs.count) 件をアプリから削除しますか？",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("\(selectedEntryURLs.count) 件をアプリから削除", role: .destructive) {
                let targets = entries.filter { selectedEntryURLs.contains($0.url) }
                for entry in targets {
                    _ = library.deleteFolderEntry(entry, in: folder)
                }
                exitSelectionMode()
                loadEntries()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("アプリ内の一覧・表示からのみ削除します。iCloud Drive や連携元のファイル自体は削除されません。")
        }
        .refreshable {
            loadEntries()
        }
        .onAppear {
            loadEntries()
        }
        .onChange(of: library.documents) { _, _ in
            loadEntries()
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: FolderEntry) -> some View {
        let isSelected = selectedEntryURLs.contains(entry.url)

        Group {
            if isSelectionMode {
                Button {
                    if isSelected {
                        selectedEntryURLs.remove(entry.url)
                    } else {
                        selectedEntryURLs.insert(entry.url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                            .frame(width: 24)
                        entryLabelContent(entry, showChevron: false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if entry.isDirectory {
                NavigationLink {
                    FolderBrowserView(
                        folder: folder,
                        subdirectory: entry.url,
                        library: library
                    )
                } label: {
                    Label(entry.name, systemImage: "folder.fill")
                        .foregroundStyle(.primary)
                }
            } else {
                Button {
                    library.openEntryFromWatchedFolder(entry, folder: folder)
                } label: {
                    entryLabelContent(entry, showChevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: !isSelectionMode && !entry.isDirectory) {
            if !isSelectionMode && !entry.isDirectory {
                let pinned = library.isPinned(entry: entry, in: folder)
                Button {
                    library.togglePin(entry: entry, in: folder)
                } label: {
                    Label(pinned ? "解除" : "ピン", systemImage: pinned ? "pin.slash" : "pin")
                }
                .tint(Color.accentColor)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button(role: entry.isDirectory ? nil : .destructive) {
                    if entry.isDirectory {
                        pendingDeleteEntry = entry
                    } else if library.deleteFolderEntry(entry, in: folder) {
                        loadEntries()
                    }
                } label: {
                    Label("アプリから削除", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if !isSelectionMode {
                if !entry.isDirectory {
                    let pinned = library.isPinned(entry: entry, in: folder)
                    Button {
                        library.togglePin(entry: entry, in: folder)
                    } label: {
                        Label(pinned ? "ピン留めを解除" : "ピン留めする", systemImage: pinned ? "pin.slash" : "pin")
                    }
                }

                Button {
                    renameDraft = entry.isDirectory ? entry.name : entry.url.deletingPathExtension().lastPathComponent
                    renameTargetEntry = entry
                } label: {
                    Label("名前を変更", systemImage: "pencil")
                }

                Button {
                    selectedEntryURLs = [entry.url]
                    isSelectionMode = true
                } label: {
                    Label("複数選択…", systemImage: "checkmark.circle")
                }

                Divider()

                Button(role: .destructive) {
                    pendingDeleteEntry = entry
                } label: {
                    Label(entry.isDirectory ? "フォルダごとアプリから削除" : "アプリから削除", systemImage: "trash")
                }
            }
        }
    }

    private func entryLabelContent(_ entry: FolderEntry, showChevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.richtext")
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? Color.primary : Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !entry.isDirectory {
                    HStack(spacing: 8) {
                        if let date = entry.modifiedAt {
                            Text(date, style: .relative)
                        }
                        if let size = entry.fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedEntryURLs.removeAll()
    }

    private func loadEntries() {
        entries = library.listContents(of: folder, subdirectory: subdirectory)
    }
}
