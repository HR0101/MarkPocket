import Foundation

struct MarkdownSyncEngine: Sendable {

    nonisolated static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn"
    ]

    nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg"
    ]

    nonisolated static let maxImageByteSize = 25 * 1024 * 1024

    nonisolated init() {}

    nonisolated func performSync(
        sources: [WatchedSource],
        settings: SyncSettings,
        previousManifest: [String: ManifestItem]
    ) -> SyncExecutionReport {
        let fm = FileManager.default
        let destRoot = settings.resolvedDestinationURL.standardizedFileURL

        var events: [SyncLogEntry] = []
        var newManifest: [String: ManifestItem] = [:]
        var syncedRecords: [SyncedFileRecord] = []
        var addedCount = 0
        var updatedCount = 0
        var removedCount = 0

        do {
            try createDirectoryCoordinated(at: destRoot, fileManager: fm)
        } catch {
            events.append(SyncLogEntry(
                kind: .error,
                message: "同期先フォルダを作成できませんでした",
                detail: "\(destRoot.path): \(error.localizedDescription)"
            ))
            return SyncExecutionReport(
                manifest: previousManifest,
                syncedFiles: [],
                events: events,
                addedCount: 0,
                updatedCount: 0,
                removedCount: 0
            )
        }

        let excludedSet = Set(settings.excludedDirectoryNames)
        var candidates = collectDesiredFiles(
            sources: sources,
            settings: settings,
            destRoot: destRoot,
            excludedDirs: excludedSet,
            events: &events
        )

        // Sort deterministically so collision resolution is stable
        candidates.sort { $0.sourceURL.path < $1.sourceURL.path }

        // Resolve relative destination paths cleanly without overwriting colliding names
        var occupiedRelativePaths: Set<String> = []
        var resolvedTargets: [(relativePath: String, candidate: CandidateFile)] = []

        for candidate in candidates {
            let relPath = resolveUniqueRelativePath(
                proposed: candidate.proposedRelativePath,
                sourceName: candidate.sourceName,
                occupied: &occupiedRelativePaths
            )
            resolvedTargets.append((relPath, candidate))
        }

        // Copy / update desired files
        let now = Date()
        for (relPath, item) in resolvedTargets {
            let destFileURL = destRoot.appendingPathComponent(relPath)
            let destDirURL = destFileURL.deletingLastPathComponent()

            let prev = previousManifest[relPath]
            let destExists = fm.fileExists(atPath: destFileURL.path)

            let isUnchanged: Bool
            if destExists, let prev {
                let sameSource = prev.sourcePath == item.sourceURL.path
                let sameSize = prev.sourceSize == item.byteSize
                let sameMod = abs(prev.sourceModifiedTimestamp - item.modifiedAt.timeIntervalSince1970) < 0.001
                isUnchanged = sameSource && sameSize && sameMod
            } else {
                isUnchanged = false
            }

            if isUnchanged, let prev {
                newManifest[relPath] = prev
                syncedRecords.append(SyncedFileRecord(
                    id: relPath,
                    fileName: destFileURL.lastPathComponent,
                    relativePath: relPath,
                    sourceName: item.sourceName,
                    sourcePath: item.sourceURL.path,
                    destinationPath: destFileURL.path,
                    byteSize: item.byteSize,
                    modifiedAt: item.modifiedAt,
                    syncedAt: prev.syncedAt
                ))
                continue
            }

            do {
                try createDirectoryCoordinated(at: destDirURL, fileManager: fm)
                try copyAtomically(from: item.sourceURL, to: destFileURL, modificationDate: item.modifiedAt, fileManager: fm)

                if destExists {
                    updatedCount += 1
                    events.append(SyncLogEntry(kind: .updated, message: "更新: \(relPath)", detail: item.sourceURL.path))
                } else {
                    addedCount += 1
                    events.append(SyncLogEntry(kind: .added, message: "追加: \(relPath)", detail: item.sourceURL.path))
                }

                let manifestEntry = ManifestItem(
                    relativePath: relPath,
                    sourcePath: item.sourceURL.path,
                    sourceSize: item.byteSize,
                    sourceModifiedTimestamp: item.modifiedAt.timeIntervalSince1970,
                    syncedAt: now
                )
                newManifest[relPath] = manifestEntry
                syncedRecords.append(SyncedFileRecord(
                    id: relPath,
                    fileName: destFileURL.lastPathComponent,
                    relativePath: relPath,
                    sourceName: item.sourceName,
                    sourcePath: item.sourceURL.path,
                    destinationPath: destFileURL.path,
                    byteSize: item.byteSize,
                    modifiedAt: item.modifiedAt,
                    syncedAt: now
                ))
            } catch {
                events.append(SyncLogEntry(
                    kind: .error,
                    message: "コピー失敗: \(relPath)",
                    detail: error.localizedDescription
                ))
                if let prev {
                    newManifest[relPath] = prev
                }
            }
        }

        // Clean up files previously placed by MarkPocketSync that were removed from sources
        if settings.deleteRemovedFiles {
            for (oldRelPath, _) in previousManifest where newManifest[oldRelPath] == nil {
                let obsoleteURL = destRoot.appendingPathComponent(oldRelPath)
                if fm.fileExists(atPath: obsoleteURL.path) {
                    do {
                        try removeItemCoordinated(at: obsoleteURL, fileManager: fm)
                        removedCount += 1
                        events.append(SyncLogEntry(kind: .removed, message: "削除: \(oldRelPath)"))
                        pruneEmptyParentDirectories(startingAt: obsoleteURL.deletingLastPathComponent(), stopAt: destRoot, fileManager: fm)
                    } catch {
                        events.append(SyncLogEntry(
                            kind: .error,
                            message: "削除失敗: \(oldRelPath)",
                            detail: error.localizedDescription
                        ))
                    }
                }
            }
        }

        let sortedRecords = syncedRecords.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }

        return SyncExecutionReport(
            manifest: newManifest,
            syncedFiles: sortedRecords,
            events: events,
            addedCount: addedCount,
            updatedCount: updatedCount,
            removedCount: removedCount
        )
    }

    // MARK: - Candidate Discovery

    private struct CandidateFile {
        let sourceName: String
        let sourceURL: URL
        let proposedRelativePath: String
        let byteSize: Int
        let modifiedAt: Date
    }

    private nonisolated func collectDesiredFiles(
        sources: [WatchedSource],
        settings: SyncSettings,
        destRoot: URL,
        excludedDirs: Set<String>,
        events: inout [SyncLogEntry]
    ) -> [CandidateFile] {
        let fm = FileManager.default
        var results: [CandidateFile] = []
        var seenSourcePaths: Set<String> = []
        let destPathPrefix = destRoot.path.hasSuffix("/") ? destRoot.path : destRoot.path + "/"

        for source in sources where source.isEnabled {
            let sourceURL = source.url.standardizedFileURL
            guard fm.fileExists(atPath: sourceURL.path) else {
                events.append(SyncLogEntry(kind: .error, message: "監視元が見つかりません: \(source.name)", detail: source.path))
                continue
            }

            // Never sync from inside the iCloud destination folder itself
            if sourceURL.path == destRoot.path || sourceURL.path.hasPrefix(destPathPrefix) {
                events.append(SyncLogEntry(kind: .info, message: "同期先フォルダ自体は監視対象からスキップされました: \(source.name)"))
                continue
            }

            if !source.isDirectory {
                if let candidate = inspectSingleFile(
                    fileURL: sourceURL,
                    sourceName: source.name,
                    relativePath: sourceURL.lastPathComponent,
                    settings: settings
                ), seenSourcePaths.insert(sourceURL.path).inserted {
                    results.append(candidate)
                }
                continue
            }

            let sourceRootName = sanitizedSegment(source.name)
            if source.includeSubfolders {
                let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
                guard let enumerator = fm.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for case let itemURL as URL in enumerator {
                    let stdItem = itemURL.standardizedFileURL
                    if stdItem.path == destRoot.path || stdItem.path.hasPrefix(destPathPrefix) {
                        enumerator.skipDescendants()
                        continue
                    }

                    let values = try? stdItem.resourceValues(forKeys: Set(keys))
                    if values?.isSymbolicLink == true {
                        if values?.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }

                    if values?.isDirectory == true {
                        if excludedDirs.contains(stdItem.lastPathComponent) || stdItem.lastPathComponent.hasPrefix(".") {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    guard values?.isRegularFile == true else { continue }
                    let subRel = relativePath(of: stdItem, relativeTo: sourceURL)
                    let proposed = settings.preserveFolderStructure
                        ? "\(sourceRootName)/\(subRel)"
                        : stdItem.lastPathComponent

                    if let candidate = makeCandidateIfSupported(
                        fileURL: stdItem,
                        sourceName: source.name,
                        proposedRelativePath: proposed,
                        values: values,
                        settings: settings
                    ), seenSourcePaths.insert(stdItem.path).inserted {
                        results.append(candidate)
                    }
                }
            } else {
                guard let entries = try? fm.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for itemURL in entries {
                    let stdItem = itemURL.standardizedFileURL
                    let values = try? stdItem.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                    guard values?.isRegularFile == true else { continue }
                    let proposed = settings.preserveFolderStructure
                        ? "\(sourceRootName)/\(stdItem.lastPathComponent)"
                        : stdItem.lastPathComponent

                    if let candidate = makeCandidateIfSupported(
                        fileURL: stdItem,
                        sourceName: source.name,
                        proposedRelativePath: proposed,
                        values: values,
                        settings: settings
                    ), seenSourcePaths.insert(stdItem.path).inserted {
                        results.append(candidate)
                    }
                }
            }
        }

        return results
    }

    private nonisolated func inspectSingleFile(
        fileURL: URL,
        sourceName: String,
        relativePath: String,
        settings: SyncSettings
    ) -> CandidateFile? {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
        return makeCandidateIfSupported(
            fileURL: fileURL,
            sourceName: sourceName,
            proposedRelativePath: relativePath,
            values: values,
            settings: settings
        )
    }

    private nonisolated func makeCandidateIfSupported(
        fileURL: URL,
        sourceName: String,
        proposedRelativePath: String,
        values: URLResourceValues?,
        settings: SyncSettings
    ) -> CandidateFile? {
        let ext = fileURL.pathExtension.lowercased()
        let byteSize = values?.fileSize ?? 0
        let modDate = values?.contentModificationDate ?? Date()

        let isMarkdown = Self.markdownExtensions.contains(ext) || (settings.syncPlainTextFiles && ext == "txt")
        let isImage = settings.syncReferencedImages && Self.imageExtensions.contains(ext) && byteSize <= Self.maxImageByteSize

        guard isMarkdown || isImage else { return nil }

        return CandidateFile(
            sourceName: sourceName,
            sourceURL: fileURL,
            proposedRelativePath: proposedRelativePath,
            byteSize: byteSize,
            modifiedAt: modDate
        )
    }

    // MARK: - iCloud Upload Inspection

    nonisolated static func inspectICloudUploadStatus(at destRoot: URL) -> ICloudUploadSummary {
        let now = Date()
        let fm = FileManager.default
        let isUbiquitousContainer = isUbiquitousPath(destRoot)
        guard isUbiquitousContainer, fm.fileExists(atPath: destRoot.path) else {
            return ICloudUploadSummary(
                isUbiquitousContainer: isUbiquitousContainer,
                permissionDenied: false,
                totalCount: 0,
                uploadedCount: 0,
                uploadingCount: 0,
                pendingCount: 0,
                errorCount: 0,
                firstErrorMessage: nil,
                checkedAt: now
            )
        }

        do {
            _ = try fm.contentsOfDirectory(atPath: destRoot.path)
        } catch {
            let nsErr = error as NSError
            let isPerm = (nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoPermissionError)
                || (nsErr.domain == NSPOSIXErrorDomain && (nsErr.code == Int(EPERM) || nsErr.code == Int(EACCES)))
            return ICloudUploadSummary(
                isUbiquitousContainer: true,
                permissionDenied: isPerm,
                totalCount: 0,
                uploadedCount: 0,
                uploadingCount: 0,
                pendingCount: 0,
                errorCount: isPerm ? 0 : 1,
                firstErrorMessage: error.localizedDescription,
                checkedAt: now
            )
        }

        let fileKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let ubiquityKeys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey
        ]

        var total = 0
        var uploaded = 0
        var uploading = 0
        var pending = 0
        var errors = 0
        var firstError: String?

        if let enumerator = fm.enumerator(
            at: destRoot,
            includingPropertiesForKeys: Array(fileKeys),
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let fileInfo = try? fileURL.resourceValues(forKeys: fileKeys)
                guard fileInfo?.isRegularFile == true else { continue }
                let rv = try? fileURL.resourceValues(forKeys: ubiquityKeys)
                total += 1
                if let err = rv?.ubiquitousItemUploadingError {
                    errors += 1
                    if firstError == nil {
                        firstError = err.localizedDescription
                    }
                } else if rv?.ubiquitousItemIsUploading == true {
                    uploading += 1
                } else if rv?.ubiquitousItemIsUploaded == true {
                    uploaded += 1
                } else {
                    pending += 1
                }
            }
        }

        return ICloudUploadSummary(
            isUbiquitousContainer: true,
            permissionDenied: false,
            totalCount: total,
            uploadedCount: uploaded,
            uploadingCount: uploading,
            pendingCount: pending,
            errorCount: errors,
            firstErrorMessage: firstError,
            checkedAt: now
        )
    }

    // MARK: - File Operations

    private nonisolated static func isUbiquitousPath(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    private nonisolated func coordinateWrite(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        operation: (URL) throws -> Void
    ) throws {
        guard Self.isUbiquitousPath(url) else {
            try operation(url)
            return
        }

        var coordinatorError: NSError?
        var operationError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: options,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                try operation(coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinatorError { throw coordinatorError }
    }

    private nonisolated func createDirectoryCoordinated(at url: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try coordinateWrite(at: url, options: .forMerging) { coordinatedURL in
            try fileManager.createDirectory(at: coordinatedURL, withIntermediateDirectories: true)
        }
    }

    private nonisolated func removeItemCoordinated(at url: URL, fileManager: FileManager) throws {
        try coordinateWrite(at: url, options: .forDeleting) { coordinatedURL in
            if fileManager.fileExists(atPath: coordinatedURL.path) {
                try fileManager.removeItem(at: coordinatedURL)
            }
        }
    }

    private nonisolated func copyAtomically(
        from sourceURL: URL,
        to destinationURL: URL,
        modificationDate: Date,
        fileManager: FileManager
    ) throws {
        // Stage outside iCloud Drive so FileProvider does not index or upload temporary artifacts.
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("MarkPocketSyncStaging", isDirectory: true)
        try? fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let tempURL = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
        defer {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: tempURL)
        try? fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: tempURL.path)

        try coordinateWrite(at: destinationURL, options: .forReplacing) { targetURL in
            if fileManager.fileExists(atPath: targetURL.path) {
                do {
                    _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
                } catch {
                    // Fallback when temp and destination reside on separate volumes.
                    try fileManager.removeItem(at: targetURL)
                    try fileManager.copyItem(at: tempURL, to: targetURL)
                    try? fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: targetURL.path)
                }
            } else {
                do {
                    try fileManager.moveItem(at: tempURL, to: targetURL)
                } catch {
                    try fileManager.copyItem(at: tempURL, to: targetURL)
                    try? fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: targetURL.path)
                }
            }
        }
    }

    private nonisolated func pruneEmptyParentDirectories(startingAt dir: URL, stopAt root: URL, fileManager: FileManager) {
        var current = dir.standardizedFileURL
        let rootStd = root.standardizedFileURL
        while current.path != rootStd.path && current.path.hasPrefix(rootStd.path) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path) else { break }
            let nonDSStore = contents.filter { $0 != ".DS_Store" }
            if nonDSStore.isEmpty {
                try? removeItemCoordinated(at: current, fileManager: fileManager)
                current = current.deletingLastPathComponent().standardizedFileURL
            } else {
                break
            }
        }
    }

    private nonisolated func resolveUniqueRelativePath(
        proposed: String,
        sourceName: String,
        occupied: inout Set<String>
    ) -> String {
        if occupied.insert(proposed.lowercased()).inserted {
            return proposed
        }

        let url = URL(fileURLWithPath: proposed)
        let dir = url.deletingLastPathComponent().relativePath
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let safeSource = sanitizedSegment(sourceName)

        let withSourceName = ext.isEmpty ? "\(stem) (\(safeSource))" : "\(stem) (\(safeSource)).\(ext)"
        let candidate1 = (dir == "." || dir.isEmpty) ? withSourceName : "\(dir)/\(withSourceName)"
        if occupied.insert(candidate1.lowercased()).inserted {
            return candidate1
        }

        var counter = 2
        while true {
            let numbered = ext.isEmpty ? "\(stem) (\(safeSource) \(counter))" : "\(stem) (\(safeSource) \(counter)).\(ext)"
            let candidate = (dir == "." || dir.isEmpty) ? numbered : "\(dir)/\(numbered)"
            if occupied.insert(candidate.lowercased()).inserted {
                return candidate
            }
            counter += 1
        }
    }

    private nonisolated func relativePath(of fileURL: URL, relativeTo rootURL: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        if fileURL.path.hasPrefix(rootPath) {
            return String(fileURL.path.dropFirst(rootPath.count))
        }
        return fileURL.lastPathComponent
    }

    private nonisolated func sanitizedSegment(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Folder" : cleaned
    }
}
