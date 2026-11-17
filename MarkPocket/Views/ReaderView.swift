import SwiftUI
import UIKit

struct ReaderView: View {
    let document: PocketDocument
    @Bindable var library: DocumentLibraryStore
    @Bindable var preferences: ReaderPreferences

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.openURL) private var systemOpenURL
    @Environment(\.dismiss) private var dismiss

    @State private var rawMarkdown: String = ""
    @State private var parsedDocument: MarkdownDocument = .empty
    @State private var baseDirectoryURL: URL?
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var stopSecurityScopeAccess: (() -> Void)?

    @State private var showRawSource = false
    @State private var showAppearanceSheet = false
    @State private var showTOCSheet = false
    @State private var showEditorSheet = false
    @State private var activeImagePreview: ImagePreviewItem?

    // Find in document
    @State private var isSearchVisible = false
    @State private var searchQuery = ""
    @State private var searchMatches: [SearchMatch] = []
    @State private var currentMatchIndex = 0
    @FocusState private var isSearchFocused: Bool

    // PDF share & management
    @State private var exportedPDFURL: URL?
    @State private var showPDFShareSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showRenameAlert = false
    @State private var renameDraft = ""

    private let parser = MarkdownParser()

    private var currentDoc: PocketDocument {
        library.documents.first(where: { $0.id == document.id }) ?? document
    }

    private var palette: ThemePalette {
        preferences.theme.palette(for: systemScheme)
    }

    private var activeMatchBlockID: String? {
        guard isSearchVisible,
              !searchMatches.isEmpty,
              currentMatchIndex >= 0,
              currentMatchIndex < searchMatches.count else {
            return nil
        }
        return searchMatches[currentMatchIndex].blockID
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                if isSearchVisible {
                    findInPageBar(scrollProxy: scrollProxy)
                }

                Group {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("読み込み中")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage = loadErrorMessage {
                        ContentUnavailableView {
                            Label("ファイルを読み込めませんでした", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("再試行") {
                                Task { await loadDocumentAsync() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if showRawSource {
                        rawSourceScrollView
                    } else {
                        renderedScrollView(scrollProxy: scrollProxy)
                    }
                }
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(currentDoc.title)
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(preferences.theme.preferredColorScheme)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAppearanceSheet = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .accessibilityLabel("表示設定")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    moreActionsMenu
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showTOCSheet = true
                    } label: {
                        Label("目次", systemImage: "list.bullet.indent")
                    }
                    .disabled(parsedDocument.headings.isEmpty && parsedDocument.stats.lineCount == 0)
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchVisible.toggle()
                            if isSearchVisible {
                                isSearchFocused = true
                            } else {
                                clearSearch()
                            }
                        }
                    } label: {
                        Label("検索", systemImage: "magnifyingglass")
                    }
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showRawSource.toggle()
                        }
                    } label: {
                        Label(
                            showRawSource ? "プレビュー" : "原文",
                            systemImage: showRawSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right"
                        )
                    }
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        library.togglePin(currentDoc)
                    } label: {
                        Label(
                            currentDoc.isPinned ? "ピン解除" : "ピン留め",
                            systemImage: currentDoc.isPinned ? "pin.fill" : "pin"
                        )
                        .foregroundStyle(currentDoc.isPinned ? palette.accent : .primary)
                    }
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                handleLinkTap(url, scrollProxy: scrollProxy)
            })
            .sheet(isPresented: $showAppearanceSheet) {
                AppearanceSettingsSheet(preferences: preferences)
            }
            .sheet(isPresented: $showTOCSheet) {
                TableOfContentsSheet(
                    document: parsedDocument,
                    documentTitle: currentDoc.title,
                    palette: palette
                ) { heading in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(heading.id, anchor: .top)
                        }
                    }
                }
            }
            .sheet(isPresented: $showEditorSheet) {
                RawMarkdownEditorSheet(
                    title: currentDoc.title,
                    initialText: rawMarkdown,
                    isWritable: library.isWritable(currentDoc),
                    onSave: { updated in
                        if library.saveMarkdownContent(updated, for: currentDoc) {
                            applyMarkdownText(updated)
                        }
                    },
                    onDuplicateEditable: { text in
                        let newTitle = "\(currentDoc.title) コピー"
                        _ = library.createNewNote(title: newTitle, markdownContent: text, openImmediately: true)
                    }
                )
            }
            .sheet(item: $activeImagePreview) { item in
                ImagePreviewSheet(item: item)
            }
            .sheet(isPresented: $showPDFShareSheet) {
                if let url = exportedPDFURL {
                    ActivityShareSheet(items: [url])
                }
            }
            .alert("ファイル名を変更", isPresented: $showRenameAlert) {
                TextField("ファイル名", text: $renameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("変更") {
                    _ = library.renameDocument(currentDoc, to: renameDraft)
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("拡張子を省略すると元の拡張子が維持されます。")
            }
            .confirmationDialog(
                library.deleteConfirmationTitle(for: currentDoc),
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(library.deleteActionLabel(for: currentDoc), role: .destructive) {
                    if library.deleteDocument(currentDoc) {
                        dismiss()
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(library.deleteConfirmationMessage(for: currentDoc))
            }
            .onChange(of: searchQuery) { _, newValue in
                updateSearchMatches(for: newValue, scrollProxy: scrollProxy)
            }
            .task(id: document.id) {
                clearSearch()
                library.markOpened(currentDoc)
                await loadDocumentAsync()
            }
            .onDisappear {
                stopSecurityScopeAccess?()
                stopSecurityScopeAccess = nil
            }
        }
    }

    // MARK: - Subviews

    private func renderedScrollView(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Compact reading meta bar
                readingMetaHeader(scrollProxy: scrollProxy)

                if preferences.showFrontmatter, !parsedDocument.frontmatter.isEmpty {
                    FrontmatterBannerView(items: parsedDocument.frontmatter, palette: palette)
                }

                if parsedDocument.blocks.isEmpty {
                    ContentUnavailableView(
                        "空のドキュメント",
                        systemImage: "doc.text",
                        description: Text("この Markdown ファイルには表示する内容がありません")
                    )
                    .padding(.top, 40)
                } else {
                    MarkdownBlocksView(
                        blocks: parsedDocument.blocks,
                        context: RenderContext(
                            palette: palette,
                            fontSize: CGFloat(preferences.fontSize),
                            fontDesign: preferences.fontDesign.swiftUIDesign,
                            lineSpacing: preferences.lineSpacing.points,
                            wrapCodeLines: preferences.wrapCodeLines,
                            showCodeLineNumbers: preferences.showCodeLineNumbers,
                            isWritable: library.isWritable(currentDoc),
                            searchQuery: isSearchVisible ? searchQuery : "",
                            activeMatchBlockID: activeMatchBlockID,
                            baseDirectoryURL: baseDirectoryURL,
                            onToggleTask: { sourceLine in
                                if let updated = library.toggleTaskCheckbox(in: currentDoc, sourceLine: sourceLine) {
                                    applyMarkdownText(updated)
                                }
                            },
                            onTapImage: { item in
                                activeImagePreview = item
                            }
                        )
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: 740, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .refreshable {
            await loadDocumentAsync()
        }
    }

    private func readingMetaHeader(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Label(currentDoc.watchedRelativePath ?? currentDoc.fileName, systemImage: currentDoc.sourceKind.badgeSymbol)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("約\(parsedDocument.stats.estimatedReadingMinutes)分 · \(parsedDocument.stats.wordCount)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)

            if !parsedDocument.headings.isEmpty {
                Button {
                    showTOCSheet = true
                } label: {
                    Text("# \(parsedDocument.headings.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.secondaryBackground, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(palette.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    private var rawSourceScrollView: some View {
        let lines = rawMarkdown.components(separatedBy: "\n")
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Markdown 原文", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Text("\(lines.count) 行 • \(rawMarkdown.count) 文字")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.secondaryBackground)

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, _ in
                                Text("\(idx + 1)")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(palette.secondaryText.opacity(0.55))
                            }
                        }

                        Text(rawMarkdown)
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(palette.primaryText)
                            .lineSpacing(2.5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(16)
                }
            }
        }
        .refreshable {
            await loadDocumentAsync()
        }
    }

    private func findInPageBar(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                TextField("ページ内検索", text: $searchQuery)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFocused)
                    .onSubmit {
                        stepMatch(delta: 1, scrollProxy: scrollProxy)
                    }

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 8))

            if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(searchMatches.isEmpty ? "0件" : "\(currentMatchIndex + 1)/\(searchMatches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
                    .frame(minWidth: 38)
            }

            Button {
                stepMatch(delta: -1, scrollProxy: scrollProxy)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(searchMatches.isEmpty)

            Button {
                stepMatch(delta: 1, scrollProxy: scrollProxy)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(searchMatches.isEmpty)

            Button("完了") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSearchVisible = false
                    clearSearch()
                }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.secondaryBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 0.5)
        }
    }

    private var moreActionsMenu: some View {
        Menu {
            Button {
                showEditorSheet = true
            } label: {
                Label(library.isWritable(currentDoc) ? "Markdown を編集" : "原文エディタ / 複製", systemImage: "square.and.pencil")
            }

            Button {
                Task { await loadDocumentAsync() }
            } label: {
                Label("再読み込み", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                UIPasteboard.general.string = rawMarkdown
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("Markdown 原文をコピー", systemImage: "doc.on.doc")
            }

            Button {
                let plain = parsedDocument.blocks.map(\.plainText).joined(separator: "\n\n")
                UIPasteboard.general.string = plain
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("プレーンテキストをコピー", systemImage: "text.alignleft")
            }

            ShareLink(item: rawMarkdown, subject: Text(currentDoc.title)) {
                Label("テキストを共有", systemImage: "square.and.arrow.up")
            }

            Button {
                if let pdfURL = MarkdownPDFExporter.exportPDF(title: currentDoc.title, document: parsedDocument) {
                    exportedPDFURL = pdfURL
                    showPDFShareSheet = true
                }
            } label: {
                Label("PDF として書き出す", systemImage: "doc.richtext")
            }

            if library.canRename(currentDoc) {
                Divider()

                Button {
                    renameDraft = URL(fileURLWithPath: currentDoc.fileName).deletingPathExtension().lastPathComponent
                    showRenameAlert = true
                } label: {
                    Label("ファイル名を変更", systemImage: "pencil")
                }
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(library.deleteActionLabel(for: currentDoc), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Actions & Helpers

    private func loadDocumentAsync() async {
        stopSecurityScopeAccess?()
        stopSecurityScopeAccess = nil

        if rawMarkdown.isEmpty {
            isLoading = true
        }
        loadErrorMessage = nil

        if let resolved = library.resolveURL(for: currentDoc) {
            baseDirectoryURL = resolved.url.deletingLastPathComponent()
            stopSecurityScopeAccess = resolved.stopAccess
        }

        let result = await library.loadMarkdownContentAsync(for: currentDoc)
        guard !Task.isCancelled else { return }

        switch result {
        case .success(let text):
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownParser().parse(text)
            }.value
            guard !Task.isCancelled else { return }
            rawMarkdown = text
            parsedDocument = parsed
            loadErrorMessage = nil
        case .failure(let error):
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func applyMarkdownText(_ text: String) {
        rawMarkdown = text
        parsedDocument = parser.parse(text)
    }

    private func updateSearchMatches(for query: String, scrollProxy: ScrollViewProxy) {
        searchMatches = parsedDocument.searchMatches(for: query)
        currentMatchIndex = 0
        if let first = searchMatches.first {
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy.scrollTo(first.blockID, anchor: .center)
            }
        }
    }

    private func stepMatch(delta: Int, scrollProxy: ScrollViewProxy) {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + delta + searchMatches.count) % searchMatches.count
        let target = searchMatches[currentMatchIndex]
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollProxy.scrollTo(target.blockID, anchor: .center)
        }
    }

    private func clearSearch() {
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = 0
        isSearchFocused = false
    }

    private func handleLinkTap(_ url: URL, scrollProxy: ScrollViewProxy) -> OpenURLAction.Result {
        if url.scheme == "markpocket-anchor" {
            let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let decoded = (raw.removingPercentEncoding ?? raw).lowercased()
            if let targetHeading = parsedDocument.headings.first(where: {
                $0.anchor.lowercased() == decoded || $0.text.lowercased() == decoded
            }) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollProxy.scrollTo(targetHeading.id, anchor: .top)
                }
            }
            return .handled
        }

        if url.scheme == "markpocket-rel" {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = comps.queryItems?.first(where: { $0.name == "path" })?.value {
                if library.openRelativeMarkdownLink(path, from: currentDoc) {
                    return .handled
                }
            }
            return .handled
        }

        systemOpenURL(url)
        return .handled
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
