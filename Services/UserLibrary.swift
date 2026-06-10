import Foundation
import SwiftUI

// MARK: - 用户库管理

actor UserLibrary {
    static let shared = UserLibrary()

    private let fileManager = FileManager.default
    private let libraryDirectory: URL

    // 文件路径
    private var wallpaperFavoritesPath: URL { libraryDirectory.appendingPathComponent("wallpaper_favorites.json") }
    private var videoFavoritesPath: URL { libraryDirectory.appendingPathComponent("video_favorites.json") }
    private var downloadsPath: URL { libraryDirectory.appendingPathComponent("downloads.json") }

    // 内存缓存
    private var wallpaperFavorites: [UniversalContentItem] = []
    private var videoFavorites: [UniversalContentItem] = []
    private var downloads: [DownloadRecord] = []

    init() {
        // ⚠️ 不在 init 中做任何 I/O（FileManager/UserDefaults），避免 _CFXPreferences 递归栈溢出
        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            self.libraryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("WaifuX", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
            return
        }
        self.libraryDirectory = supportDir
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }
    
    /// 延迟初始化：创建目录并加载数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        try? fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        Task {
            await loadAllData()
        }
    }

    // MARK: - 加载数据

    private func loadAllData() async {
        let loadedWallpaperFavorites = loadUniversalItemsExcludingLegacyAnime(from: wallpaperFavoritesPath)
        let loadedVideoFavorites = loadUniversalItemsExcludingLegacyAnime(from: videoFavoritesPath)
        let loadedDownloads = loadDownloadsExcludingLegacyAnime(from: downloadsPath)

        wallpaperFavorites = loadedWallpaperFavorites.items
        videoFavorites = loadedVideoFavorites.items
        downloads = loadedDownloads.items

        if loadedWallpaperFavorites.removedLegacyAnime {
            try? saveItems(wallpaperFavorites, to: wallpaperFavoritesPath)
        }
        if loadedVideoFavorites.removedLegacyAnime {
            try? saveItems(videoFavorites, to: videoFavoritesPath)
        }
        if loadedDownloads.removedLegacyAnime {
            try? saveItems(downloads, to: downloadsPath)
        }
    }

    private func loadItems<T: Codable>(from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func loadData<T: Codable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveItems<T: Codable>(_ items: [T], to url: URL) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: url)
    }

    private func loadUniversalItemsExcludingLegacyAnime(from url: URL) -> (items: [UniversalContentItem], removedLegacyAnime: Bool) {
        loadArrayExcludingLegacyAnimeContentType(from: url)
    }

    private func loadDownloadsExcludingLegacyAnime(from url: URL) -> (items: [DownloadRecord], removedLegacyAnime: Bool) {
        loadArrayExcludingLegacyAnimeContentType(from: url)
    }

    private func loadArrayExcludingLegacyAnimeContentType<T: Codable>(from url: URL) -> (items: [T], removedLegacyAnime: Bool) {
        guard let data = try? Data(contentsOf: url) else {
            return ([], false)
        }

        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ((try? JSONDecoder().decode([T].self, from: data)) ?? [], false)
        }

        let filtered = objects.filter { object in
            guard let rawType = object["contentType"] as? String else { return true }
            return rawType.caseInsensitiveCompare("anime") != .orderedSame
        }

        guard filtered.count != objects.count else {
            return ((try? JSONDecoder().decode([T].self, from: data)) ?? [], false)
        }

        guard let filteredData = try? JSONSerialization.data(withJSONObject: filtered) else {
            return ([], true)
        }
        return ((try? JSONDecoder().decode([T].self, from: filteredData)) ?? [], true)
    }

    // MARK: - 收藏管理

    func addToFavorites(_ item: UniversalContentItem) async throws {
        switch item.contentType {
        case .wallpaper:
            guard !wallpaperFavorites.contains(where: { $0.id == item.id }) else { return }
            wallpaperFavorites.append(item)
            try saveItems(wallpaperFavorites, to: wallpaperFavoritesPath)

        case .video:
            guard !videoFavorites.contains(where: { $0.id == item.id }) else { return }
            videoFavorites.append(item)
            try saveItems(videoFavorites, to: videoFavoritesPath)
        }
    }

    func removeFromFavorites(id: String, contentType: ContentType) async throws {
        switch contentType {
        case .wallpaper:
            wallpaperFavorites.removeAll { $0.id == id }
            try saveItems(wallpaperFavorites, to: wallpaperFavoritesPath)

        case .video:
            videoFavorites.removeAll { $0.id == id }
            try saveItems(videoFavorites, to: videoFavoritesPath)
        }
    }

    func getFavorites(for contentType: ContentType) async -> [UniversalContentItem] {
        switch contentType {
        case .wallpaper: return wallpaperFavorites
        case .video: return videoFavorites
        }
    }

    func isFavorite(id: String, contentType: ContentType) async -> Bool {
        switch contentType {
        case .wallpaper: return wallpaperFavorites.contains(where: { $0.id == id })
        case .video: return videoFavorites.contains(where: { $0.id == id })
        }
    }

    func toggleFavorite(_ item: UniversalContentItem) async throws -> Bool {
        let isFav = await isFavorite(id: item.id, contentType: item.contentType)
        if isFav {
            try await removeFromFavorites(id: item.id, contentType: item.contentType)
            return false
        } else {
            try await addToFavorites(item)
            return true
        }
    }

    // MARK: - 下载记录

    func addDownloadRecord(_ record: DownloadRecord) async throws {
        downloads.append(record)
        try saveItems(downloads, to: downloadsPath)
    }

    func removeDownloadRecord(id: String) async throws {
        downloads.removeAll { $0.id == id }
        try saveItems(downloads, to: downloadsPath)
    }

    func getDownloads(for contentType: ContentType?) async -> [DownloadRecord] {
        if let type = contentType {
            return downloads.filter { $0.contentType == type }
        }
        return downloads
    }

    func bulkUpdatePaths(oldPrefix: String, newPrefix: String) async {
        var changed = false
        for index in downloads.indices {
            if let localPath = downloads[index].localPath, localPath.hasPrefix(oldPrefix) {
                downloads[index].localPath = newPrefix + String(localPath.dropFirst(oldPrefix.count))
                changed = true
            }
        }
        if changed {
            try? saveItems(downloads, to: downloadsPath)
            print("[UserLibrary] Bulk updated download paths from \(oldPrefix) to \(newPrefix)")
        }
    }

    // MARK: - 获取所有内容

    func getAllItems(for contentType: ContentType) async -> LibraryItems {
        let favorites = await getFavorites(for: contentType)
        let downloaded = await getDownloads(for: contentType)

        return LibraryItems(
            favorites: favorites,
            downloads: downloaded
        )
    }

    // MARK: - 统计

    func getStats() async -> LibraryStats {
        return LibraryStats(
            wallpaperCount: wallpaperFavorites.count,
            videoCount: videoFavorites.count,
            totalDownloads: downloads.count
        )
    }
}

// MARK: - 下载记录

struct DownloadRecord: Identifiable, Codable {
    let id: String
    let contentType: ContentType
    let itemId: String
    let title: String
    let thumbnailURL: String
    let downloadURL: String
    var localPath: String?
    let fileSize: String?
    let downloadedAt: Date
    let status: DownloadRecordStatus
}

enum DownloadRecordStatus: String, Codable {
    case pending, downloading, completed, failed
}

// MARK: - 库项目

struct LibraryItems {
    let favorites: [UniversalContentItem]
    let downloads: [DownloadRecord]
}

// MARK: - 库统计

struct LibraryStats {
    let wallpaperCount: Int
    let videoCount: Int
    let totalDownloads: Int

    var totalItems: Int {
        wallpaperCount + videoCount
    }
}
