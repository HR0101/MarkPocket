import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var library: DocumentLibraryStore
    @Bindable var preferences: ReaderPreferences

    @Environment(\.colorScheme) private var systemScheme
    @State private var searchText = ""
    @State private var sortOption: LibrarySortOption = .lastOpened
    @State private var activePickerMode: DocumentPickerMode?
    @State private var showNewNoteSheet = false
    @State private var showGlobalAppearanceSheet = false

    // Selection & management states
    @State private var isSelectionMode = false
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var pendingDeleteDocument: PocketDocument?
    @State private var showBulkDeleteConfirmation = false
    @State private var renameTargetDocument: PocketDocument?
    @State private var renameDraft = ""

    private var palette: ThemePalette {
        preferences.theme.palette(for: systemScheme)
    }

    private var displayedDocuments: [PocketDocument] {
        library.sortedDocuments(sort: sortOption, query: searchText)
    }

    private var pinnedDocuments: [PocketDocument] {
        displayedDocuments.filter(\.isPinned)
    }

    private var unpinnedDocuments: [PocketDocument] {
        displayedDocuments.filter { !$0.isPinned }
    }

    private static var markdownFileTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        if let markdown = UTType(filenameExtension: "markdown") { types.insert(markdown, at: 0) }
        if let daring = UTType("net.daringfireball.markdown") { types.insert(daring, at: 0) }
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    quickActionsSection
                    if library.watchedFolders.isEmpty {
                        iCloudLinkPromptSection
                    } else {
                        watchedFoldersSection
                    }
                }

                if !pinnedDocuments.isEmpty {
                    Section {
                        ForEach(pinnedDocuments) { doc in
                            documentRow(doc)
                        }
                    } header: {
                        sectionHeader("ピン留め", count: pinnedDocuments.count)
                    }
                }

                Section {
                    if unpinnedDocuments.isEmpty && pinnedDocuments.isEmpty {
                        ContentUnavailableView {
                            Label(
                                searchText.isEmpty ? "ドキュメントがありません" : "一致するドキュメントがありません",
                                systemImage: searchText.isEmpty ? "doc.text" : "magnifyingglass"
                            )
                        } description: {
                            Text(
                                searchText.isEmpty
                                ? "右上の追加メニューから .md ファイルまたはクリップボードの内容を開けます"
                                : "検索キーワードを変更してやり直してください"
                            )
                        } actions: {
                            if searchText.isEmpty {
                                Button("ガイドを復元") {
                                    library.restoreSampleDocuments()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(unpinnedDocuments) { doc in
                            documentRow(doc)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text("ライブラリ")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                        if library.isSyncingFolders {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Spacer()
                        Text("\(displayedDocuments.count) 件")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondaryText)
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("MarkPocket")
            .searchable(text: $searchText, prompt: "タイトル・ファイル名・本文を検索")
            .refreshable {
                library.rescanLocalDocuments()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelectionMode {
                        Button(areAllDisplayedSelected ? "選択解除" : "すべて選択") {
                            toggleSelectAllDisplayed()
                        }
                    } else {
                        Menu {
                            Picker("並び替え", selection: $sortOption) {
                                ForEach(LibrarySortOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }

                            Divider()

                            Button {
                                selectedDocumentIDs.removeAll()
                                isSelectionMode = true
                            } label: {
                                Label("項目を選択して整理", systemImage: "checkmark.circle")
                            }
                            .disabled(displayedDocuments.isEmpty)

                            Button {
                                showGlobalAppearanceSheet = true
                            } label: {
                                Label("リーダー表示設定", systemImage: "textformat.size")
                            }

                            Button {
                                library.restoreSampleDocuments()
                            } label: {
                                Label("サンプルガイドを復元", systemImage: "book.closed")
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                        }
                        .accessibilityLabel("表示と並び替え")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isSelectionMode {
                        Button("完了") {
                            exitSelectionMode()
                        }
                        .fontWeight(.medium)
                    } else {
                        Menu {
                            Button {
                                activePickerMode = .files(types: Self.markdownFileTypes, allowsMultiple: true)
                            } label: {
                                Label("ファイルを開く", systemImage: "doc")
                            }

                            Button {
                                activePickerMode = .folder
                            } label: {
                                Label("フォルダを連携", systemImage: "folder")
                            }

                            Divider()

                            Button {
                                openFromClipboard()
                            } label: {
                                Label("クリップボードから開く", systemImage: "doc.on.clipboard")
                            }

                            Button {
                                showNewNoteSheet = true
                            } label: {
                                Label("新規 Markdown メモ", systemImage: "square.and.pencil")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.medium)
                        }
                        .accessibilityLabel("追加")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    selectionActionBar
                }
            }
            .navigationDestination(item: $library.activeDocument) { doc in
                ReaderView(document: doc, library: library, preferences: preferences)
            }
            .sheet(item: $activePickerMode) { mode in
                DocumentPickerSheet(mode: mode) { urls in
                    activePickerMode = nil
                    switch mode {
                    case .files:
                        Task {
                            for (idx, url) in urls.enumerated() {
                                _ = await library.importExternalFileAsync(from: url, openImmediately: idx == urls.count - 1)
                            }
                        }
                    case .folder:
                        if let folderURL = urls.first {
                            library.addWatchedFolder(from: folderURL)
                        }
                    }
                } onCancel: {
                    activePickerMode = nil
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showNewNoteSheet) {
                NewMarkdownNoteSheet { title, content in
                    _ = library.createNewNote(title: title, markdownContent: content, openImmediately: true)
                }
            }
            .sheet(isPresented: $showGlobalAppearanceSheet) {
                AppearanceSettingsSheet(preferences: preferences)
            }
            .alert(
                "お知らせ",
                isPresented: Binding(
                    get: { library.alertMessage != nil },
                    set: { if !$0 { library.alertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.alertMessage ?? "")
            }
            .alert(
                "ファイル名を変更",
                isPresented: Binding(
                    get: { renameTargetDocument != nil },
                    set: { if !$0 { renameTargetDocument = nil } }
                )
            ) {
                TextField("ファイル名", text: $renameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("変更") {
                    if let doc = renameTargetDocument {
                        _ = library.renameDocument(doc, to: renameDraft)
                    }
                    renameTargetDocument = nil
                }
                Button("キャンセル", role: .cancel) {
                    renameTargetDocument = nil
                }
            } message: {
                Text("拡張子を省略すると元の拡張子が維持されます。")
            }
            .confirmationDialog(
                pendingDeleteDocument.map { library.deleteConfirmationTitle(for: $0) } ?? "",
                isPresented: Binding(
                    get: { pendingDeleteDocument != nil },
                    set: { if !$0 { pendingDeleteDocument = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let doc = pendingDeleteDocument {
                    Button(library.deleteActionLabel(for: doc), role: .destructive) {
                        _ = library.deleteDocument(doc)
                        pendingDeleteDocument = nil
                    }
                }
                Button("キャンセル", role: .cancel) {
                    pendingDeleteDocument = nil
                }
            } message: {
                if let doc = pendingDeleteDocument {
                    Text(library.deleteConfirmationMessage(for: doc))
                }
            }
            .confirmationDialog(
                "選択した \(selectedDocumentIDs.count) 件を削除しますか？",
                isPresented: $showBulkDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("\(selectedDocumentIDs.count) 件を削除", role: .destructive) {
                    _ = library.deleteDocuments(ids: selectedDocumentIDs)
                    exitSelectionMode()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(bulkDeleteMessage)
            }
        }
        .tint(palette.accent)
    }

    // MARK: - Subviews

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Text("\(count) 件")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)
        }
        .textCase(nil)
    }

    private var quickActionsSection: some View {
        Section {
            HStack(spacing: 8) {
                QuickActionTile(
                    title: "ファイル",
                    subtitle: "Files / iCloud",
                    icon: "doc",
                    palette: palette
                ) {
                    activePickerMode = .files(types: Self.markdownFileTypes, allowsMultiple: true)
                }

                QuickActionTile(
                    title: "クリップボード",
                    subtitle: "コピー文を表示",
                    icon: "doc.on.clipboard",
                    palette: palette
                ) {
                    openFromClipboard()
                }

                QuickActionTile(
                    title: "新規メモ",
                    subtitle: ".md 作成",
                    icon: "square.and.pencil",
                    palette: palette
                ) {
                    showNewNoteSheet = true
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private var watchedFoldersSection: some View {
        Section {
            ForEach(library.watchedFolders) { folder in
                NavigationLink {
                    FolderBrowserView(folder: folder, subdirectory: nil, library: library)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(palette.accent)
                            .frame(width: 24, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(palette.primaryText)
                            Text("フォルダ別に見る")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button("連携解除", role: .destructive) {
                        library.removeWatchedFolder(folder)
                    }
                }
                .contextMenu {
                    Button {
                        library.triggerBackgroundFolderSync()
                    } label: {
                        Label("フォルダを再読み込み", systemImage: "arrow.clockwise")
                    }

                    let excludedCount = library.excludedItemCount(for: folder)
                    if excludedCount > 0 {
                        Button {
                            library.restoreExcludedItems(for: folder)
                        } label: {
                            Label("アプリから削除した項目を復元 (\(excludedCount))", systemImage: "arrow.uturn.backward")
                        }
                    }

                    Button(role: .destructive) {
                        library.removeWatchedFolder(folder)
                    } label: {
                        Label("連携を解除", systemImage: "folder.badge.minus")
                    }
                }
            }
        } header: {
            sectionHeader("連携フォルダ", count: library.watchedFolders.count)
        }
    }

    private var iCloudLinkPromptSection: some View {
        Section {
            Button {
                activePickerMode = .folder
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "icloud")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(palette.accent)
                        .frame(width: 24, alignment: .center)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud フォルダを連携")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.primaryText)
                        Text("iCloud Drive/MarkPocket を選ぶと Mac の .md が自動反映")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText.opacity(0.6))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func documentRow(_ doc: PocketDocument) -> some View {
        let isSelected = selectedDocumentIDs.contains(doc.id)
        return Button {
            if isSelectionMode {
                toggleSelection(for: doc.id)
            } else {
                library.markOpened(doc)
                library.activeDocument = doc
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isSelected ? palette.accent : palette.secondaryText.opacity(0.45))
                        .frame(width: 24, alignment: .center)
                        .padding(.top, 2)
                } else {
                    Image(systemName: rowIconName(for: doc))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(doc.sourceKind == .watchedFolder ? palette.accent : palette.secondaryText)
                        .frame(width: 24, alignment: .center)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(doc.title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        if doc.isPinned {
                            Image(systemName: "pin")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.accent)
                        }
                    }

                    if !doc.previewText.isEmpty {
                        Text(doc.previewText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text(doc.watchedRelativePath ?? doc.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                        Text("約\(doc.estimatedReadingMinutes)分")
                        Text("·")
                        Text(doc.modifiedAt, format: .dateTime.month(.defaultDigits).day())
                    }
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryText.opacity(0.75))
                }

                Spacer(minLength: 8)

                if !isSelectionMode {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText.opacity(0.5))
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: !isSelectionMode) {
            if !isSelectionMode {
                Button {
                    library.togglePin(doc)
                } label: {
                    Label(doc.isPinned ? "解除" : "ピン", systemImage: doc.isPinned ? "pin.slash" : "pin")
                }
                .tint(palette.accent)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button(role: .destructive) {
                    _ = library.deleteDocument(doc)
                } label: {
                    Label(library.deleteActionLabel(for: doc), systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if !isSelectionMode {
                Button {
                    library.togglePin(doc)
                } label: {
                    Label(doc.isPinned ? "ピン留めを解除" : "ピン留めする", systemImage: doc.isPinned ? "pin.slash" : "pin")
                }

                if library.canRename(doc) {
                    Button {
                        beginRename(doc)
                    } label: {
                        Label("ファイル名を変更", systemImage: "pencil")
                    }
                }

                Button {
                    selectedDocumentIDs = [doc.id]
                    isSelectionMode = true
                } label: {
                    Label("複数選択…", systemImage: "checkmark.circle")
                }

                Divider()

                Button(role: .destructive) {
                    pendingDeleteDocument = doc
                } label: {
                    Label(library.deleteActionLabel(for: doc), systemImage: "trash")
                }
            }
        }
    }

    private func rowIconName(for doc: PocketDocument) -> String {
        switch doc.sourceKind {
        case .sample: return "book.closed"
        case .watchedFolder: return "icloud"
        case .localFile, .externalBookmark: return "doc.text"
        }
    }

    // MARK: - Actions

    private func openFromClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            library.alertMessage = "クリップボードにテキストがコピーされていません"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd_HHmm"
        let defaultName = "Clipboard_\(formatter.string(from: Date()))"
        _ = library.createNewNote(title: defaultName, markdownContent: text, openImmediately: true)
    }

    // MARK: - Selection & Delete Helpers

    private var areAllDisplayedSelected: Bool {
        !displayedDocuments.isEmpty && displayedDocuments.allSatisfy { selectedDocumentIDs.contains($0.id) }
    }

    private func toggleSelection(for id: UUID) {
        if selectedDocumentIDs.contains(id) {
            selectedDocumentIDs.remove(id)
        } else {
            selectedDocumentIDs.insert(id)
        }
    }

    private func toggleSelectAllDisplayed() {
        let visibleIDs = Set(displayedDocuments.map(\.id))
        if areAllDisplayedSelected {
            selectedDocumentIDs.subtract(visibleIDs)
        } else {
            selectedDocumentIDs.formUnion(visibleIDs)
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedDocumentIDs.removeAll()
    }

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedDocumentIDs.count) 件選択")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)

            Spacer()

            Button {
                library.setPinned(true, for: selectedDocumentIDs)
                exitSelectionMode()
            } label: {
                Label("ピン留め", systemImage: "pin")
                    .font(.system(size: 14, weight: .medium))
            }
            .disabled(selectedDocumentIDs.isEmpty)

            Button(role: .destructive) {
                showBulkDeleteConfirmation = true
            } label: {
                Label("削除", systemImage: "trash")
                    .font(.system(size: 14, weight: .medium))
            }
            .disabled(selectedDocumentIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.secondaryBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 0.5)
        }
    }

    private func beginRename(_ doc: PocketDocument) {
        renameDraft = URL(fileURLWithPath: doc.fileName).deletingPathExtension().lastPathComponent
        renameTargetDocument = doc
    }

    private var bulkDeleteMessage: String {
        let selected = library.documents.filter { selectedDocumentIDs.contains($0.id) }
        let hasExternalOrWatched = selected.contains { $0.sourceKind == .watchedFolder || $0.sourceKind == .externalBookmark }
        let hasLocal = selected.contains { $0.sourceKind == .localFile || $0.sourceKind == .sample }
        if hasExternalOrWatched && !hasLocal {
            return "アプリ内の一覧からのみ削除します。iCloud Drive や端末内の元のファイルは削除されません。"
        }
        if hasExternalOrWatched && hasLocal {
            return "選択項目をアプリ内から削除します（iCloud Drive や外部ファイル自体は削除されません）。"
        }
        return "アプリ内に保存されたメモを削除します（iCloud Drive には影響しません）。"
    }
}

private struct QuickActionTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let palette: ThemePalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 20, height: 20, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(palette.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct NewMarkdownNoteSheet: View {
    @State private var title = ""
    @State private var content = "# 新しいメモ\n\nここに Markdown を入力してください\n"
    let onCreate: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("ファイル名 / タイトル") {
                    TextField("Meeting_Notes", text: $title)
                        .textInputAutocapitalization(.never)
                }

                Section("Markdown 本文") {
                    TextEditor(text: $content)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(minHeight: 240)
                }
            }
            .navigationTitle("新規 Markdown メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") {
                        onCreate(title, content)
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
}
