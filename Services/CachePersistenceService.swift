import Foundation
import Cache

// MARK: - 基于 hyperoslo/Cache 的持久化服务

/// 替代 UserDefaults 存储大规模收藏/下载记录。
///
/// 存储布局 (所有 key 经过 MD5 哈希后落盘，由 Cache 库自动处理)：
/// ```
/// 个体记录:  {category}/{id}  → Data (单条 JSON)
/// 索引:      index/{category} → Data (JSON [String])
/// ```
///
/// 分类命名空间：
/// - `wallpaper/fav` — 壁纸收藏
/// - `wallpaper/dl`  — 壁纸下载
/// - `media/fav`     — 媒体收藏
/// - `media/dl`      — 媒体下载
/// - `anime/fav`     — 动漫收藏
@MainActor
final class CachePersistenceService {
    static let shared = CachePersistenceService()

    private let storage: Storage<String, Data>

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.waifux.app/CachePersistence")

        let diskConfig = DiskConfig(
            name: "Records",
            expiry: .never,
            directory: appSupport
        )
        let memoryConfig = MemoryConfig(expiry: .never, countLimit: 0, totalCostLimit: 0)

        do {
            storage = try Storage<String, Data>(
                diskConfig: diskConfig,
                memoryConfig: memoryConfig,
                fileManager: .default,
                transformer: TransformerFactory.forData()
            )
        } catch {
            fatalError("[CachePersistenceService] Failed to initialize: \(error)")
        }
    }

    // MARK: - 个体记录

    /// 保存单条记录
    @discardableResult
    func save<T: Encodable>(_ value: T, key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            try storage.setObject(data, forKey: key)
            return true
        } catch {
            print("[CachePersistenceService] Failed to save key=\(key): \(error)")
            return false
        }
    }

    /// 读取单条记录
    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        do {
            let data = try storage.object(forKey: key)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }

    /// 删除单条记录
    @discardableResult
    func delete(key: String) -> Bool {
        do {
            try storage.removeObject(forKey: key)
            return true
        } catch {
            print("[CachePersistenceService] Failed to delete key=\(key): \(error)")
            return false
        }
    }

    /// 检查记录是否存在
    func exists(key: String) -> Bool {
        (try? storage.existsObject(forKey: key)) ?? false
    }

    // MARK: - 索引

    /// 保存分类下所有活跃 ID 索引
    @discardableResult
    func saveIndex(_ ids: [String], key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(ids)
            try storage.setObject(data, forKey: key)
            return true
        } catch {
            print("[CachePersistenceService] Failed to save index key=\(key): \(error)")
            return false
        }
    }

    /// 读取分类下所有活跃 ID 索引
    func loadIndex(key: String) -> [String] {
        do {
            let data = try storage.object(forKey: key)
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            return []
        }
    }

    // MARK: - 批量操作

    /// 加载分类下所有记录（类型由返回类型推断）
    func loadAll<T: Decodable>(category: String) -> [T] {
        let ids = loadIndex(key: "index/\(category)")
        var results: [T] = []
        for id in ids {
            if let record: T = load(T.self, key: "\(category)/\(id)") {
                results.append(record)
            }
        }
        return results
    }

    /// 全量覆盖保存（用于迁移/批量重建）
    @discardableResult
    func saveAll<T: Encodable & Identifiable>(
        _ records: [T],
        category: String,
        activeFilter: ((T) -> Bool)? = nil
    ) -> Bool where T.ID == String {
        let filtered = activeFilter.map { records.filter($0) } ?? records
        for record in filtered {
            guard save(record, key: "\(category)/\(record.id)") else {
                return false
            }
        }
        let ids = filtered.map(\.id)
        return saveIndex(ids, key: "index/\(category)")
    }
}
