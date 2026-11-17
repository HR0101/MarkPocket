import Foundation
import Testing
@testable import MarkPocket

@MainActor
struct DocumentLibraryTests {
    private func makeIsolatedStore() -> (DocumentLibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkPocketTests-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let meta = root.appendingPathComponent("Metadata", isDirectory: true)
        let store = DocumentLibraryStore(
            documentsDirectory: docs,
            metadataDirectory: meta,
            seedSamplesIfNeeded: false
        )
        return (store, root)
    }

    @Test func createsReadsPinsAndDeletesNote() {
        let (store, root) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let created = store.createNewNote(
            title: "Meeting Notes",
            markdownContent: "# 議事録\n\n明日のリリース予定を確認する。",
            openImmediately: false
        )
        #expect(created != nil)
        #expect(store.documents.count == 1)
        #expect(created?.title == "議事録")
        #expect(created?.previewText.contains("明日のリリース予定") == true)

        if let doc = created {
            store.togglePin(doc)
            #expect(store.documents.first?.isPinned == true)
            store.deleteDocument(doc)
            #expect(store.documents.isEmpty)
        }
    }

    @Test func togglesTaskCheckboxOnExactSourceLineWithFrontmatter() {
        let (store, root) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let content = """
        ---
        title: Checklist
        ---

        - [ ] First item
        - [x] Second item
        """
        guard let doc = store.createNewNote(title: "Checklist", markdownContent: content, openImmediately: false) else {
            Issue.record("Failed to create checklist note")
            return
        }

        let parsed = MarkdownParser().parse(content)
        guard case .list(_, _, _, let items) = parsed.blocks.first,
              let firstLine = items[0].sourceLine else {
            Issue.record("Expected parsed task item")
            return
        }

        let updated = store.toggleTaskCheckbox(in: doc, sourceLine: firstLine)
        #expect(updated != nil)
        #expect(updated?.contains("- [x] First item") == true)
        #expect(updated?.contains("- [x] Second item") == true)
    }

    @Test func decodesShiftJISMarkdownFilesCleanly() throws {
        let (store, root) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let sjisText = "# シフトJISテスト\n\n日本語の本文です。"
        let sjisData = sjisText.data(using: .shiftJIS)!
        let fileURL = store.documentsDirectory.appendingPathComponent("sjis_note.md")
        try sjisData.write(to: fileURL)

        store.rescanLocalDocuments()
        #expect(store.documents.count == 1)
        #expect(store.documents.first?.title == "シフトJISテスト")
        let loaded = store.loadMarkdownContent(for: store.documents[0])
        #expect(loaded == sjisText)
    }

    @Test func autoSyncsWatchedFolderSubdirectoriesIntoLibrary() async throws {
        let (store, root) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let watched = root.appendingPathComponent("iCloudMirror", isDirectory: true)
        let sub = watched.appendingPathComponent("ProjectX", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let syncedFile = sub.appendingPathComponent("spec.md")
        try "# Project X Spec\n\n同期された仕様書です。".write(to: syncedFile, atomically: true, encoding: .utf8)
        let stubFile = sub.appendingPathComponent(".cloud_only.md.icloud")
        try Data().write(to: stubFile)

        store.addWatchedFolder(from: watched, syncImmediately: false)
        await store.syncWatchedFoldersAsync()

        #expect(store.watchedFolders.count == 1)
        #expect(store.documents.count == 2)

        guard let doc = store.documents.first(where: { $0.fileName == "spec.md" }) else {
            Issue.record("Expected spec.md in watched documents")
            return
        }
        #expect(doc.sourceKind == .watchedFolder)
        #expect(doc.title == "Project X Spec")
        #expect(doc.watchedRelativePath == "ProjectX/spec.md")

        let loaded = await store.loadMarkdownContentAsync(for: doc)
        switch loaded {
        case .success(let text):
            #expect(text.contains("同期された仕様書です。"))
        case .failure(let error):
            Issue.record("Failed async load: \(error)")
        }

        let cloudStub = store.documents.first(where: { $0.fileName == "cloud_only.md" })
        #expect(cloudStub?.watchedRelativePath == "ProjectX/cloud_only.md")
    }

    @Test func renamesAndBatchDeletesLocalAndWatchedDocuments() async throws {
        let (store, root) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        guard let localA = store.createNewNote(title: "Alpha", markdownContent: "body a", openImmediately: false),
              let localB = store.createNewNote(title: "Beta", markdownContent: "body b", openImmediately: false) else {
            Issue.record("Failed to create local notes")
            return
        }

        let renamedLocal = store.renameDocument(localA, to: "Alpha_Renamed")
        #expect(renamedLocal?.fileName == "Alpha_Renamed.md")
        #expect(FileManager.default.fileExists(atPath: store.documentsDirectory.appendingPathComponent("Alpha_Renamed.md").path))
        #expect(!FileManager.default.fileExists(atPath: store.documentsDirectory.appendingPathComponent("Alpha.md").path))

        let watched = root.appendingPathComponent("Watched", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        store.addWatchedFolder(from: watched, syncImmediately: false)
        guard let folder = store.watchedFolders.first else {
            Issue.record("Expected watched folder")
            return
        }

        guard let createdInFolder = store.createNote(in: folder, subdirectory: nil, title: "CloudNote", markdownContent: "# Cloud", openImmediately: false) else {
            Issue.record("Failed to create note inside watched folder")
            return
        }
        #expect(FileManager.default.fileExists(atPath: watched.appendingPathComponent("CloudNote.md").path))

        let renamedWatched = store.renameDocument(createdInFolder, to: "CloudNoteV2.md")
        #expect(renamedWatched?.fileName == "CloudNoteV2.md")
        #expect(FileManager.default.fileExists(atPath: watched.appendingPathComponent("CloudNoteV2.md").path))

        store.setPinned(true, for: [localA.id, localB.id])
        #expect(store.documents.filter(\.isPinned).count == 2)

        let deletedCount = store.deleteDocuments(ids: [localA.id, createdInFolder.id])
        #expect(deletedCount == 2)
        #expect(store.documents.count == 1)
        #expect(store.documents.first?.id == localB.id)
        // Local file is deleted from app sandbox, while watched/iCloud file stays on disk and hidden in app
        #expect(!FileManager.default.fileExists(atPath: store.documentsDirectory.appendingPathComponent("Alpha_Renamed.md").path))
        #expect(FileManager.default.fileExists(atPath: watched.appendingPathComponent("CloudNoteV2.md").path))

        // Rescanning must keep app-deleted watched file hidden rather than re-adding it
        store.syncWatchedFolders()
        #expect(store.documents.count == 1)

        // Restoring excluded items makes it visible again
        store.restoreExcludedItems(for: folder, syncImmediately: false)
        store.syncWatchedFolders()
        #expect(store.documents.count == 2)
    }

    @Test func renamesAndDeletesWatchedFolderEntriesInBrowser() throws {
        let (store, root) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let watched = root.appendingPathComponent("BrowserRoot", isDirectory: true)
        let sub = watched.appendingPathComponent("SubDir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let noteURL = sub.appendingPathComponent("memo.md")
        try "# Sub Memo".write(to: noteURL, atomically: true, encoding: .utf8)

        store.addWatchedFolder(from: watched, syncImmediately: false)
        store.syncWatchedFolders()
        guard let folder = store.watchedFolders.first else {
            Issue.record("Missing watched folder")
            return
        }

        let topEntries = store.listContents(of: folder, subdirectory: nil)
        guard let subEntry = topEntries.first(where: { $0.isDirectory && $0.name == "SubDir" }) else {
            Issue.record("Missing SubDir entry")
            return
        }

        #expect(store.renameFolderEntry(subEntry, in: folder, to: "SubRenamed"))
        #expect(store.documents.first?.watchedRelativePath == "SubRenamed/memo.md")

        let renamedEntries = store.listContents(of: folder, subdirectory: nil)
        guard let renamedSubEntry = renamedEntries.first(where: { $0.isDirectory && $0.name == "SubRenamed" }) else {
            Issue.record("Missing SubRenamed entry")
            return
        }

        #expect(store.deleteFolderEntry(renamedSubEntry, in: folder))
        #expect(store.documents.isEmpty)
        #expect(store.listContents(of: folder, subdirectory: nil).isEmpty)
        // Actual directory & file remain intact on disk / iCloud Drive
        #expect(FileManager.default.fileExists(atPath: watched.appendingPathComponent("SubRenamed/memo.md").path))

        store.syncWatchedFolders()
        #expect(store.documents.isEmpty)
    }
}
