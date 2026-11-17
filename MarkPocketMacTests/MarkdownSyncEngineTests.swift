import Foundation
import Testing
@testable import MarkPocketSync

struct MarkdownSyncEngineTests {
    private let engine = MarkdownSyncEngine()

    private func makeTempPair() -> (root: URL, srcA: URL, srcB: URL, dest: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkPocketSyncTests-\(UUID().uuidString)", isDirectory: true)
        let srcA = root.appendingPathComponent("ProjectA", isDirectory: true)
        let srcB = root.appendingPathComponent("ProjectB", isDirectory: true)
        let dest = root.appendingPathComponent("iCloudDest", isDirectory: true)

        try? FileManager.default.createDirectory(at: srcA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: srcB, withIntermediateDirectories: true)
        return (root, srcA, srcB, dest)
    }

    @Test func syncsMarkdownRecursivelyAndSkipsExcludedDirectories() throws {
        let (root, srcA, _, dest) = makeTempPair()
        defer { try? FileManager.default.removeItem(at: root) }

        let subDocs = srcA.appendingPathComponent("docs", isDirectory: true)
        let gitDir = srcA.appendingPathComponent(".git", isDirectory: true)
        let buildDir = srcA.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: subDocs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        try "# Root".write(to: srcA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Guide".write(to: subDocs.appendingPathComponent("guide.markdown"), atomically: true, encoding: .utf8)
        try "ignored".write(to: gitDir.appendingPathComponent("COMMIT_EDITMSG.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: buildDir.appendingPathComponent("temp.md"), atomically: true, encoding: .utf8)
        try "ignored txt".write(to: srcA.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        var settings = SyncSettings()
        settings.destinationMode = .customFolder
        settings.customDestinationPath = dest.path

        let source = WatchedSource(
            id: UUID(),
            name: "ProjectA",
            path: srcA.path,
            isDirectory: true,
            includeSubfolders: true,
            isEnabled: true,
            addedAt: Date()
        )

        let report1 = engine.performSync(sources: [source], settings: settings, previousManifest: [:])
        #expect(report1.addedCount == 2)
        #expect(report1.syncedFiles.count == 2)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("ProjectA/README.md").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("ProjectA/docs/guide.markdown").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("ProjectA/.git/COMMIT_EDITMSG.md").path))

        // Second sync without changes should be a no-op
        let report2 = engine.performSync(sources: [source], settings: settings, previousManifest: report1.manifest)
        #expect(report2.addedCount == 0)
        #expect(report2.updatedCount == 0)
        #expect(report2.removedCount == 0)
        #expect(report2.syncedFiles.count == 2)
    }

    @Test func deletesOnlyManifestTrackedFilesWhenSourceRemoved() throws {
        let (root, srcA, _, dest) = makeTempPair()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let manualFile = dest.appendingPathComponent("ManualOnICloud.md")
        try "# Keep me".write(to: manualFile, atomically: true, encoding: .utf8)

        let trackedSrc = srcA.appendingPathComponent("temp_note.md")
        try "# Temp".write(to: trackedSrc, atomically: true, encoding: .utf8)

        var settings = SyncSettings()
        settings.destinationMode = .customFolder
        settings.customDestinationPath = dest.path
        settings.deleteRemovedFiles = true

        let source = WatchedSource(
            id: UUID(),
            name: "ProjectA",
            path: srcA.path,
            isDirectory: true,
            includeSubfolders: true,
            isEnabled: true,
            addedAt: Date()
        )

        let r1 = engine.performSync(sources: [source], settings: settings, previousManifest: [:])
        #expect(r1.addedCount == 1)
        let syncedPath = dest.appendingPathComponent("ProjectA/temp_note.md")
        #expect(FileManager.default.fileExists(atPath: syncedPath.path))

        try FileManager.default.removeItem(at: trackedSrc)
        let r2 = engine.performSync(sources: [source], settings: settings, previousManifest: r1.manifest)
        #expect(r2.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: syncedPath.path))
        #expect(FileManager.default.fileExists(atPath: manualFile.path))
    }

    @Test func avoidsCollisionsWhenFlatteningSameNamedReadmes() throws {
        let (root, srcA, srcB, dest) = makeTempPair()
        defer { try? FileManager.default.removeItem(at: root) }

        try "# A".write(to: srcA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# B".write(to: srcB.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        var settings = SyncSettings()
        settings.destinationMode = .customFolder
        settings.customDestinationPath = dest.path
        settings.preserveFolderStructure = false

        let s1 = WatchedSource(id: UUID(), name: "ProjectA", path: srcA.path, isDirectory: true, includeSubfolders: true, isEnabled: true, addedAt: Date())
        let s2 = WatchedSource(id: UUID(), name: "ProjectB", path: srcB.path, isDirectory: true, includeSubfolders: true, isEnabled: true, addedAt: Date())

        let report = engine.performSync(sources: [s1, s2], settings: settings, previousManifest: [:])
        #expect(report.syncedFiles.count == 2)
        let paths = Set(report.syncedFiles.map(\.relativePath))
        #expect(paths.count == 2)
    }

    @Test func skipsSourceInsideDestinationToPreventLoop() throws {
        let (root, _, _, dest) = makeTempPair()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "# Inside".write(to: dest.appendingPathComponent("inside.md"), atomically: true, encoding: .utf8)

        var settings = SyncSettings()
        settings.destinationMode = .customFolder
        settings.customDestinationPath = dest.path

        let selfSource = WatchedSource(id: UUID(), name: "iCloudDest", path: dest.path, isDirectory: true, includeSubfolders: true, isEnabled: true, addedAt: Date())
        let report = engine.performSync(sources: [selfSource], settings: settings, previousManifest: [:])
        #expect(report.addedCount == 0)
        #expect(report.syncedFiles.isEmpty)
    }

    @Test func updatesModifiedFileCleanlyWithoutTempArtifactsInDestination() throws {
        let (root, srcA, _, dest) = makeTempPair()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = srcA.appendingPathComponent("note.md")
        try "# v1".write(to: note, atomically: true, encoding: .utf8)

        var settings = SyncSettings()
        settings.destinationMode = .customFolder
        settings.customDestinationPath = dest.path

        let source = WatchedSource(id: UUID(), name: "ProjectA", path: srcA.path, isDirectory: true, includeSubfolders: true, isEnabled: true, addedAt: Date())
        let r1 = engine.performSync(sources: [source], settings: settings, previousManifest: [:])
        #expect(r1.addedCount == 1)

        try "# v2 updated".write(to: note, atomically: true, encoding: .utf8)
        let futureDate = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: note.path)

        let r2 = engine.performSync(sources: [source], settings: settings, previousManifest: r1.manifest)
        #expect(r2.updatedCount == 1)

        let syncedDir = dest.appendingPathComponent("ProjectA", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: syncedDir.path)
        #expect(entries == ["note.md"])
        let syncedContent = try String(contentsOf: syncedDir.appendingPathComponent("note.md"), encoding: .utf8)
        #expect(syncedContent == "# v2 updated")

        let status = MarkdownSyncEngine.inspectICloudUploadStatus(at: dest)
        #expect(!status.isUbiquitousContainer)
        #expect(!status.permissionDenied)
    }
}
