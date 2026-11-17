import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainSyncView: View {
    @Bindable var coordinator: SyncCoordinator
    @Bindable var loginManager: LoginItemManager

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: DetailTab = .files
    @State private var searchText: String = ""
    @State private var isDropTargeted = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case files = "ファイル"
        case logs = "ログ"
        case settings = "設定"

        var id: String { rawValue }
    }

    private var palette: MacPalette {
        MacPalette.resolve(for: colorScheme)
    }

    private var filteredFiles: [SyncedFileRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return coordinator.syncedFiles }
        return coordinator.syncedFiles.filter {
            $0.fileName.localizedCaseInsensitiveContains(trimmed) ||
            $0.relativePath.localizedCaseInsensitiveContains(trimmed) ||
            $0.sourceName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 236, ideal: 252, max: 280)
        } detail: {
            detailContent
                .frame(minWidth: 580)
        }
        .frame(minWidth: 860, minHeight: 560)
        .tint(palette.accent)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(palette.accent)
                            Text("ドロップして監視フォルダに追加")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(palette.primaryText)
                        }
                        .padding(24)
                        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            destinationPanel
                .padding(16)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            HStack(spacing: 8) {
                Text("監視フォルダ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.mutedText)
                Spacer()
                Button {
                    coordinator.pickFoldersAndFiles()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("追加")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(palette.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if coordinator.sources.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(palette.mutedText)
                    Text("フォルダまたは .md を追加")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                    Text("ドロップしたフォルダ内の Markdown を自動で iCloud Drive へ同期します")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.mutedText)
                        .multilineTextAlignment(.center)
                    Button {
                        coordinator.pickFoldersAndFiles()
                    } label: {
                        Text("フォルダを選択")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accentTextOnFill)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(palette.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(coordinator.sources) { source in
                            SourceRowView(source: source, coordinator: coordinator, palette: palette)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(palette.mutedText)
                Text("iPhone で iCloud Drive/MarkPocket を連携")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(palette.sidebar)
    }

    private var destinationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: coordinator.isICloudDriveAvailable ? "icloud" : "icloud.slash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(coordinator.isICloudDriveAvailable ? palette.accent : palette.warning)
                    .frame(width: 16)

                Text("同期先")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)

                Spacer()

                Button {
                    coordinator.openDestinationInFinder()
                } label: {
                    Text("Finder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Text(friendlyDestinationLabel)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(coordinator.destinationURL.path)

            if let uploadLine = iCloudUploadStatusText {
                HStack(spacing: 6) {
                    Circle()
                        .fill(iCloudUploadStatusColor)
                        .frame(width: 6, height: 6)
                    Text(uploadLine)
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(iCloudUploadTextColor)
                        .lineLimit(1)
                    if coordinator.iCloudUploadSummary?.permissionDenied == true {
                        Spacer(minLength: 4)
                        Button("許可設定") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .buttonStyle(.plain)
                    }
                }
                .help(coordinator.iCloudUploadSummary?.firstErrorMessage ?? coordinator.destinationURL.path)
            }

            if !coordinator.isICloudDriveAvailable && coordinator.settings.destinationMode == .iCloudDriveMarkPocket {
                Text("Mac のシステム設定で iCloud Drive を有効にしてください")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.warning)
            }
        }
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(palette.hairline, lineWidth: 1)
        )
    }

    private var iCloudUploadStatusText: String? {
        guard coordinator.settings.destinationMode == .iCloudDriveMarkPocket
                || coordinator.iCloudUploadSummary?.isUbiquitousContainer == true else {
            return nil
        }
        guard let summary = coordinator.iCloudUploadSummary else {
            return coordinator.sources.isEmpty ? nil : "iCloud Drive の状態を確認中…"
        }
        guard summary.isUbiquitousContainer else {
            return nil
        }
        if summary.permissionDenied {
            return "iCloud Drive のアクセス許可が必要です"
        }
        if summary.totalCount == 0 {
            return "同期ファイル待機中"
        }
        if summary.errorCount > 0 {
            return "アップロードエラー \(summary.errorCount) 件"
        }
        if summary.isFullyUploaded {
            return "iCloud 同期済み (\(summary.uploadedCount) 件)"
        }
        return "iCloud へ転送中 (\(summary.uploadedCount)/\(summary.totalCount))"
    }

    private var iCloudUploadStatusColor: Color {
        guard let summary = coordinator.iCloudUploadSummary else { return palette.accent }
        if summary.permissionDenied { return palette.warning }
        if summary.errorCount > 0 { return palette.negative }
        if summary.isFullyUploaded { return palette.positive }
        if summary.totalCount == 0 { return palette.mutedText }
        return palette.accent
    }

    private var iCloudUploadTextColor: Color {
        guard let summary = coordinator.iCloudUploadSummary else { return palette.secondaryText }
        if summary.permissionDenied { return palette.warning }
        if summary.errorCount > 0 { return palette.negative }
        return palette.secondaryText
    }

    private var friendlyDestinationLabel: String {
        if coordinator.settings.destinationMode == .iCloudDriveMarkPocket {
            return "iCloud Drive / MarkPocket"
        }
        return coordinator.destinationURL.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    // MARK: - Detail Panel

    private var detailContent: some View {
        VStack(spacing: 0) {
            statusHeaderBar
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            Group {
                switch selectedTab {
                case .files:
                    syncedFilesView
                case .logs:
                    logsView
                case .settings:
                    settingsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.canvas)
        }
        .background(palette.canvas)
    }

    private var statusHeaderBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)

                Text(statusTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: true, vertical: false)

                if let last = coordinator.lastSyncDate {
                    Text("·")
                        .foregroundStyle(palette.mutedText)
                    Text(last, format: .dateTime.hour().minute().second())
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.mutedText)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            tabSwitcher

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    coordinator.settings.isAutoSyncEnabled.toggle()
                } label: {
                    Text(coordinator.settings.isAutoSyncEnabled ? "停止" : "再開")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    Task { await coordinator.syncNow() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                        Text(coordinator.isSyncing ? "同期中" : "同期")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.accentTextOnFill)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isSyncing)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(palette.canvas)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { tab in
                let isActive = selectedTab == tab
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? palette.primaryText : palette.mutedText)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isActive ? palette.card : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isActive ? palette.hairline : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.hairline, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusTitle: String {
        if coordinator.isSyncing { return "同期中" }
        if !coordinator.settings.isAutoSyncEnabled { return "一時停止" }
        return "自動監視中"
    }

    private var statusDotColor: Color {
        if coordinator.isSyncing { return palette.accent }
        if !coordinator.settings.isAutoSyncEnabled { return palette.warning }
        return coordinator.sources.contains(where: \.isEnabled) ? palette.positive : palette.mutedText
    }

    // MARK: - Synced Files Tab

    private var syncedFilesView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.mutedText)
                    TextField("ファイルを検索", text: $searchText)
                        .font(.system(size: 13, weight: .regular))
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(palette.mutedText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.hairline, lineWidth: 1)
                )

                Text("\(filteredFiles.count) 件")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedText)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            if filteredFiles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(palette.mutedText)
                    Text(coordinator.sources.isEmpty ? "監視フォルダが未登録です" : "一致するファイルがありません")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                    Text(
                        coordinator.sources.isEmpty
                        ? "左のサイドバーにフォルダを追加するとここに一覧が表示されます"
                        : "検索キーワードを見直してください"
                    )
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.mutedText)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredFiles) { item in
                            SyncedFileRow(item: item, palette: palette) {
                                coordinator.revealInFinder(item.destinationURL)
                            } onRevealSource: {
                                coordinator.revealInFinder(URL(fileURLWithPath: item.sourcePath))
                            } onOpenSource: {
                                NSWorkspace.shared.open(URL(fileURLWithPath: item.sourcePath))
                            }

                            Rectangle()
                                .fill(palette.hairline)
                                .frame(height: 1)
                                .padding(.leading, 48)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Logs Tab

    private var logsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("アクティビティ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Text("\(coordinator.logs.count)")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedText)
                Spacer()
                Button("クリア") {
                    coordinator.clearLogs()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .buttonStyle(.plain)
                .disabled(coordinator.logs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            if coordinator.logs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(palette.mutedText)
                    Text("同期ログはありません")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                    Text("ファイルの追加・更新・削除が行われると記録されます")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.mutedText)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(coordinator.logs) { log in
                            HStack(alignment: .center, spacing: 12) {
                                Text(log.kind.badge)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(color(for: log.kind))
                                    .frame(width: 44, height: 22)
                                    .background(color(for: log.kind).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.message)
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    if let detail = log.detail {
                                        Text(detail)
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .foregroundStyle(palette.mutedText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }

                                Spacer()

                                Text(log.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.mutedText)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)

                            Rectangle()
                                .fill(palette.hairline)
                                .frame(height: 1)
                                .padding(.leading, 76)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Settings Tab

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsCard(title: "同期先の保存場所") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("モード", selection: $coordinator.settings.destinationMode) {
                            ForEach(SyncDestinationMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Text(coordinator.destinationURL.path)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("変更") {
                                coordinator.pickCustomDestinationFolder()
                            }
                            .controlSize(.small)
                            Button("Finder で開く") {
                                coordinator.openDestinationInFinder()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                settingsCard(title: "同期ルール") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("監視フォルダごとのサブフォルダ階層を維持する", isOn: $coordinator.settings.preserveFolderStructure)
                        Toggle("Mac 側で削除されたファイルを iCloud 同期先からも削除する", isOn: $coordinator.settings.deleteRemovedFiles)
                        Toggle("同フォルダ内の参照画像（PNG / JPG / SVG 等）も同期する", isOn: $coordinator.settings.syncReferencedImages)
                        Toggle(".txt ファイルも同期対象に含める", isOn: $coordinator.settings.syncPlainTextFiles)
                    }
                    .font(.system(size: 13, weight: .regular))
                }

                settingsCard(title: "システムと除外設定") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Mac ログイン時に MarkPocket Sync を自動起動する",
                            isOn: Binding(
                                get: { loginManager.isEnabled },
                                set: { loginManager.setEnabled($0) }
                            )
                        )
                        .font(.system(size: 13, weight: .regular))

                        if let err = loginManager.lastErrorMessage {
                            Text("自動起動の設定エラー: \(err)")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.negative)
                        }

                        Rectangle()
                            .fill(palette.hairline)
                            .frame(height: 1)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("自動除外されるフォルダ")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.secondaryText)
                            Text(coordinator.settings.excludedDirectoryNames.joined(separator: ", "))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(palette.mutedText)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.mutedText)

            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(palette.hairline, lineWidth: 1)
                )
        }
    }

    // MARK: - Helpers

    private func color(for kind: SyncEventKind) -> Color {
        switch kind {
        case .added: return palette.positive
        case .updated: return palette.accent
        case .removed: return palette.warning
        case .info: return palette.secondaryText
        case .error: return palette.negative
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    coordinator.addSourceURLs([url])
                }
            }
        }
        return accepted
    }
}

private struct SyncedFileRow: View {
    let item: SyncedFileRecord
    let palette: MacPalette
    let onRevealDestination: () -> Void
    let onRevealSource: () -> Void
    let onOpenSource: () -> Void

    @State private var isHovered = false

    private var isMarkdown: Bool {
        let ext = item.destinationURL.pathExtension.lowercased()
        return MarkdownSyncEngine.markdownExtensions.contains(ext) || ext == "txt"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMarkdown ? "doc.text" : "photo")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(palette.mutedText)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(item.relativePath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(item.formattedSize)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.mutedText)
                .frame(width: 68, alignment: .trailing)

            Text(item.modifiedAt, format: .dateTime.month(.defaultDigits).day().hour().minute())
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.mutedText)
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .background(isHovered ? palette.raised.opacity(0.55) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onOpenSource()
        }
        .contextMenu {
            Button("元のファイルを開く") { onOpenSource() }
            Button("Finder で iCloud ファイルを表示") { onRevealDestination() }
            Button("Finder で元のファイルを表示") { onRevealSource() }
        }
    }
}

private struct SourceRowView: View {
    let source: WatchedSource
    @Bindable var coordinator: SyncCoordinator
    let palette: MacPalette

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(source.isEnabled ? palette.secondaryText : palette.mutedText)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(source.isEnabled ? palette.primaryText : palette.mutedText)
                    .lineLimit(1)
                Text(source.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Button {
                coordinator.toggleSource(source)
            } label: {
                Circle()
                    .fill(source.isEnabled ? palette.accent : palette.mutedText.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(source.isEnabled ? "監視をオフ" : "監視をオン")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? palette.raised : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Toggle("監視を有効にする", isOn: Binding(
                get: { source.isEnabled },
                set: { _ in coordinator.toggleSource(source) }
            ))
            if source.isDirectory {
                Toggle("サブフォルダも含める", isOn: Binding(
                    get: { source.includeSubfolders },
                    set: { _ in coordinator.toggleIncludeSubfolders(source) }
                ))
            }
            Button("Finder で表示") {
                coordinator.revealInFinder(source.url)
            }
            Divider()
            Button("監視対象から削除", role: .destructive) {
                coordinator.removeSource(source)
            }
        }
    }
}
