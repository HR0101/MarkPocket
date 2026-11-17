import Foundation

enum DocumentSourceKind: String, Codable, Hashable, Sendable {
    case localFile
    case externalBookmark
    case watchedFolder
    case sample

    var badgeLabel: String {
        switch self {
        case .localFile: return "このiPhone内"
        case .externalBookmark: return "外部ファイル"
        case .watchedFolder: return "自動同期"
        case .sample: return "ガイド"
        }
    }

    var badgeSymbol: String {
        switch self {
        case .localFile: return "folder"
        case .externalBookmark: return "link"
        case .watchedFolder: return "icloud.fill"
        case .sample: return "sparkles"
        }
    }
}

enum LibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case lastOpened
    case modifiedDate
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastOpened: return "最近開いた順"
        case .modifiedDate: return "更新日時順"
        case .title: return "名前順"
        }
    }
}

struct PocketDocument: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var fileName: String
    /// Relative path inside the app's `Documents` directory for local/sample files.
    var localRelativePath: String?
    /// Security-scoped bookmark data for files opened from Files / iCloud Drive / external providers.
    var bookmarkData: Data?
    /// Parent watched folder ID when auto-synced from a linked folder (e.g. iCloud Drive / MarkPocket).
    var watchedFolderID: UUID?
    /// Relative path inside the parent watched folder.
    var watchedRelativePath: String?
    var sourceKind: DocumentSourceKind
    var isPinned: Bool
    var lastOpenedAt: Date
    var modifiedAt: Date
    var previewText: String
    var byteSize: Int
    var wordCount: Int
    var estimatedReadingMinutes: Int
    var lastScrollBlockID: String?

    var formattedByteSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
}

struct WatchedFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var bookmarkData: Data
    var addedAt: Date
}

struct FolderEntry: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let modifiedAt: Date?
    let fileSize: Int?
}
