import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class SyncCoordinator {
    var sources: [WatchedSource] = [] {
        didSet {
            saveSources()
            rebuildWatcher()
        }
    }

    var settings: SyncSettings {
        didSet {
            saveSettings()
            rebuildWatcher()
        }
    }

    private(set) var syncedFiles: [SyncedFileRecord] = []
    private(set) var logs: [SyncLogEntry] = []
    private(set) var isSyncing: Bool = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSummaryText: String = "待機中"
    private(set) var iCloudUploadSummary: ICloudUploadSummary?

    private let supportDirectory: URL
    private let sourcesURL: URL
    private let settingsURL: URL
    private let manifestURL: URL

    private var manifest: [String: ManifestItem] = [:]
    private let watcher = FSEventsWatcher()
    private let engine = MarkdownSyncEngine()

    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var uploadPollTask: Task<Void, Never>?
    private var isInspectingUploadStatus = false
    private let uploadStatusQueue = DispatchQueue(label: "com.HR.MarkPocketSync.uploadStatus", qos: .utility)
    private var pendingResyncAfterCurrent = false

    init(supportDirectory: URL? = nil, startBackgroundMonitoring: Bool = true) {
        let baseSupport = supportDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkPocketSync", isDirectory: true)

        self.supportDirectory = baseSupport
        self.sourcesURL = baseSupport.appendingPathComponent("sources.json")
        self.settingsURL = baseSupport.appendingPathComponent("settings.json")
        self.manifestURL = baseSupport.appendingPathComponent("manifest.json")

        try? FileManager.default.createDirectory(at: baseSupport, withIntermediateDirectories: true)

        self.settings = Self.loadSettings(from: settingsURL) ?? SyncSettings()
        self.sources = Self.loadSources(from: sourcesURL) ?? []
        self.manifest = Self.loadManifest(from: manifestURL) ?? [:]

        if startBackgroundMonitoring {
            rebuildWatcher()
            startPeriodicTimer()
            if settings.isAutoSyncEnabled && !sources.isEmpty {
                Task { @MainActor [weak self] in
                    await self?.syncNow()
                }
            } else {
                Task { @MainActor [weak self] in
                    await self?.refreshICloudUploadStatus()
                }
            }
        }
    }

    var isICloudDriveAvailable: Bool {
        SyncSettings.isICloudDriveRootAvailable
    }

    var destinationURL: URL {
        settings.resolvedDestinationURL
    }

    var markdownSyncedCount: Int {
        syncedFiles.filter {
            MarkdownSyncEngine.markdownExtensions.contains($0.destinationURL.pathExtension.lowercased()) ||
            $0.destinationURL.pathExtension.lowercased() == "txt"
        }.count
    }

    // MARK: - Source Management

    func addSourceURLs(_ urls: [URL]) {
        let fm = FileManager.default
        var addedAny = false

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            // Avoid adding destination folder itself
            let destPath = destinationURL.standardizedFileURL.path
            if url.path == destPath || url.path.hasPrefix(destPath + "/") {
                appendLog(SyncLogEntry(kind: .info, message: "同期先の iCloud フォルダ自体は監視対象に追加できません", detail: url.path))
                continue
            }

            if sources.contains(where: { $0.path == url.path }) {
                continue
            }

            let source = WatchedSource(
                id: UUID(),
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                path: url.path,
                isDirectory: isDir.boolValue,
                includeSubfolders: true,
                isEnabled: true,
                addedAt: Date()
            )
            sources.append(source)
            appendLog(SyncLogEntry(kind: .info, message: "監視対象を追加: \(source.name)", detail: source.path))
            addedAny = true
        }

        if addedAny && settings.isAutoSyncEnabled {
            Task { @MainActor [weak self] in
                await self?.syncNow()
            }
        }
    }

    func removeSource(_ source: WatchedSource) {
        sources.removeAll { $0.id == source.id }
        appendLog(SyncLogEntry(kind: .info, message: "監視対象を削除: \(source.name)"))
        if settings.isAutoSyncEnabled {
            Task { @MainActor [weak self] in
                await self?.syncNow()
            }
        }
    }

    func toggleSource(_ source: WatchedSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx].isEnabled.toggle()
        if settings.isAutoSyncEnabled {
            scheduleDebouncedSync(delaySeconds: 0.1)
        }
    }

    func toggleIncludeSubfolders(_ source: WatchedSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx].includeSubfolders.toggle()
        if settings.isAutoSyncEnabled {
            scheduleDebouncedSync(delaySeconds: 0.1)
        }
    }

    // MARK: - Sync Lifecycle

    func syncNow() async {
        if isSyncing {
            pendingResyncAfterCurrent = true
            return
        }

        isSyncing = true
        let snapshotSources = sources
        let snapshotSettings = settings
        let snapshotManifest = manifest
        let syncEngine = engine

        let report = await Task.detached(priority: .utility) {
            syncEngine.performSync(
                sources: snapshotSources,
                settings: snapshotSettings,
                previousManifest: snapshotManifest
            )
        }.value

        manifest = report.manifest
        saveManifest()
        syncedFiles = report.syncedFiles
        lastSyncDate = Date()

        for event in report.events {
            appendLog(event)
        }

        if report.addedCount == 0 && report.updatedCount == 0 && report.removedCount == 0 {
            lastSummaryText = "最新 (\(markdownSyncedCount) 件)"
        } else {
            var parts: [String] = []
            if report.addedCount > 0 { parts.append("+\(report.addedCount)") }
            if report.updatedCount > 0 { parts.append("↻\(report.updatedCount)") }
            if report.removedCount > 0 { parts.append("-\(report.removedCount)") }
            lastSummaryText = "同期完了 (\(parts.joined(separator: " / ")))"
        }

        isSyncing = false

        Task { @MainActor [weak self] in
            await self?.refreshICloudUploadStatus(scheduleFollowUp: true)
        }

        if pendingResyncAfterCurrent {
            pendingResyncAfterCurrent = false
            await syncNow()
        }
    }

    func refreshICloudUploadStatus(scheduleFollowUp: Bool = false) async {
        guard let summary = await runUploadInspectionIfIdle() else { return }
        iCloudUploadSummary = summary

        guard scheduleFollowUp else { return }
        uploadPollTask?.cancel()
        guard summary.isUbiquitousContainer,
              !summary.permissionDenied,
              summary.totalCount > 0,
              !summary.isFullyUploaded else {
            return
        }

        uploadPollTask = Task { @MainActor [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                guard let updated = await self.runUploadInspectionIfIdle() else { continue }
                self.iCloudUploadSummary = updated
                if updated.isFullyUploaded || !updated.isUbiquitousContainer || updated.permissionDenied {
                    break
                }
            }
        }
    }

    private func runUploadInspectionIfIdle() async -> ICloudUploadSummary? {
        guard !isInspectingUploadStatus else { return nil }
        isInspectingUploadStatus = true
        defer { isInspectingUploadStatus = false }

        let dest = destinationURL
        let queue = uploadStatusQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: MarkdownSyncEngine.inspectICloudUploadStatus(at: dest))
            }
        }
    }

    func scheduleDebouncedSync(delaySeconds: Double = 0.45) {
        guard settings.isAutoSyncEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func rebuildWatcher() {
        watcher.stop()
        guard settings.isAutoSyncEnabled else { return }

        let activePaths = sources.filter(\.isEnabled).map(\.path)
        guard !activePaths.isEmpty else { return }

        let excluded = settings.excludedDirectoryNames
        watcher.start(paths: activePaths) { [weak self] changedPaths in
            // Skip events originating purely inside excluded build/VCS folders
            let hasRelevantChange = changedPaths.isEmpty || changedPaths.contains { rawPath in
                let components = Set(rawPath.split(separator: "/").map(String.init))
                return components.isDisjoint(with: excluded)
            }
            guard hasRelevantChange else { return }

            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSync()
            }
        }
    }

    private func startPeriodicTimer() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { break }
                guard let self, self.settings.isAutoSyncEnabled, !self.sources.isEmpty else { continue }
                await self.syncNow()
            }
        }
    }

    // MARK: - Finder & Pickers

    func openDestinationInFinder() {
        let dest = destinationURL
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func pickFoldersAndFiles() {
        let panel = NSOpenPanel()
        panel.title = "自動同期するフォルダ・Markdown ファイルを選択"
        panel.message = "選択したフォルダ内の .md ファイルが自動的に iCloud へ同期されます。"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        var types: [UTType] = [.folder, .plainText]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK {
            addSourceURLs(panel.urls)
        }
    }

    func pickCustomDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "同期先のフォルダを選択"
        panel.message = "通常は iCloud Drive 内のフォルダを指定してください。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            settings.destinationMode = .customFolder
            settings.customDestinationPath = url.path
            appendLog(SyncLogEntry(kind: .info, message: "同期先を変更: \(url.lastPathComponent)", detail: url.path))
            Task { @MainActor [weak self] in
                await self?.syncNow()
            }
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Persistence

    private func appendLog(_ entry: SyncLogEntry) {
        logs.insert(entry, at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: sourcesURL, options: .atomic)
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private static func loadSources(from url: URL) -> [WatchedSource]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WatchedSource].self, from: data)
    }

    private static func loadSettings(from url: URL) -> SyncSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncSettings.self, from: data)
    }

    private static func loadManifest(from url: URL) -> [String: ManifestItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: ManifestItem].self, from: data)
    }
}
