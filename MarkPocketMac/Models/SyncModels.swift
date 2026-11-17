import Foundation

struct WatchedSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var isDirectory: Bool
    var includeSubfolders: Bool
    var isEnabled: Bool
    var addedAt: Date

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

enum SyncDestinationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case iCloudDriveMarkPocket
    case customFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iCloudDriveMarkPocket: return "iCloud Drive / MarkPocket"
        case .customFolder: return "カスタムフォルダ"
        }
    }
}

struct SyncSettings: Codable, Equatable, Sendable {
    var destinationMode: SyncDestinationMode = .iCloudDriveMarkPocket
    var customDestinationPath: String = ""
    var preserveFolderStructure: Bool = true
    var deleteRemovedFiles: Bool = true
    var syncReferencedImages: Bool = true
    var syncPlainTextFiles: Bool = false
    var isAutoSyncEnabled: Bool = true
    var excludedDirectoryNames: [String] = SyncSettings.defaultExcludedDirectories

    static let defaultExcludedDirectories: [String] = [
        ".git", ".hg", ".svn",
        ".build", "build", "DerivedData",
        "node_modules", "Pods", ".swiftpm",
        "xcuserdata", ".Trash", "__pycache__",
        ".venv", "venv", ".next", "dist", "target"
    ]

    static var defaultICloudDriveMarkPocketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MarkPocket", isDirectory: true)
    }

    static var isICloudDriveRootAvailable: Bool {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: cloudDocs.path)
    }

    var resolvedDestinationURL: URL {
        if destinationMode == .customFolder, !customDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: customDestinationPath, isDirectory: true)
        }
        return Self.defaultICloudDriveMarkPocketURL
    }
}

struct ManifestItem: Codable, Equatable, Sendable {
    let relativePath: String
    let sourcePath: String
    let sourceSize: Int
    let sourceModifiedTimestamp: TimeInterval
    let syncedAt: Date
}

struct SyncedFileRecord: Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    let relativePath: String
    let sourceName: String
    let sourcePath: String
    let destinationPath: String
    let byteSize: Int
    let modifiedAt: Date
    let syncedAt: Date

    var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
}

enum SyncEventKind: String, Sendable {
    case added
    case updated
    case removed
    case info
    case error

    var badge: String {
        switch self {
        case .added: return "追加"
        case .updated: return "更新"
        case .removed: return "削除"
        case .info: return "情報"
        case .error: return "エラー"
        }
    }
}

struct SyncLogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: SyncEventKind
    let message: String
    let detail: String?

    init(kind: SyncEventKind, message: String, detail: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.message = message
        self.detail = detail
    }
}

struct SyncExecutionReport: Sendable {
    let manifest: [String: ManifestItem]
    let syncedFiles: [SyncedFileRecord]
    let events: [SyncLogEntry]
    let addedCount: Int
    let updatedCount: Int
    let removedCount: Int
}

struct ICloudUploadSummary: Equatable, Sendable {
    let isUbiquitousContainer: Bool
    let permissionDenied: Bool
    let totalCount: Int
    let uploadedCount: Int
    let uploadingCount: Int
    let pendingCount: Int
    let errorCount: Int
    let firstErrorMessage: String?
    let checkedAt: Date

    var isFullyUploaded: Bool {
        isUbiquitousContainer
            && !permissionDenied
            && totalCount > 0
            && uploadedCount == totalCount
            && uploadingCount == 0
            && pendingCount == 0
            && errorCount == 0
    }
}
