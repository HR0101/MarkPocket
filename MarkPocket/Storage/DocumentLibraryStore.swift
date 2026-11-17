import Foundation
import Observation

@MainActor
@Observable
final class DocumentLibraryStore {
    private(set) var documents: [PocketDocument] = []
    private(set) var watchedFolders: [WatchedFolder] = []
    private(set) var excludedWatchedKeys: Set<String> = []
    private(set) var isSyncingFolders: Bool = false
    var activeDocument: PocketDocument?
    var alertMessage: String?

    private let fileManager: FileManager
    let documentsDirectory: URL
    private let metadataDirectory: URL
    private let indexFileURL: URL
    private let foldersFileURL: URL
    private let excludedItemsFileURL: URL
    private let parser = MarkdownParser()
    private var activeFolderSyncTask: Task<Void, Never>?

    private nonisolated static let supportedExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "txt"
    ]

    private enum DefaultsKeys {
        static let seededSamples = "markpocket.didSeedSamples.v1"
    }

    enum LoadError: LocalizedError {
        case cannotResolveAccess
        case fileNotFound
        case failedToDecode(String)

        var errorDescription: String? {
            switch self {
            case .cannotResolveAccess:
                return "ファイルへのアクセス権を取得できませんでした。もう一度ファイルまたはフォルダを選択してください。"
            case .fileNotFound:
                return "ファイルが見つかりませんでした。iCloud Drive 上で移動または削除された可能性があります。"
            case .failedToDecode(let name):
                return "「\(name)」の文字コードを判別して読み込めませんでした。"
            }
        }
    }

    init(
        fileManager: FileManager = .default,
        documentsDirectory: URL? = nil,
        metadataDirectory: URL? = nil,
        seedSamplesIfNeeded: Bool = true
    ) {
        self.fileManager = fileManager

        let resolvedDocs = documentsDirectory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resolvedAppSupport = metadataDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkPocket", isDirectory: true)

        self.documentsDirectory = resolvedDocs
        self.metadataDirectory = resolvedAppSupport
        self.indexFileURL = resolvedAppSupport.appendingPathComponent("library_index.json")
        self.foldersFileURL = resolvedAppSupport.appendingPathComponent("watched_folders.json")
        self.excludedItemsFileURL = resolvedAppSupport.appendingPathComponent("excluded_items.json")

        try? fileManager.createDirectory(at: resolvedDocs, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resolvedAppSupport, withIntermediateDirectories: true)

        loadIndex()
        if seedSamplesIfNeeded {
            seedInitialSamplesIfNeeded()
        }
        rescanLocalDocuments()
    }

    // MARK: - Library Scanning & Persistence

    func rescanLocalDocuments(triggerWatchedFolderSync: Bool = true) {
        if let entries = try? fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            var localPathsPresent: Set<String> = []

            for url in entries {
                let ext = url.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

                let relPath = url.lastPathComponent
                localPathsPresent.insert(relPath)

                if let existingIndex = documents.firstIndex(where: { $0.localRelativePath == relPath }) {
                    refreshMetadata(at: existingIndex, url: url)
                } else if let text = Self.decodeMarkdownData(from: url) {
                    let kind: DocumentSourceKind = (relPath == SampleDocuments.guideFileName || relPath == SampleDocuments.cheatSheetFileName) ? .sample : .localFile
                    let doc = makePocketDocument(
                        url: url,
                        text: text,
                        sourceKind: kind,
                        localRelativePath: relPath,
                        bookmarkData: nil
                    )
                    documents.append(doc)
                }
            }

            documents.removeAll { doc in
                if let rel = doc.localRelativePath, doc.sourceKind == .localFile || doc.sourceKind == .sample {
                    return !localPathsPresent.contains(rel)
                }
                return false
            }

            saveIndex()
        }

        if triggerWatchedFolderSync && !watchedFolders.isEmpty {
            triggerBackgroundFolderSync()
        }
    }

    func triggerBackgroundFolderSync() {
        activeFolderSyncTask?.cancel()
        activeFolderSyncTask = Task { @MainActor [weak self] in
            await self?.syncWatchedFoldersAsync()
        }
    }

    private func seedInitialSamplesIfNeeded() {
        let alreadySeeded = UserDefaults.standard.bool(forKey: DefaultsKeys.seededSamples)
        guard !alreadySeeded else { return }

        let samples: [(String, String)] = [
            (SampleDocuments.guideFileName, SampleDocuments.guideMarkdown),
            (SampleDocuments.cheatSheetFileName, SampleDocuments.cheatSheetMarkdown)
        ]

        for (fileName, content) in samples {
            let url = documentsDirectory.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: url.path) {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        UserDefaults.standard.set(true, forKey: DefaultsKeys.seededSamples)
    }

    func restoreSampleDocuments() {
        let samples: [(String, String)] = [
            (SampleDocuments.guideFileName, SampleDocuments.guideMarkdown),
            (SampleDocuments.cheatSheetFileName, SampleDocuments.cheatSheetMarkdown)
        ]
        for (fileName, content) in samples {
            let url = documentsDirectory.appendingPathComponent(fileName)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        rescanLocalDocuments(triggerWatchedFolderSync: false)
    }

    // MARK: - Sorting & Filtering

    func sortedDocuments(sort: LibrarySortOption, query: String) -> [PocketDocument] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [PocketDocument]
        if trimmedQuery.isEmpty {
            filtered = documents
        } else {
            filtered = documents.filter { doc in
                doc.title.localizedCaseInsensitiveContains(trimmedQuery) ||
                doc.fileName.localizedCaseInsensitiveContains(trimmedQuery) ||
                (doc.watchedRelativePath?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
                doc.previewText.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }

        return filtered.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            switch sort {
            case .lastOpened:
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            case .modifiedDate:
                return lhs.modifiedAt > rhs.modifiedAt
            case .title:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    // MARK: - Importing & Opening Files

    func importExternalFileAsync(from url: URL, openImmediately: Bool = true) async -> PocketDocument? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        // If a folder URL was sent, register it as a watched folder instead
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            addWatchedFolder(from: url)
            return nil
        }

        let inboxPrefix = documentsDirectory.appendingPathComponent("Inbox").standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path

        if standardizedPath.hasPrefix(inboxPrefix) || standardizedPath.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) {
            return copyIntoLocalLibrary(from: url, openImmediately: openImmediately)
        }

        let docsPrefix = documentsDirectory.standardizedFileURL.path
        if standardizedPath.hasPrefix(docsPrefix + "/") {
            let relPath = String(standardizedPath.dropFirst(docsPrefix.count + 1))
            if let existing = documents.first(where: { $0.localRelativePath == relPath }) {
                if openImmediately {
                    markOpened(existing)
                    activeDocument = existing
                }
                return existing
            }
            rescanLocalDocuments(triggerWatchedFolderSync: false)
            if let added = documents.first(where: { $0.localRelativePath == relPath }) {
                if openImmediately { activeDocument = added }
                return added
            }
        }

        // If the selected file lives inside an already-linked watched folder, reuse that watched document
        if let watchedMatch = findMatchingWatchedDocument(for: url) {
            if openImmediately {
                markOpened(watchedMatch)
                activeDocument = watchedMatch
            }
            return watchedMatch
        }

        let text = await Task.detached(priority: .userInitiated) {
            Self.readCoordinatedText(from: url)
        }.value

        guard let text else {
            alertMessage = "「\(url.lastPathComponent)」を読み込めませんでした。iCloud からダウンロード中か、テキスト形式のファイルか確認してください。"
            return nil
        }

        if let bookmark = Self.createBookmark(for: url) {
            if let idx = documents.firstIndex(where: { $0.sourceKind == .externalBookmark && $0.fileName == url.lastPathComponent && matchesBookmark($0.bookmarkData, url: url) }) {
                documents[idx].bookmarkData = bookmark
                documents[idx].lastOpenedAt = Date()
                updateStatsAndPreview(at: idx, text: text, url: url)
                saveIndex()
                if openImmediately { activeDocument = documents[idx] }
                return documents[idx]
            }

            let doc = makePocketDocument(
                url: url,
                text: text,
                sourceKind: .externalBookmark,
                localRelativePath: nil,
                bookmarkData: bookmark
            )
            documents.insert(doc, at: 0)
            saveIndex()
            if openImmediately { activeDocument = doc }
            return doc
        } else {
            return copyIntoLocalLibrary(from: url, openImmediately: openImmediately)
        }
    }

    @discardableResult
    func importExternalFile(from url: URL, openImmediately: Bool = true) -> PocketDocument? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let inboxPrefix = documentsDirectory.appendingPathComponent("Inbox").standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path

        if standardizedPath.hasPrefix(inboxPrefix) || standardizedPath.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) {
            return copyIntoLocalLibrary(from: url, openImmediately: openImmediately)
        }

        let docsPrefix = documentsDirectory.standardizedFileURL.path
        if standardizedPath.hasPrefix(docsPrefix + "/") {
            let relPath = String(standardizedPath.dropFirst(docsPrefix.count + 1))
            if let existing = documents.first(where: { $0.localRelativePath == relPath }) {
                if openImmediately {
                    markOpened(existing)
                    activeDocument = existing
                }
                return existing
            }
            rescanLocalDocuments(triggerWatchedFolderSync: false)
            if let added = documents.first(where: { $0.localRelativePath == relPath }) {
                if openImmediately { activeDocument = added }
                return added
            }
        }

        guard let text = Self.readCoordinatedText(from: url) else {
            alertMessage = "「\(url.lastPathComponent)」を読み込めませんでした。"
            return nil
        }

        if let bookmark = Self.createBookmark(for: url) {
            if let idx = documents.firstIndex(where: { $0.sourceKind == .externalBookmark && $0.fileName == url.lastPathComponent && matchesBookmark($0.bookmarkData, url: url) }) {
                documents[idx].bookmarkData = bookmark
                documents[idx].lastOpenedAt = Date()
                updateStatsAndPreview(at: idx, text: text, url: url)
                saveIndex()
                if openImmediately { activeDocument = documents[idx] }
                return documents[idx]
            }

            let doc = makePocketDocument(
                url: url,
                text: text,
                sourceKind: .externalBookmark,
                localRelativePath: nil,
                bookmarkData: bookmark
            )
            documents.insert(doc, at: 0)
            saveIndex()
            if openImmediately { activeDocument = doc }
            return doc
        } else {
            return copyIntoLocalLibrary(from: url, openImmediately: openImmediately)
        }
    }

    @discardableResult
    func copyIntoLocalLibrary(from url: URL, openImmediately: Bool = true) -> PocketDocument? {
        guard let text = Self.readCoordinatedText(from: url) else {
            alertMessage = "ファイルを読み込めませんでした。"
            return nil
        }
        let targetURL = uniqueLocalFileURL(preferredName: url.lastPathComponent)
        do {
            try text.write(to: targetURL, atomically: true, encoding: .utf8)
            if url.standardizedFileURL.path.contains("/Documents/Inbox/") {
                try? fileManager.removeItem(at: url)
            }
            let doc = makePocketDocument(
                url: targetURL,
                text: text,
                sourceKind: .localFile,
                localRelativePath: targetURL.lastPathComponent,
                bookmarkData: nil
            )
            documents.insert(doc, at: 0)
            saveIndex()
            if openImmediately { activeDocument = doc }
            return doc
        } catch {
            alertMessage = "ファイルの保存に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func createNewNote(title: String, markdownContent: String, openImmediately: Bool = true) -> PocketDocument? {
        let baseName = sanitizedFileName(from: title.isEmpty ? "Untitled" : title)
        let targetURL = uniqueLocalFileURL(preferredName: "\(baseName).md")
        do {
            try markdownContent.write(to: targetURL, atomically: true, encoding: .utf8)
            let doc = makePocketDocument(
                url: targetURL,
                text: markdownContent,
                sourceKind: .localFile,
                localRelativePath: targetURL.lastPathComponent,
                bookmarkData: nil
            )
            documents.insert(doc, at: 0)
            saveIndex()
            if openImmediately { activeDocument = doc }
            return doc
        } catch {
            alertMessage = "メモの作成に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Watched Folders

    func addWatchedFolder(from url: URL, syncImmediately: Bool = true) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let bookmark = Self.createBookmark(for: url) else {
            alertMessage = "「\(url.lastPathComponent)」へのアクセス権を保存できませんでした。"
            return
        }

        if watchedFolders.contains(where: { matchesBookmark($0.bookmarkData, url: url) }) {
            if syncImmediately {
                triggerBackgroundFolderSync()
            }
            return
        }

        let folder = WatchedFolder(
            id: UUID(),
            name: url.lastPathComponent.isEmpty ? "連携フォルダ" : url.lastPathComponent,
            bookmarkData: bookmark,
            addedAt: Date()
        )
        watchedFolders.append(folder)
        saveFolders()

        if syncImmediately {
            triggerBackgroundFolderSync()
        }
    }

    func removeWatchedFolder(_ folder: WatchedFolder) {
        watchedFolders.removeAll { $0.id == folder.id }
        documents.removeAll { $0.sourceKind == .watchedFolder && $0.watchedFolderID == folder.id }
        let prefix = "\(folder.id.uuidString)|"
        excludedWatchedKeys = excludedWatchedKeys.filter { !$0.hasPrefix(prefix) }
        saveFolders()
        saveIndex()
        saveExcludedItems()
    }

    func excludedItemCount(for folder: WatchedFolder) -> Int {
        let prefix = "\(folder.id.uuidString)|"
        return excludedWatchedKeys.count { $0.hasPrefix(prefix) }
    }

    func restoreExcludedItems(for folder: WatchedFolder, syncImmediately: Bool = true) {
        let prefix = "\(folder.id.uuidString)|"
        let before = excludedWatchedKeys.count
        excludedWatchedKeys = excludedWatchedKeys.filter { !$0.hasPrefix(prefix) }
        guard excludedWatchedKeys.count != before else { return }
        saveExcludedItems()
        if syncImmediately {
            triggerBackgroundFolderSync()
        }
    }

    /// Synchronous folder sync helper (useful for unit tests and immediate checks).
    func syncWatchedFolders() {
        let foldersSnapshot = watchedFolders
        let excludedSnapshot = excludedWatchedKeys
        let result = Self.scanWatchedFolders(foldersSnapshot, excludedKeys: excludedSnapshot)
        applyFolderScanResult(result)
    }

    /// Non-blocking recursive sync of all linked folders, optimized for large iCloud Drive trees.
    func syncWatchedFoldersAsync() async {
        let foldersSnapshot = watchedFolders
        let excludedSnapshot = excludedWatchedKeys
        guard !foldersSnapshot.isEmpty else {
            documents.removeAll { $0.sourceKind == .watchedFolder }
            saveIndex()
            return
        }

        isSyncingFolders = true
        let result = await Task.detached(priority: .userInitiated) {
            Self.scanWatchedFolders(foldersSnapshot, excludedKeys: excludedSnapshot)
        }.value

        guard !Task.isCancelled else {
            isSyncingFolders = false
            return
        }

        applyFolderScanResult(result)
        isSyncingFolders = false
    }

    private struct ScannedFolderItem: Sendable {
        let folderID: UUID
        let relativePath: String
        let fileName: String
        let title: String
        let previewText: String
        let byteSize: Int
        let modifiedAt: Date
        let estimatedReadingMinutes: Int
    }

    private struct FolderScanResult: Sendable {
        let items: [ScannedFolderItem]
        let refreshedBookmarks: [UUID: Data]
        let succeededFolderIDs: Set<UUID>
    }

    private nonisolated static func scanWatchedFolders(_ folders: [WatchedFolder], excludedKeys: Set<String>) -> FolderScanResult {
        let fm = FileManager.default
        var scannedItems: [ScannedFolderItem] = []
        var refreshedBookmarks: [UUID: Data] = [:]
        var succeededFolderIDs: Set<UUID> = []

        for folder in folders {
            var isStale = false
            guard let rootURL = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }

            let didAccess = rootURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { rootURL.stopAccessingSecurityScopedResource() }
            }

            if isStale, let refreshed = createBookmark(for: rootURL) {
                refreshedBookmarks[folder.id] = refreshed
            }

            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .ubiquitousItemDownloadingStatusKey
            ]

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: []
            ) else {
                continue
            }

            succeededFolderIDs.insert(folder.id)

            let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"

            for case let fileURL as URL in enumerator {
                let rawName = fileURL.lastPathComponent
                let values = try? fileURL.resourceValues(forKeys: Set(keys))

                if values?.isDirectory == true {
                    let canonicalDir = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                    let dirRel = canonicalDir.hasPrefix(rootPrefix) ? String(canonicalDir.dropFirst(rootPrefix.count)) : rawName
                    if rawName.hasPrefix(".") || isWatchedPathExcluded(folderID: folder.id, relativePath: dirRel, excludedKeys: excludedKeys) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Handle iCloud `.Name.md.icloud` placeholder stub files if present
                let isICloudStub = rawName.hasPrefix(".") && fileURL.pathExtension.lowercased() == "icloud"
                if rawName.hasPrefix(".") && !isICloudStub {
                    continue
                }

                let logicalName: String
                let logicalURL: URL
                let canonicalParent = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                if isICloudStub {
                    let withoutDot = String(rawName.dropFirst())
                    logicalName = String(withoutDot.dropLast(".icloud".count))
                    logicalURL = canonicalParent.appendingPathComponent(logicalName)
                } else {
                    logicalName = rawName
                    logicalURL = canonicalParent.appendingPathComponent(logicalName)
                }

                let ext = logicalURL.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }

                let stdLogical = logicalURL.path
                let relPath = stdLogical.hasPrefix(rootPrefix)
                    ? String(stdLogical.dropFirst(rootPrefix.count))
                    : logicalName

                if isWatchedPathExcluded(folderID: folder.id, relativePath: relPath, excludedKeys: excludedKeys) {
                    continue
                }

                let modDate = values?.contentModificationDate ?? Date()
                let byteSize = values?.fileSize ?? 0
                let downloadStatus = values?.ubiquitousItemDownloadingStatus
                let isLocallyReadable = !isICloudStub && (downloadStatus == nil || downloadStatus != .notDownloaded)

                var title = logicalURL.deletingPathExtension().lastPathComponent
                var previewText = isLocallyReadable ? "" : "iCloud からタップして読み込み"
                let estimatedMinutes = max(1, byteSize / 1500)

                if isLocallyReadable, let snippet = readPrefixSummary(from: fileURL) {
                    if !snippet.title.isEmpty { title = snippet.title }
                    previewText = snippet.preview
                }

                scannedItems.append(
                    ScannedFolderItem(
                        folderID: folder.id,
                        relativePath: relPath,
                        fileName: logicalName,
                        title: title,
                        previewText: previewText,
                        byteSize: byteSize,
                        modifiedAt: modDate,
                        estimatedReadingMinutes: estimatedMinutes
                    )
                )
            }
        }

        return FolderScanResult(
            items: scannedItems,
            refreshedBookmarks: refreshedBookmarks,
            succeededFolderIDs: succeededFolderIDs
        )
    }

    private func applyFolderScanResult(_ result: FolderScanResult) {
        for (folderID, newBookmark) in result.refreshedBookmarks {
            if let idx = watchedFolders.firstIndex(where: { $0.id == folderID }) {
                watchedFolders[idx].bookmarkData = newBookmark
            }
        }
        if !result.refreshedBookmarks.isEmpty {
            saveFolders()
        }

        let activeFolderIDs = Set(watchedFolders.map(\.id))
        var existingByKey: [String: PocketDocument] = [:]
        var nonWatchedDocs: [PocketDocument] = []

        for doc in documents {
            if doc.sourceKind == .watchedFolder {
                if let fid = doc.watchedFolderID, let rel = doc.watchedRelativePath, activeFolderIDs.contains(fid) {
                    existingByKey["\(fid.uuidString)|\(rel)"] = doc
                }
            } else {
                nonWatchedDocs.append(doc)
            }
        }

        var updatedWatchedDocs: [PocketDocument] = []
        updatedWatchedDocs.reserveCapacity(result.items.count)

        for item in result.items {
            if Self.isWatchedPathExcluded(folderID: item.folderID, relativePath: item.relativePath, excludedKeys: excludedWatchedKeys) {
                continue
            }
            let key = Self.watchedItemKey(folderID: item.folderID, relativePath: item.relativePath)
            if var existing = existingByKey.removeValue(forKey: key) {
                existing.fileName = item.fileName
                existing.title = item.title
                if !item.previewText.isEmpty {
                    existing.previewText = item.previewText
                }
                existing.byteSize = item.byteSize
                existing.modifiedAt = item.modifiedAt
                existing.estimatedReadingMinutes = max(existing.estimatedReadingMinutes, item.estimatedReadingMinutes)
                updatedWatchedDocs.append(existing)
            } else {
                let newDoc = PocketDocument(
                    id: UUID(),
                    title: item.title,
                    fileName: item.fileName,
                    localRelativePath: nil,
                    bookmarkData: nil,
                    watchedFolderID: item.folderID,
                    watchedRelativePath: item.relativePath,
                    sourceKind: .watchedFolder,
                    isPinned: false,
                    lastOpenedAt: item.modifiedAt,
                    modifiedAt: item.modifiedAt,
                    previewText: item.previewText,
                    byteSize: item.byteSize,
                    wordCount: item.byteSize / 3,
                    estimatedReadingMinutes: item.estimatedReadingMinutes,
                    lastScrollBlockID: nil
                )
                updatedWatchedDocs.append(newDoc)
            }
        }

        // Retain cached items for folders that temporarily couldn't be enumerated (if any)
        for (_, leftover) in existingByKey {
            if let fid = leftover.watchedFolderID, !result.succeededFolderIDs.contains(fid) {
                updatedWatchedDocs.append(leftover)
            }
        }

        documents = nonWatchedDocs + updatedWatchedDocs
        saveIndex()
    }

    func listContents(of folder: WatchedFolder, subdirectory: URL? = nil) -> [FolderEntry] {
        guard let rootAccess = resolveWatchedFolderRoot(folder) else {
            return []
        }
        defer { rootAccess.stopAccess() }
        let rootURL = rootAccess.url

        let targetURL = subdirectory ?? rootURL
        guard let urls = try? fileManager.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        var entries: [FolderEntry] = []
        for itemURL in urls {
            let rawName = itemURL.lastPathComponent
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let isICloudStub = rawName.hasPrefix(".") && itemURL.pathExtension.lowercased() == "icloud"
            if rawName.hasPrefix(".") && !isICloudStub { continue }

            let displayName: String
            let targetEntryURL: URL
            if isICloudStub {
                displayName = String(rawName.dropFirst().dropLast(".icloud".count))
                targetEntryURL = itemURL.deletingLastPathComponent().appendingPathComponent(displayName)
            } else {
                displayName = rawName
                targetEntryURL = itemURL
            }

            if !isDir {
                let ext = targetEntryURL.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { continue }
            }
            let relPath = Self.relativePath(of: targetEntryURL, itemName: displayName, inside: rootURL)
            if Self.isWatchedPathExcluded(folderID: folder.id, relativePath: relPath, excludedKeys: excludedWatchedKeys) {
                continue
            }
            entries.append(
                FolderEntry(
                    id: targetEntryURL,
                    url: targetEntryURL,
                    name: displayName,
                    isDirectory: isDir,
                    modifiedAt: values?.contentModificationDate,
                    fileSize: values?.fileSize
                )
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func openEntryFromWatchedFolder(_ entry: FolderEntry, folder: WatchedFolder) {
        guard let rootAccess = resolveWatchedFolderRoot(folder) else { return }
        defer { rootAccess.stopAccess() }

        let relPath = Self.relativePath(of: entry.url, itemName: entry.name, inside: rootAccess.url)
        let doc = findOrCreateWatchedDocument(entry: entry, folder: folder, relativePath: relPath, markAsOpened: true)
        activeDocument = doc
    }

    func isPinned(entry: FolderEntry, in folder: WatchedFolder) -> Bool {
        guard !entry.isDirectory, let rootAccess = resolveWatchedFolderRoot(folder) else { return false }
        defer { rootAccess.stopAccess() }
        let relPath = Self.relativePath(of: entry.url, itemName: entry.name, inside: rootAccess.url)
        return documents.first(where: {
            $0.sourceKind == .watchedFolder &&
            $0.watchedFolderID == folder.id &&
            $0.watchedRelativePath == relPath
        })?.isPinned ?? false
    }

    func togglePin(entry: FolderEntry, in folder: WatchedFolder) {
        guard !entry.isDirectory, let rootAccess = resolveWatchedFolderRoot(folder) else { return }
        defer { rootAccess.stopAccess() }
        let relPath = Self.relativePath(of: entry.url, itemName: entry.name, inside: rootAccess.url)
        let doc = findOrCreateWatchedDocument(entry: entry, folder: folder, relativePath: relPath, markAsOpened: false)
        togglePin(doc)
    }

    @discardableResult
    func createNote(
        in folder: WatchedFolder,
        subdirectory: URL?,
        title: String,
        markdownContent: String,
        openImmediately: Bool = true
    ) -> PocketDocument? {
        guard let rootAccess = resolveWatchedFolderRoot(folder) else {
            alertMessage = "フォルダへのアクセス権を取得できませんでした。"
            return nil
        }
        defer { rootAccess.stopAccess() }

        let targetDir = subdirectory ?? rootAccess.url
        let baseName = sanitizedFileName(from: title.isEmpty ? "Untitled" : title)
        let targetURL = uniqueFileURL(in: targetDir, preferredName: baseName.hasSuffix(".md") ? baseName : "\(baseName).md")

        do {
            try coordinateWriteText(markdownContent, to: targetURL)
            let relPath = Self.relativePath(of: targetURL, itemName: targetURL.lastPathComponent, inside: rootAccess.url)
            let parsed = parser.parse(markdownContent)
            let doc = PocketDocument(
                id: UUID(),
                title: deriveTitle(parsed: parsed, fallbackFileName: targetURL.deletingPathExtension().lastPathComponent),
                fileName: targetURL.lastPathComponent,
                localRelativePath: nil,
                bookmarkData: nil,
                watchedFolderID: folder.id,
                watchedRelativePath: relPath,
                sourceKind: .watchedFolder,
                isPinned: false,
                lastOpenedAt: Date(),
                modifiedAt: Date(),
                previewText: derivePreview(parsed: parsed),
                byteSize: markdownContent.utf8.count,
                wordCount: parsed.stats.wordCount,
                estimatedReadingMinutes: parsed.stats.estimatedReadingMinutes,
                lastScrollBlockID: nil
            )
            documents.insert(doc, at: 0)
            saveIndex()
            if openImmediately { activeDocument = doc }
            return doc
        } catch {
            alertMessage = "メモの作成に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func deleteFolderEntry(_ entry: FolderEntry, in folder: WatchedFolder) -> Bool {
        guard let rootAccess = resolveWatchedFolderRoot(folder) else {
            alertMessage = "フォルダへのアクセス権を取得できませんでした。"
            return false
        }
        defer { rootAccess.stopAccess() }

        let relPath = Self.relativePath(of: entry.url, itemName: entry.name, inside: rootAccess.url)
        excludedWatchedKeys.insert(Self.watchedItemKey(folderID: folder.id, relativePath: relPath))
        removeIndexedWatchedDocuments(folderID: folder.id, relativePath: relPath, isDirectory: entry.isDirectory)
        saveExcludedItems()
        saveIndex()
        return true
    }

    @discardableResult
    func renameFolderEntry(_ entry: FolderEntry, in folder: WatchedFolder, to rawNewName: String) -> Bool {
        guard let rootAccess = resolveWatchedFolderRoot(folder) else {
            alertMessage = "フォルダへのアクセス権を取得できませんでした。"
            return false
        }
        defer { rootAccess.stopAccess() }

        guard let targetName = resolvedRenamedFileName(from: rawNewName, existingURL: entry.url, isDirectory: entry.isDirectory) else {
            alertMessage = "有効な名前を入力してください。"
            return false
        }

        let parentDir = entry.url.deletingLastPathComponent()
        let destURL = parentDir.appendingPathComponent(targetName, isDirectory: entry.isDirectory)
        guard destURL.standardizedFileURL != entry.url.standardizedFileURL else { return true }
        guard existingPhysicalURL(for: destURL) == nil else {
            alertMessage = "同名の項目「\(targetName)」がすでに存在します。"
            return false
        }

        let sourcePhysical = existingPhysicalURL(for: entry.url) ?? entry.url
        do {
            try coordinateMoveItem(from: sourcePhysical, to: destURL)
            let oldRel = Self.relativePath(of: entry.url, itemName: entry.name, inside: rootAccess.url)
            let newRel = Self.relativePath(of: destURL, itemName: targetName, inside: rootAccess.url)
            updateIndexedWatchedPathsAfterRename(folderID: folder.id, oldRelativePath: oldRel, newRelativePath: newRel, newName: targetName, isDirectory: entry.isDirectory)
            saveIndex()
            return true
        } catch {
            alertMessage = "名前を変更できませんでした: \(error.localizedDescription)"
            return false
        }
    }

    private func resolveWatchedFolderRoot(_ folder: WatchedFolder) -> (url: URL, stopAccess: () -> Void)? {
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: folder.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        if isStale, let refreshed = Self.createBookmark(for: rootURL),
           let idx = watchedFolders.firstIndex(where: { $0.id == folder.id }) {
            watchedFolders[idx].bookmarkData = refreshed
            saveFolders()
        }
        return (rootURL, {
            if didAccess { rootURL.stopAccessingSecurityScopedResource() }
        })
    }

    private func findOrCreateWatchedDocument(
        entry: FolderEntry,
        folder: WatchedFolder,
        relativePath relPath: String,
        markAsOpened: Bool
    ) -> PocketDocument {
        if let existingIdx = documents.firstIndex(where: {
            $0.sourceKind == .watchedFolder &&
            $0.watchedFolderID == folder.id &&
            $0.watchedRelativePath == relPath
        }) {
            if markAsOpened {
                documents[existingIdx].lastOpenedAt = Date()
                saveIndex()
            }
            return documents[existingIdx]
        }

        let newDoc = PocketDocument(
            id: UUID(),
            title: entry.url.deletingPathExtension().lastPathComponent,
            fileName: entry.name,
            localRelativePath: nil,
            bookmarkData: nil,
            watchedFolderID: folder.id,
            watchedRelativePath: relPath,
            sourceKind: .watchedFolder,
            isPinned: false,
            lastOpenedAt: Date(),
            modifiedAt: entry.modifiedAt ?? Date(),
            previewText: "",
            byteSize: entry.fileSize ?? 0,
            wordCount: 0,
            estimatedReadingMinutes: 1,
            lastScrollBlockID: nil
        )
        documents.insert(newDoc, at: 0)
        saveIndex()
        return newDoc
    }

    // MARK: - Reading, Updating, & Managing Documents

    func resolveURL(for document: PocketDocument) -> (url: URL, stopAccess: () -> Void)? {
        if let relPath = document.localRelativePath {
            let url = documentsDirectory.appendingPathComponent(relPath)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return (url, {})
        }

        if document.sourceKind == .watchedFolder,
           let folderID = document.watchedFolderID,
           let relPath = document.watchedRelativePath,
           let folder = watchedFolders.first(where: { $0.id == folderID }) {
            var isStale = false
            guard let rootURL = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            let didAccess = rootURL.startAccessingSecurityScopedResource()
            let fileURL = rootURL.appendingPathComponent(relPath)
            return (fileURL, {
                if didAccess { rootURL.stopAccessingSecurityScopedResource() }
            })
        }

        if let bookmarkData = document.bookmarkData {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            if isStale, let idx = documents.firstIndex(where: { $0.id == document.id }),
               let refreshed = Self.createBookmark(for: url) {
                documents[idx].bookmarkData = refreshed
                saveIndex()
            }
            return (url, {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            })
        }

        return nil
    }

    func loadMarkdownContent(for document: PocketDocument) -> String? {
        guard let resolved = resolveURL(for: document) else { return nil }
        defer { resolved.stopAccess() }

        guard let text = Self.readCoordinatedText(from: resolved.url) else { return nil }

        if let idx = documents.firstIndex(where: { $0.id == document.id }) {
            updateStatsAndPreview(at: idx, text: text, url: resolved.url)
            saveIndex()
        }
        return text
    }

    func loadMarkdownContentAsync(for document: PocketDocument) async -> Result<String, LoadError> {
        guard let resolved = resolveURL(for: document) else {
            return .failure(.cannotResolveAccess)
        }
        defer { resolved.stopAccess() }
        let targetURL = resolved.url

        let result: Result<String, LoadError> = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.isUbiquitousItem(at: targetURL) {
                try? fm.startDownloadingUbiquitousItem(at: targetURL)
            }
            if let text = Self.readCoordinatedText(from: targetURL) {
                return .success(text)
            }
            if !fm.fileExists(atPath: targetURL.path) {
                return .failure(.fileNotFound)
            }
            return .failure(.failedToDecode(targetURL.lastPathComponent))
        }.value

        if case .success(let text) = result,
           let idx = documents.firstIndex(where: { $0.id == document.id }) {
            updateStatsAndPreview(at: idx, text: text, url: targetURL)
            saveIndex()
        }
        return result
    }

    func saveMarkdownContent(_ content: String, for document: PocketDocument) -> Bool {
        guard let resolved = resolveURL(for: document) else { return false }
        defer { resolved.stopAccess() }

        do {
            try content.write(to: resolved.url, atomically: true, encoding: .utf8)
            if let idx = documents.firstIndex(where: { $0.id == document.id }) {
                updateStatsAndPreview(at: idx, text: content, url: resolved.url)
                saveIndex()
            }
            return true
        } catch {
            alertMessage = "ファイルの保存に失敗しました: \(error.localizedDescription)"
            return false
        }
    }

    func toggleTaskCheckbox(in document: PocketDocument, sourceLine: Int) -> String? {
        guard isWritable(document),
              let currentText = loadMarkdownContent(for: document) else {
            return nil
        }

        let normalized = currentText.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")

        guard sourceLine >= 0, sourceLine < lines.count else { return nil }
        let line = lines[sourceLine]

        if let range = line.range(of: "[ ]") {
            lines[sourceLine] = line.replacingCharacters(in: range, with: "[x]")
        } else if let range = line.range(of: "[x]") ?? line.range(of: "[X]") {
            lines[sourceLine] = line.replacingCharacters(in: range, with: "[ ]")
        } else {
            return nil
        }

        let updated = lines.joined(separator: "\n")
        return saveMarkdownContent(updated, for: document) ? updated : nil
    }

    func isWritable(_ document: PocketDocument) -> Bool {
        document.sourceKind == .localFile || document.sourceKind == .sample
    }

    func openRelativeMarkdownLink(_ relativeDestination: String, from currentDocument: PocketDocument) -> Bool {
        let cleanRelative = relativeDestination.components(separatedBy: "#").first ?? relativeDestination
        guard !cleanRelative.isEmpty else { return false }

        if currentDocument.sourceKind == .watchedFolder,
           let folderID = currentDocument.watchedFolderID,
           let currentRel = currentDocument.watchedRelativePath {
            let currentDir = URL(fileURLWithPath: currentRel).deletingLastPathComponent().relativePath
            let joined = (currentDir == "." || currentDir.isEmpty) ? cleanRelative : "\(currentDir)/\(cleanRelative)"
            let normalizedRel = URL(fileURLWithPath: "/\(joined)").standardized.path.dropFirst()
            if let match = documents.first(where: {
                $0.sourceKind == .watchedFolder &&
                $0.watchedFolderID == folderID &&
                $0.watchedRelativePath?.caseInsensitiveCompare(String(normalizedRel)) == .orderedSame
            }) {
                markOpened(match)
                activeDocument = match
                return true
            }
        }

        if let resolved = resolveURL(for: currentDocument) {
            defer { resolved.stopAccess() }
            let baseDir = resolved.url.deletingLastPathComponent()
            let candidate = baseDir.appendingPathComponent(cleanRelative).standardizedFileURL
            if fileManager.fileExists(atPath: candidate.path) {
                return importExternalFile(from: candidate, openImmediately: true) != nil
            }
        }

        let targetName = URL(fileURLWithPath: cleanRelative).lastPathComponent
        if let match = documents.first(where: { $0.fileName.caseInsensitiveCompare(targetName) == .orderedSame }) {
            markOpened(match)
            activeDocument = match
            return true
        }
        return false
    }

    func markOpened(_ document: PocketDocument) {
        guard let idx = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[idx].lastOpenedAt = Date()
        saveIndex()
    }

    func updateScrollAnchor(_ blockID: String?, for document: PocketDocument) {
        guard let idx = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[idx].lastScrollBlockID = blockID
        saveIndex()
    }

    func togglePin(_ document: PocketDocument) {
        guard let idx = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[idx].isPinned.toggle()
        if activeDocument?.id == document.id {
            activeDocument = documents[idx]
        }
        saveIndex()
    }

    func setPinned(_ pinned: Bool, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for idx in documents.indices where ids.contains(documents[idx].id) {
            if documents[idx].isPinned != pinned {
                documents[idx].isPinned = pinned
                changed = true
                if activeDocument?.id == documents[idx].id {
                    activeDocument = documents[idx]
                }
            }
        }
        if changed {
            saveIndex()
        }
    }

    func canRename(_ document: PocketDocument) -> Bool {
        switch document.sourceKind {
        case .localFile, .sample, .watchedFolder:
            return true
        case .externalBookmark:
            return false
        }
    }

    func deleteActionLabel(for document: PocketDocument) -> String {
        switch document.sourceKind {
        case .externalBookmark, .watchedFolder:
            return "アプリから削除"
        case .localFile, .sample:
            return "削除"
        }
    }

    func deleteConfirmationTitle(for document: PocketDocument) -> String {
        if document.sourceKind == .localFile || document.sourceKind == .sample {
            return "「\(document.fileName)」を削除しますか？"
        }
        return "「\(document.title)」をアプリから削除しますか？"
    }

    func deleteConfirmationMessage(for document: PocketDocument) -> String {
        switch document.sourceKind {
        case .watchedFolder:
            return "アプリ内の一覧からのみ削除します。iCloud Drive や連携フォルダ内の元のファイルは削除されません。"
        case .externalBookmark:
            return "アプリ内の一覧からのみ削除します。iCloud Drive や端末内の元のファイルは削除されません。"
        case .localFile, .sample:
            return "アプリ内に保存されたこのメモを削除します（iCloud Drive には影響しません）。"
        }
    }

    @discardableResult
    func deleteDocument(_ document: PocketDocument) -> Bool {
        do {
            try removeDocumentItemIfNeeded(document)
            documents.removeAll { $0.id == document.id }
            if activeDocument?.id == document.id {
                activeDocument = nil
            }
            saveIndex()
            return true
        } catch {
            alertMessage = "「\(document.fileName)」を削除できませんでした: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteDocuments(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let targets = documents.filter { ids.contains($0.id) }
        var deletedIDs: Set<UUID> = []
        var firstError: Error?
        var failedName: String?

        for doc in targets {
            do {
                try removeDocumentItemIfNeeded(doc)
                deletedIDs.insert(doc.id)
            } catch {
                if firstError == nil {
                    firstError = error
                    failedName = doc.fileName
                }
            }
        }

        if !deletedIDs.isEmpty {
            documents.removeAll { deletedIDs.contains($0.id) }
            if let activeID = activeDocument?.id, deletedIDs.contains(activeID) {
                activeDocument = nil
            }
            saveIndex()
        }

        if let firstError, let failedName {
            alertMessage = "「\(failedName)」などを削除できませんでした: \(firstError.localizedDescription)"
        }
        return deletedIDs.count
    }

    @discardableResult
    func renameDocument(_ document: PocketDocument, to rawNewName: String) -> PocketDocument? {
        guard canRename(document),
              let idx = documents.firstIndex(where: { $0.id == document.id }),
              let resolved = resolveURL(for: document) else {
            alertMessage = "ファイル名を変更できませんでした。"
            return nil
        }
        defer { resolved.stopAccess() }

        guard let targetName = resolvedRenamedFileName(from: rawNewName, existingURL: resolved.url, isDirectory: false) else {
            alertMessage = "有効なファイル名を入力してください。"
            return nil
        }

        let oldURL = resolved.url
        let destURL = oldURL.deletingLastPathComponent().appendingPathComponent(targetName)
        guard destURL.standardizedFileURL != oldURL.standardizedFileURL else {
            return documents[idx]
        }
        guard existingPhysicalURL(for: destURL) == nil else {
            alertMessage = "同名のファイル「\(targetName)」がすでに存在します。"
            return nil
        }

        let oldStem = oldURL.deletingPathExtension().lastPathComponent
        let newStem = destURL.deletingPathExtension().lastPathComponent
        let sourcePhysical = existingPhysicalURL(for: oldURL) ?? oldURL

        do {
            if document.sourceKind == .watchedFolder {
                try coordinateMoveItem(from: sourcePhysical, to: destURL)
            } else {
                try fileManager.moveItem(at: sourcePhysical, to: destURL)
            }

            documents[idx].fileName = targetName
            if let oldLocal = documents[idx].localRelativePath {
                let parentRel = URL(fileURLWithPath: oldLocal).deletingLastPathComponent().relativePath
                documents[idx].localRelativePath = (parentRel == "." || parentRel.isEmpty)
                    ? targetName
                    : "\(parentRel)/\(targetName)"
            }
            if let oldWatched = documents[idx].watchedRelativePath {
                let parentRel = URL(fileURLWithPath: oldWatched).deletingLastPathComponent().relativePath
                documents[idx].watchedRelativePath = (parentRel == "." || parentRel.isEmpty)
                    ? targetName
                    : "\(parentRel)/\(targetName)"
            }
            if documents[idx].title == oldStem || documents[idx].title.isEmpty {
                documents[idx].title = newStem
            }
            if activeDocument?.id == documents[idx].id {
                activeDocument = documents[idx]
            }
            saveIndex()
            return documents[idx]
        } catch {
            alertMessage = "ファイル名を変更できませんでした: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Helpers

    private func findMatchingWatchedDocument(for url: URL) -> PocketDocument? {
        let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        for folder in watchedFolders {
            var stale = false
            guard let rootURL = try? URL(resolvingBookmarkData: folder.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue
            }
            let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            if targetPath.hasPrefix(rootPrefix) {
                let relPath = String(targetPath.dropFirst(rootPrefix.count))
                if let match = documents.first(where: {
                    $0.sourceKind == .watchedFolder &&
                    $0.watchedFolderID == folder.id &&
                    $0.watchedRelativePath == relPath
                }) {
                    return match
                }
            }
        }
        return nil
    }

    private func makePocketDocument(
        url: URL,
        text: String,
        sourceKind: DocumentSourceKind,
        localRelativePath: String?,
        bookmarkData: Data?
    ) -> PocketDocument {
        let parsed = parser.parse(text)
        let title = deriveTitle(parsed: parsed, fallbackFileName: url.deletingPathExtension().lastPathComponent)
        let preview = derivePreview(parsed: parsed)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let byteSize = values?.fileSize ?? text.utf8.count
        let modDate = values?.contentModificationDate ?? Date()

        return PocketDocument(
            id: UUID(),
            title: title,
            fileName: url.lastPathComponent,
            localRelativePath: localRelativePath,
            bookmarkData: bookmarkData,
            sourceKind: sourceKind,
            isPinned: false,
            lastOpenedAt: Date(),
            modifiedAt: modDate,
            previewText: preview,
            byteSize: byteSize,
            wordCount: parsed.stats.wordCount,
            estimatedReadingMinutes: parsed.stats.estimatedReadingMinutes,
            lastScrollBlockID: nil
        )
    }

    private func refreshMetadata(at index: Int, url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let diskMod = values?.contentModificationDate ?? Date()
        if diskMod > documents[index].modifiedAt, let text = Self.decodeMarkdownData(from: url) {
            updateStatsAndPreview(at: index, text: text, url: url)
        }
    }

    private func updateStatsAndPreview(at index: Int, text: String, url: URL) {
        let parsed = parser.parse(text)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        documents[index].title = deriveTitle(parsed: parsed, fallbackFileName: url.deletingPathExtension().lastPathComponent)
        documents[index].previewText = derivePreview(parsed: parsed)
        documents[index].wordCount = parsed.stats.wordCount
        documents[index].estimatedReadingMinutes = parsed.stats.estimatedReadingMinutes
        documents[index].byteSize = values?.fileSize ?? text.utf8.count
        documents[index].modifiedAt = values?.contentModificationDate ?? Date()
    }

    private func deriveTitle(parsed: MarkdownDocument, fallbackFileName: String) -> String {
        if let fmTitle = parsed.frontmatter.first(where: { $0.key.lowercased() == "title" })?.value,
           !fmTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return fmTitle
        }
        if let firstH1 = parsed.headings.first(where: { $0.level == 1 })?.text, !firstH1.isEmpty {
            return firstH1
        }
        if let anyHeading = parsed.headings.first?.text, !anyHeading.isEmpty {
            return anyHeading
        }
        return fallbackFileName
    }

    private func derivePreview(parsed: MarkdownDocument) -> String {
        for block in parsed.blocks {
            switch block {
            case .paragraph(_, let inlines):
                let text = inlines.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return String(text.prefix(160)) }
            case .blockquote(_, _, _, let inner):
                let text = inner.map(\.plainText).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return String(text.prefix(160)) }
            case .list(_, _, _, let items):
                let text = items.first?.inlines.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { return String(text.prefix(160)) }
            default:
                continue
            }
        }
        return ""
    }

    /// Lightweight prefix reader (< 4 KB) so scanning 1,000+ folder files stays instant.
    private nonisolated static func readPrefixSummary(from url: URL) -> (title: String, preview: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else {
            return nil
        }

        var decodedText: String?
        for trim in 0...min(3, data.count - 1) {
            let slice = trim == 0 ? data : data.dropLast(trim)
            if let utf8 = String(data: slice, encoding: .utf8) {
                decodedText = utf8
                break
            }
        }
        if decodedText == nil {
            decodedText = decodeMarkdownString(from: data)
        }
        guard let text = decodedText else { return nil }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var idx = 0
        var fmTitle = ""
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            idx = 1
            while idx < lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." {
                    idx += 1
                    break
                }
                if t.lowercased().hasPrefix("title:") {
                    fmTitle = String(t.dropFirst(6))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                idx += 1
            }
        }

        var headingTitle = ""
        var previewLines: [String] = []
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            idx += 1
            if trimmed.isEmpty || trimmed.hasPrefix("```") || trimmed.hasPrefix("---") { continue }
            if trimmed.hasPrefix("#") {
                if headingTitle.isEmpty {
                    headingTitle = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            previewLines.append(trimmed.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
            if previewLines.joined(separator: " ").count >= 120 { break }
        }

        let resolvedTitle = !fmTitle.isEmpty ? fmTitle : headingTitle
        let preview = String(previewLines.joined(separator: " ").prefix(140))
        return (resolvedTitle, preview)
    }

    private nonisolated static func createBookmark(for url: URL) -> Data? {
        if let standard = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return standard
        }
        return try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private nonisolated static func readCoordinatedText(from url: URL) -> String? {
        let fm = FileManager.default
        if fm.isUbiquitousItem(at: url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        var coordinatedData: Data?
        var coordError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            coordinatedData = try? Data(contentsOf: readURL)
        }
        if let data = coordinatedData {
            return decodeMarkdownString(from: data)
        }
        return decodeMarkdownData(from: url)
    }

    private nonisolated static func decodeMarkdownData(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeMarkdownString(from: data)
    }

    private nonisolated static func decodeMarkdownString(from data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .shiftJIS,
            .japaneseEUC,
            .iso2022JP,
            .utf16
        ]
        for encoding in encodings {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        return nil
    }

    private func matchesBookmark(_ bookmarkData: Data?, url: URL) -> Bool {
        guard let data = bookmarkData else { return false }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return false
        }
        return resolved.standardizedFileURL == url.standardizedFileURL
    }

    private func uniqueLocalFileURL(preferredName: String) -> URL {
        uniqueFileURL(in: documentsDirectory, preferredName: preferredName)
    }

    private func sanitizedFileName(from title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(64))
    }

    private func uniqueFileURL(in directory: URL, preferredName: String) -> URL {
        let cleanName = preferredName.isEmpty ? "Untitled.md" : preferredName
        let baseURL = directory.appendingPathComponent(cleanName)
        if existingPhysicalURL(for: baseURL) == nil {
            return baseURL
        }
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension.isEmpty ? "md" : baseURL.pathExtension
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) \(counter).\(ext)")
            if existingPhysicalURL(for: candidate) == nil {
                return candidate
            }
            counter += 1
        }
    }

    private func resolvedRenamedFileName(from rawName: String, existingURL: URL, isDirectory: Bool) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = sanitizedFileName(from: trimmed)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        if isDirectory {
            return cleaned
        }
        let requestedExt = (cleaned as NSString).pathExtension.lowercased()
        if !requestedExt.isEmpty && Self.supportedExtensions.contains(requestedExt) {
            return cleaned
        }
        let originalExt = existingURL.pathExtension.isEmpty ? "md" : existingURL.pathExtension
        return "\(cleaned).\(originalExt)"
    }

    private func existingPhysicalURL(for url: URL) -> URL? {
        if fileManager.fileExists(atPath: url.path) {
            return url
        }
        let stubURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fileManager.fileExists(atPath: stubURL.path) {
            return stubURL
        }
        return nil
    }

    private func removeDocumentItemIfNeeded(_ document: PocketDocument) throws {
        switch document.sourceKind {
        case .localFile, .sample:
            if let rel = document.localRelativePath {
                let url = documentsDirectory.appendingPathComponent(rel)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        case .externalBookmark:
            break
        case .watchedFolder:
            if let folderID = document.watchedFolderID,
               let relPath = document.watchedRelativePath {
                excludedWatchedKeys.insert(Self.watchedItemKey(folderID: folderID, relativePath: relPath))
                saveExcludedItems()
            }
        }
    }

    private func removeIndexedWatchedDocuments(folderID: UUID, relativePath: String, isDirectory: Bool) {
        let dirPrefix = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
        var removedActive = false
        documents.removeAll { doc in
            guard doc.sourceKind == .watchedFolder,
                  doc.watchedFolderID == folderID,
                  let docRel = doc.watchedRelativePath else {
                return false
            }
            let match = isDirectory
                ? (docRel == relativePath || docRel.hasPrefix(dirPrefix))
                : (docRel == relativePath)
            if match && activeDocument?.id == doc.id {
                removedActive = true
            }
            return match
        }
        if removedActive {
            activeDocument = nil
        }
    }

    private func updateIndexedWatchedPathsAfterRename(
        folderID: UUID,
        oldRelativePath: String,
        newRelativePath: String,
        newName: String,
        isDirectory: Bool
    ) {
        let oldPrefix = oldRelativePath.hasSuffix("/") ? oldRelativePath : oldRelativePath + "/"
        let oldStem = URL(fileURLWithPath: oldRelativePath).deletingPathExtension().lastPathComponent
        let newStem = URL(fileURLWithPath: newName).deletingPathExtension().lastPathComponent

        for idx in documents.indices {
            guard documents[idx].sourceKind == .watchedFolder,
                  documents[idx].watchedFolderID == folderID,
                  let docRel = documents[idx].watchedRelativePath else {
                continue
            }

            if isDirectory {
                if docRel == oldRelativePath {
                    documents[idx].watchedRelativePath = newRelativePath
                } else if docRel.hasPrefix(oldPrefix) {
                    let suffix = String(docRel.dropFirst(oldPrefix.count))
                    documents[idx].watchedRelativePath = "\(newRelativePath)/\(suffix)"
                } else {
                    continue
                }
            } else if docRel == oldRelativePath {
                documents[idx].watchedRelativePath = newRelativePath
                documents[idx].fileName = newName
                if documents[idx].title == oldStem || documents[idx].title.isEmpty {
                    documents[idx].title = newStem
                }
            } else {
                continue
            }

            if activeDocument?.id == documents[idx].id {
                activeDocument = documents[idx]
            }
        }
    }

    private nonisolated static func watchedItemKey(folderID: UUID, relativePath: String) -> String {
        "\(folderID.uuidString)|\(relativePath)"
    }

    private nonisolated static func isWatchedPathExcluded(
        folderID: UUID,
        relativePath: String,
        excludedKeys: Set<String>
    ) -> Bool {
        guard !excludedKeys.isEmpty else { return false }
        if excludedKeys.contains(watchedItemKey(folderID: folderID, relativePath: relativePath)) {
            return true
        }
        let components = relativePath.split(separator: "/")
        guard components.count > 1 else { return false }
        var prefix = ""
        for idx in 0..<(components.count - 1) {
            prefix = prefix.isEmpty ? String(components[idx]) : "\(prefix)/\(components[idx])"
            if excludedKeys.contains(watchedItemKey(folderID: folderID, relativePath: prefix)) {
                return true
            }
        }
        return false
    }

    private func coordinateMoveItem(from sourceURL: URL, to destinationURL: URL) throws {
        var coordError: NSError?
        var opError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordError
        ) { src, dst in
            do {
                try fileManager.moveItem(at: src, to: dst)
                coordinator.item(at: src, didMoveTo: dst)
            } catch {
                opError = error
            }
        }
        if let opError { throw opError }
        if let coordError { throw coordError }
    }

    private func coordinateWriteText(_ content: String, to destinationURL: URL) throws {
        var coordError: NSError?
        var opError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destinationURL, options: .forReplacing, error: &coordError) { targetURL in
            do {
                try content.write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                opError = error
            }
        }
        if let opError { throw opError }
        if let coordError { throw coordError }
    }

    private nonisolated static func relativePath(of itemURL: URL, itemName: String, inside rootURL: URL) -> String {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        let entryPath = itemURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(itemName).path
        return entryPath.hasPrefix(rootPrefix)
            ? String(entryPath.dropFirst(rootPrefix.count))
            : itemName
    }

    // MARK: - JSON Index Persistence

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexFileURL),
           let decoded = try? JSONDecoder().decode([PocketDocument].self, from: data) {
            documents = decoded
        }
        if let data = try? Data(contentsOf: foldersFileURL),
           let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            watchedFolders = decoded
        }
        if let data = try? Data(contentsOf: excludedItemsFileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            excludedWatchedKeys = Set(decoded)
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(documents) {
            try? data.write(to: indexFileURL, options: .atomic)
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(watchedFolders) {
            try? data.write(to: foldersFileURL, options: .atomic)
        }
    }

    private func saveExcludedItems() {
        if let data = try? JSONEncoder().encode(Array(excludedWatchedKeys)) {
            try? data.write(to: excludedItemsFileURL, options: .atomic)
        }
    }
}
