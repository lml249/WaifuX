import AppKit
import Combine
import Foundation

enum DesktopSlotBindingState: String, Codable, CaseIterable {
    case unbound
    case bound
    case lostBinding
    case displayMissing
}

enum DesktopSlotPendingKind: String, Codable {
    case pendingUserSet
    case pendingSchedulerSet
}

enum DesktopSlotRuntimeState: String, Codable {
    case inactive
    case activeStatic
    case activeDynamic
}

struct DesktopSlotImageOptions: Codable, Equatable {
    var imageScalingRawValue: Int?
    var allowClipping: Bool?

    static let fill = DesktopSlotImageOptions(
        imageScalingRawValue: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
        allowClipping: true
    )

    init(imageScalingRawValue: Int? = nil, allowClipping: Bool? = nil) {
        self.imageScalingRawValue = imageScalingRawValue
        self.allowClipping = allowClipping
    }

    init(workspaceOptions: [NSWorkspace.DesktopImageOptionKey: Any]) {
        if let number = workspaceOptions[.imageScaling] as? NSNumber {
            imageScalingRawValue = number.intValue
        } else if let value = workspaceOptions[.imageScaling] as? Int {
            imageScalingRawValue = value
        } else {
            imageScalingRawValue = nil
        }

        if let number = workspaceOptions[.allowClipping] as? NSNumber {
            allowClipping = number.boolValue
        } else if let value = workspaceOptions[.allowClipping] as? Bool {
            allowClipping = value
        } else {
            allowClipping = nil
        }
    }

    var workspaceOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let imageScalingRawValue {
            options[.imageScaling] = NSNumber(value: imageScalingRawValue)
        }
        if let allowClipping {
            options[.allowClipping] = NSNumber(value: allowClipping)
        }
        return options
    }
}

struct DesktopSlotPendingAction: Codable, Equatable, Identifiable {
    var id: String
    var kind: DesktopSlotPendingKind
    var assetPath: String
    var sourcePath: String?
    var options: DesktopSlotImageOptions
    var createdAt: Date
}

struct DesktopSlotScreenEntry: Codable, Equatable, Identifiable {
    var id: String { screenID }
    var screenID: String
    var screenFingerprint: String
    var bindingState: DesktopSlotBindingState
    var runtimeState: DesktopSlotRuntimeState
    var currentTokenPath: String?
    var historyTokenPaths: [String]
    var pendingAction: DesktopSlotPendingAction?
    var lastSourcePath: String?
    var updatedAt: Date
    var lastBoundAt: Date?

    static func empty(for screen: NSScreen) -> DesktopSlotScreenEntry {
        DesktopSlotScreenEntry(
            screenID: screen.wallpaperScreenIdentifier,
            screenFingerprint: screen.wallpaperScreenFingerprint,
            bindingState: .unbound,
            runtimeState: .inactive,
            currentTokenPath: nil,
            historyTokenPaths: [],
            pendingAction: nil,
            lastSourcePath: nil,
            updatedAt: Date(),
            lastBoundAt: nil
        )
    }
}

struct DesktopWallpaperSlot: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var order: Int
    var screenEntries: [String: DesktopSlotScreenEntry]
    var createdAt: Date
    var updatedAt: Date
}

struct DesktopSlotDocument: Codable, Equatable {
    var schemaVersion: Int
    var slots: [DesktopWallpaperSlot]
    var updatedAt: Date
}

struct DesktopSlotTokenMatch: Equatable {
    let slotID: String
    let screenID: String
    let isCurrent: Bool
}

enum DesktopSlotStoreError: LocalizedError {
    case missingSlot
    case missingPendingAction
    case unsupportedRemoteURL(URL)
    case unreadableSource(URL)
    case cannotLocateApplicationSupport
    case cannotBindWithoutReadableImage
    case cannotIdentifyCurrentSpace
    case missingSavedToken

    var errorDescription: String? {
        switch self {
        case .missingSlot:
            return "找不到桌面槽位"
        case .missingPendingAction:
            return "该桌面槽位没有待应用壁纸"
        case .unsupportedRemoteURL(let url):
            return "暂不支持直接绑定远程地址：\(url.absoluteString)"
        case .unreadableSource(let url):
            return "无法读取壁纸文件：\(url.path)"
        case .cannotLocateApplicationSupport:
            return "无法定位 Application Support 目录"
        case .cannotBindWithoutReadableImage:
            return "当前系统壁纸不可读取，请选择一张图片后绑定"
        case .cannotIdentifyCurrentSpace:
            return "当前桌面还没有绑定到 WaifuX 槽位，请先在桌面槽位里绑定当前桌面"
        case .missingSavedToken:
            return "该槽位还没有已保存的壁纸"
        }
    }
}

@MainActor
final class DesktopSlotStore: ObservableObject {
    static let shared = DesktopSlotStore()

    static let schemaVersion = 1
    static let maxHistoryTokensPerEntry = 5
    static let tokenGraceInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maxAssetDirectoryBytes: Int64 = 1_000_000_000

    @Published private(set) var document: DesktopSlotDocument
    @Published private(set) var lastErrorMessage: String?

    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    private init() {
        jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        document = Self.defaultDocument()
    }

    var slots: [DesktopWallpaperSlot] {
        document.slots.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.order < rhs.order
        }
    }

    var defaultSlotID: String {
        if let first = slots.first {
            return first.id
        }
        return ""
    }

    var rootDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (appSupport ?? fileManager.temporaryDirectory)
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("DesktopSlots", isDirectory: true)
    }

    var tokenRootDirectory: URL {
        rootDirectory.appendingPathComponent("Tokens", isDirectory: true)
    }

    var pendingRootDirectory: URL {
        rootDirectory.appendingPathComponent("Pending", isDirectory: true)
    }

    private var documentURL: URL {
        rootDirectory.appendingPathComponent("desktop-slots.json")
    }

    func restoreSavedData() {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: tokenRootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: pendingRootDirectory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: documentURL.path) {
                let data = try Data(contentsOf: documentURL)
                var loaded = try jsonDecoder.decode(DesktopSlotDocument.self, from: data)
                normalizeDocument(&loaded)
                document = loaded
            } else {
                document = Self.defaultDocument()
                try save()
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            print("[DesktopSlotStore] restore failed: \(error)")
        }
    }

    func save() throws {
        var snapshot = document
        normalizeDocument(&snapshot)
        snapshot.updatedAt = Date()
        let data = try jsonEncoder.encode(snapshot)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let tempURL = rootDirectory.appendingPathComponent(".desktop-slots-\(UUID().uuidString).tmp")
        try data.write(to: tempURL)

        if fileManager.fileExists(atPath: documentURL.path) {
            _ = try fileManager.replaceItemAt(documentURL, withItemAt: tempURL, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: tempURL, to: documentURL)
        }

        document = snapshot
        lastErrorMessage = nil
        cleanupUnreferencedAssets()
    }

    @discardableResult
    func createSlot(named name: String? = nil) throws -> DesktopWallpaperSlot {
        let nextOrder = (document.slots.map(\.order).max() ?? -1) + 1
        let slot = DesktopWallpaperSlot(
            id: UUID().uuidString,
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : createDefaultSlotName(index: nextOrder + 1),
            order: nextOrder,
            screenEntries: [:],
            createdAt: Date(),
            updatedAt: Date()
        )
        document.slots.append(slot)
        try save()
        return slot
    }

    func renameSlot(_ slotID: String, name: String) throws {
        guard let index = document.slots.firstIndex(where: { $0.id == slotID }) else {
            throw DesktopSlotStoreError.missingSlot
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.slots[index].name = trimmed
        document.slots[index].updatedAt = Date()
        try save()
    }

    func deleteSlot(_ slotID: String) throws {
        guard document.slots.count > 1 else { return }
        document.slots.removeAll { $0.id == slotID }
        normalizeOrders()
        try save()
    }

    func moveSlot(_ slotID: String, direction: Int) throws {
        var ordered = slots
        guard let currentIndex = ordered.firstIndex(where: { $0.id == slotID }) else {
            throw DesktopSlotStoreError.missingSlot
        }
        let nextIndex = currentIndex + direction
        guard ordered.indices.contains(nextIndex) else { return }
        ordered.swapAt(currentIndex, nextIndex)
        for index in ordered.indices {
            ordered[index].order = index
            ordered[index].updatedAt = Date()
        }
        document.slots = ordered
        try save()
    }

    func slot(id slotID: String) -> DesktopWallpaperSlot? {
        document.slots.first { $0.id == slotID }
    }

    func entry(slotID: String, screenID: String) -> DesktopSlotScreenEntry? {
        slot(id: slotID)?.screenEntries[screenID]
    }

    func entry(slotID: String, for screen: NSScreen) -> DesktopSlotScreenEntry {
        entry(slotID: slotID, screenID: screen.wallpaperScreenIdentifier) ?? .empty(for: screen)
    }

    func ensureEntry(slotID: String, for screen: NSScreen) throws -> DesktopSlotScreenEntry {
        guard let slotIndex = document.slots.firstIndex(where: { $0.id == slotID }) else {
            throw DesktopSlotStoreError.missingSlot
        }
        let screenID = screen.wallpaperScreenIdentifier
        if let entry = document.slots[slotIndex].screenEntries[screenID] {
            return entry
        }
        let entry = DesktopSlotScreenEntry.empty(for: screen)
        document.slots[slotIndex].screenEntries[screenID] = entry
        document.slots[slotIndex].updatedAt = Date()
        return entry
    }

    func markDisplayMissing(forMissingScreenIDs missingScreenIDs: Set<String>) throws {
        guard !missingScreenIDs.isEmpty else { return }
        var changed = false
        for slotIndex in document.slots.indices {
            for screenID in missingScreenIDs {
                guard var entry = document.slots[slotIndex].screenEntries[screenID],
                      entry.bindingState != .displayMissing else { continue }
                entry.bindingState = .displayMissing
                entry.runtimeState = .inactive
                entry.updatedAt = Date()
                document.slots[slotIndex].screenEntries[screenID] = entry
                changed = true
            }
        }
        if changed {
            try save()
        }
    }

    func setRuntime(_ runtimeState: DesktopSlotRuntimeState, slotID: String, screenID: String) throws {
        guard let slotIndex = document.slots.firstIndex(where: { $0.id == slotID }),
              var entry = document.slots[slotIndex].screenEntries[screenID] else {
            return
        }
        entry.runtimeState = runtimeState
        entry.updatedAt = Date()
        document.slots[slotIndex].screenEntries[screenID] = entry
        try save()
    }

    func setAllRuntimeInactive(except active: [(slotID: String, screenID: String)] = []) throws {
        let activeKeys = Set(active.map { "\($0.slotID)|\($0.screenID)" })
        var changed = false
        for slotIndex in document.slots.indices {
            for screenID in document.slots[slotIndex].screenEntries.keys {
                guard var entry = document.slots[slotIndex].screenEntries[screenID] else { continue }
                let key = "\(document.slots[slotIndex].id)|\(screenID)"
                let desired: DesktopSlotRuntimeState = activeKeys.contains(key) ? entry.runtimeState : .inactive
                if entry.runtimeState != desired {
                    entry.runtimeState = desired
                    entry.updatedAt = Date()
                    document.slots[slotIndex].screenEntries[screenID] = entry
                    changed = true
                }
            }
        }
        if changed {
            try save()
        }
    }

    func setPending(
        kind: DesktopSlotPendingKind,
        sourceURL: URL,
        slotID: String,
        screen: NSScreen,
        options: DesktopSlotImageOptions
    ) async throws {
        guard let slotIndex = document.slots.firstIndex(where: { $0.id == slotID }) else {
            throw DesktopSlotStoreError.missingSlot
        }

        let screenID = screen.wallpaperScreenIdentifier
        var entry = document.slots[slotIndex].screenEntries[screenID] ?? .empty(for: screen)
        if entry.pendingAction?.kind == .pendingUserSet, kind == .pendingSchedulerSet {
            return
        }

        let pendingAsset = try await materializeSourceURL(
            sourceURL,
            into: pendingAssetURL(slotID: slotID, screenID: screenID, sourceURL: sourceURL)
        )
        entry.pendingAction = DesktopSlotPendingAction(
            id: UUID().uuidString,
            kind: kind,
            assetPath: normalizedPath(for: pendingAsset),
            sourcePath: sourceURL.isFileURL ? normalizedPath(for: sourceURL) : sourceURL.absoluteString,
            options: options,
            createdAt: Date()
        )
        entry.screenFingerprint = screen.wallpaperScreenFingerprint
        entry.updatedAt = Date()
        document.slots[slotIndex].screenEntries[screenID] = entry
        document.slots[slotIndex].updatedAt = Date()
        try save()
    }

    func createToken(_ sourceURL: URL, slotID: String, screen: NSScreen) async throws -> URL {
        let tokenURL = generationTokenURL(slotID: slotID, screenID: screen.wallpaperScreenIdentifier, sourceURL: sourceURL)
        return try await materializeSourceURL(sourceURL, into: tokenURL)
    }

    func createFileToken(_ sourceURL: URL, slotID: String, screen: NSScreen) throws -> URL {
        guard sourceURL.isFileURL,
              fileManager.fileExists(atPath: sourceURL.path) else {
            throw DesktopSlotStoreError.unreadableSource(sourceURL)
        }

        let tokenURL = generationTokenURL(
            slotID: slotID,
            screenID: screen.wallpaperScreenIdentifier,
            sourceURL: sourceURL
        )
        try fileManager.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: tokenURL.path) {
            try fileManager.removeItem(at: tokenURL)
        }
        try fileManager.copyItem(at: sourceURL, to: tokenURL)
        return tokenURL
    }

    func pendingAction(slotID: String, screenID: String) -> DesktopSlotPendingAction? {
        entry(slotID: slotID, screenID: screenID)?.pendingAction
    }

    func hasAnyBoundToken(for screenID: String) -> Bool {
        document.slots.contains { slot in
            guard let entry = slot.screenEntries[screenID] else { return false }
            return entry.currentTokenPath != nil && entry.bindingState != .displayMissing
        }
    }

    func markApplied(
        tokenURL: URL,
        slotID: String,
        screen: NSScreen,
        options: DesktopSlotImageOptions,
        runtimeState: DesktopSlotRuntimeState,
        sourcePath: String?,
        clearsPendingKind: DesktopSlotPendingKind?,
        clearsAnyPending: Bool = false
    ) throws {
        guard let slotIndex = document.slots.firstIndex(where: { $0.id == slotID }) else {
            throw DesktopSlotStoreError.missingSlot
        }

        let screenID = screen.wallpaperScreenIdentifier
        var entry = document.slots[slotIndex].screenEntries[screenID] ?? .empty(for: screen)
        let tokenPath = normalizedPath(for: tokenURL)
        if let current = entry.currentTokenPath, current != tokenPath {
            entry.historyTokenPaths.insert(current, at: 0)
        }
        entry.historyTokenPaths.removeAll { $0 == tokenPath }
        if entry.historyTokenPaths.count > Self.maxHistoryTokensPerEntry {
            entry.historyTokenPaths = Array(entry.historyTokenPaths.prefix(Self.maxHistoryTokensPerEntry))
        }
        entry.currentTokenPath = tokenPath
        entry.bindingState = .bound
        entry.runtimeState = runtimeState
        entry.screenFingerprint = screen.wallpaperScreenFingerprint
        entry.lastSourcePath = sourcePath
        entry.updatedAt = Date()
        entry.lastBoundAt = Date()

        if clearsAnyPending {
            entry.pendingAction = nil
        } else if let clearsPendingKind,
           entry.pendingAction?.kind == clearsPendingKind {
            entry.pendingAction = nil
        }

        document.slots[slotIndex].screenEntries[screenID] = entry
        document.slots[slotIndex].updatedAt = Date()
        try save()
    }

    func markLostBinding(slotID: String, screenID: String) throws {
        guard let slotIndex = document.slots.firstIndex(where: { $0.id == slotID }),
              var entry = document.slots[slotIndex].screenEntries[screenID] else {
            return
        }
        entry.bindingState = .lostBinding
        entry.runtimeState = .inactive
        entry.updatedAt = Date()
        document.slots[slotIndex].screenEntries[screenID] = entry
        try save()
    }

    func clearPending(slotID: String, screenID: String) throws {
        guard let slotIndex = document.slots.firstIndex(where: { $0.id == slotID }),
              var entry = document.slots[slotIndex].screenEntries[screenID] else {
            return
        }
        entry.pendingAction = nil
        entry.updatedAt = Date()
        document.slots[slotIndex].screenEntries[screenID] = entry
        try save()
    }

    func matchTokenPath(_ path: String, screenID: String) -> DesktopSlotTokenMatch? {
        let normalized = normalizedPath(forPath: path)
        for slot in document.slots {
            guard let entry = slot.screenEntries[screenID] else { continue }
            if entry.currentTokenPath.map(normalizedPath(forPath:)) == normalized {
                return DesktopSlotTokenMatch(slotID: slot.id, screenID: screenID, isCurrent: true)
            }
            if entry.historyTokenPaths.map(normalizedPath(forPath:)).contains(normalized) {
                return DesktopSlotTokenMatch(slotID: slot.id, screenID: screenID, isCurrent: false)
            }
        }
        return nil
    }

    func relinkDisplayEntriesForCurrentScreens() throws {
        let currentScreens = NSScreen.screens
        let currentScreenIDs = Set(currentScreens.map(\.wallpaperScreenIdentifier))
        var fingerprintToScreen: [String: NSScreen] = [:]
        for screen in currentScreens {
            fingerprintToScreen[screen.wallpaperScreenFingerprint] = screen
        }

        var changed = false
        for slotIndex in document.slots.indices {
            let existingIDs = Array(document.slots[slotIndex].screenEntries.keys)
            for oldScreenID in existingIDs where !currentScreenIDs.contains(oldScreenID) {
                guard let oldEntry = document.slots[slotIndex].screenEntries[oldScreenID] else { continue }
                if let newScreen = fingerprintToScreen[oldEntry.screenFingerprint],
                   document.slots[slotIndex].screenEntries[newScreen.wallpaperScreenIdentifier] == nil {
                    var relinked = oldEntry
                    relinked.screenID = newScreen.wallpaperScreenIdentifier
                    relinked.screenFingerprint = newScreen.wallpaperScreenFingerprint
                    relinked.bindingState = oldEntry.bindingState == .displayMissing ? .bound : oldEntry.bindingState
                    relinked.updatedAt = Date()
                    document.slots[slotIndex].screenEntries[newScreen.wallpaperScreenIdentifier] = relinked
                    document.slots[slotIndex].screenEntries.removeValue(forKey: oldScreenID)
                    print("[DesktopSlotStore] relinked display entry slot=\(document.slots[slotIndex].name) oldScreenID=\(oldScreenID) newScreenID=\(newScreen.wallpaperScreenIdentifier) fingerprint=\(oldEntry.screenFingerprint)")
                    changed = true
                } else if oldEntry.bindingState != .displayMissing {
                    var missing = oldEntry
                    missing.bindingState = .displayMissing
                    missing.runtimeState = .inactive
                    missing.updatedAt = Date()
                    document.slots[slotIndex].screenEntries[oldScreenID] = missing
                    changed = true
                }
            }
        }
        if changed {
            try save()
        }
    }

    func normalizedPath(for url: URL) -> String {
        normalizedPath(forPath: url.path)
    }

    func normalizedPath(forPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func cleanupUnreferencedAssets(referenceDate: Date = Date()) {
        let referencedPaths = referencedAssetPaths()
        cleanupFiles(in: tokenRootDirectory, referencedPaths: referencedPaths, referenceDate: referenceDate)
        cleanupFiles(in: pendingRootDirectory, referencedPaths: referencedPaths, referenceDate: referenceDate)
        enforceAssetDirectorySizeLimit(referencedPaths: referencedPaths)
    }

    private func materializeSourceURL(_ sourceURL: URL, into destinationURL: URL) async throws -> URL {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if sourceURL.isFileURL {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw DesktopSlotStoreError.unreadableSource(sourceURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }

        guard sourceURL.scheme?.hasPrefix("http") == true else {
            throw DesktopSlotStoreError.unsupportedRemoteURL(sourceURL)
        }

        let (data, _) = try await URLSession.shared.data(from: sourceURL)
        try await data.writeAsync(to: destinationURL)
        return destinationURL
    }

    private func pendingAssetURL(slotID: String, screenID: String, sourceURL: URL) -> URL {
        let ext = safePathExtension(for: sourceURL)
        return pendingRootDirectory
            .appendingPathComponent(slotID, isDirectory: true)
            .appendingPathComponent(screenID, isDirectory: true)
            .appendingPathComponent("pending-\(UUID().uuidString).\(ext)")
    }

    private func generationTokenURL(slotID: String, screenID: String, sourceURL: URL) -> URL {
        let ext = safePathExtension(for: sourceURL)
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        return tokenRootDirectory
            .appendingPathComponent(slotID, isDirectory: true)
            .appendingPathComponent(screenID, isDirectory: true)
            .appendingPathComponent("token-\(stamp)-\(UUID().uuidString).\(ext)")
    }

    private func safePathExtension(for url: URL) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.isEmpty { return "jpg" }
        if ext.count > 12 { return "dat" }
        return ext
    }

    private func normalizeDocument(_ document: inout DesktopSlotDocument) {
        document.schemaVersion = Self.schemaVersion
        if document.slots.isEmpty {
            document = Self.defaultDocument()
            return
        }
        document.slots.sort { $0.order < $1.order }
        for index in document.slots.indices {
            document.slots[index].order = index
            if document.slots[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.slots[index].name = createDefaultSlotName(index: index + 1)
            }
        }
    }

    private func normalizeOrders() {
        document.slots.sort { $0.order < $1.order }
        for index in document.slots.indices {
            document.slots[index].order = index
            document.slots[index].updatedAt = Date()
        }
    }

    private func referencedAssetPaths() -> Set<String> {
        var paths = Set<String>()
        for slot in document.slots {
            for entry in slot.screenEntries.values {
                if let currentTokenPath = entry.currentTokenPath {
                    paths.insert(normalizedPath(forPath: currentTokenPath))
                }
                for historyTokenPath in entry.historyTokenPaths {
                    paths.insert(normalizedPath(forPath: historyTokenPath))
                }
                if let pendingAssetPath = entry.pendingAction?.assetPath {
                    paths.insert(normalizedPath(forPath: pendingAssetPath))
                }
            }
        }
        return paths
    }

    private func cleanupFiles(in root: URL, referencedPaths: Set<String>, referenceDate: Date) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let path = normalizedPath(for: url)
            guard !referencedPaths.contains(path) else { continue }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard referenceDate.timeIntervalSince(modifiedAt) >= Self.tokenGraceInterval else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                print("[DesktopSlotStore] cleanup failed for \(url.path): \(error)")
            }
        }
    }

    private func enforceAssetDirectorySizeLimit(referencedPaths: Set<String>) {
        let files = assetFiles(in: tokenRootDirectory) + assetFiles(in: pendingRootDirectory)
        let totalSize = files.reduce(Int64(0)) { $0 + $1.size }
        guard totalSize > Self.maxAssetDirectoryBytes else { return }

        var bytesToFree = totalSize - Self.maxAssetDirectoryBytes
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard bytesToFree > 0 else { break }
            guard !referencedPaths.contains(normalizedPath(for: file.url)) else { continue }
            do {
                try fileManager.removeItem(at: file.url)
                bytesToFree -= file.size
            } catch {
                print("[DesktopSlotStore] size cleanup failed for \(file.url.path): \(error)")
            }
        }
        if bytesToFree > 0 {
            print("[DesktopSlotStore] asset directory exceeds size limit but remaining files are referenced; bytesToFree=\(bytesToFree)")
        }
    }

    private func assetFiles(in root: URL) -> [(url: URL, size: Int64, modifiedAt: Date)] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var files: [(url: URL, size: Int64, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            files.append((
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast
            ))
        }
        return files
    }

    private func createDefaultSlotName(index: Int) -> String {
        "桌面 \(index)"
    }

    private static func defaultDocument() -> DesktopSlotDocument {
        let now = Date()
        return DesktopSlotDocument(
            schemaVersion: schemaVersion,
            slots: [
                DesktopWallpaperSlot(id: UUID().uuidString, name: "桌面 1", order: 0, screenEntries: [:], createdAt: now, updatedAt: now),
                DesktopWallpaperSlot(id: UUID().uuidString, name: "桌面 2", order: 1, screenEntries: [:], createdAt: now, updatedAt: now)
            ],
            updatedAt: now
        )
    }
}
