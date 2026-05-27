//  LockScreenWallpaperService.swift
//  WaifuX
//
//  管理锁屏动态壁纸的部署与状态同步。
//  仅在 macOS 26.0+ 生效，通过 WallpaperExtensionKit 私有框架实现。
//
//  支持多显示器：每个显示器可以部署不同的视频，扩展根据 choiceConfiguration 选择对应视频。

import Foundation
import AppKit
import notify

/// 锁屏动态壁纸管理服务
///
/// 当用户在 macOS 26+ 上设置动态壁纸（本机 MP4 或烘焙后的 Scene 视频）时，
/// 该服务会将视频复制到 App Group 共享容器，并通过 Darwin 通知通知 Wallpaper Extension。
///
/// 多显示器场景下，每个显示器的视频都会被部署到共享容器的 WallpaperVideos/ 目录，
/// 扩展的 SettingsProvider 会为每个视频创建设置项，系统壁纸选择器支持按显示器分配不同视频。
@MainActor
final class LockScreenWallpaperService {
    static let shared = LockScreenWallpaperService()

    /// 功能是否可用（macOS 26.0+ 且已配置 App Group）
    var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return sharedContainerURL != nil
    }

    /// 当前部署到共享容器的视频路径（主屏/单显示器）
    private(set) var currentLockScreenVideoPath: String?

    /// 已部署的视频 ID 集合（用于清理不再需要的视频）
    private var deployedVideoIDs: Set<String> = []

    private let appGroupID = "group.com.waifux.app"
    private let prefsFileName = "waifux-wallpaper-prefs.json"
    private let videoDirName = "WallpaperVideos"

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private init() {}

    // MARK: - Public API

    /// 将指定视频部署为锁屏动态壁纸（单视频模式）
    /// - Parameters:
    ///   - videoURL: 本地视频文件路径（MP4/MOV）
    ///   - videoID: 壁纸唯一标识（用于区分不同壁纸）
    func deployLockScreenVideo(videoURL: URL, videoID: String) async throws {
        guard isAvailable else {
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return
        }

        guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LockScreenError.fileNotFound
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)

        // 清理不再需要的旧视频（保留当前部署的和新视频）
        var keepIDs = deployedVideoIDs
        keepIDs.insert(videoID)
        cleanupOldVideos(in: videoDir, keeping: keepIDs)

        // 复制新视频到共享容器
        let destURL = videoDir.appendingPathComponent("\(videoID).mp4")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: videoURL, to: destURL)

        deployedVideoIDs.insert(videoID)

        // 写入偏好设置
        let prefs = PrefsFile(
            userPaused: false,
            alwaysPauseDesktop: false,
            currentVideoPath: destURL.path
        )
        let prefsURL = container.appendingPathComponent(prefsFileName)
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: prefsURL, options: .atomic)

        currentLockScreenVideoPath = destURL.path

        // 通知 Extension 刷新
        notifyExtensionPrefsChanged()

        // 写入系统壁纸配置，选中 WaifuX 为当前壁纸
        selectWaifuXInSystemWallpaper(videoID: videoID)

        print("[LockScreenWallpaper] ✅ 已部署锁屏视频: \(destURL.lastPathComponent)")
    }

    /// 为多显示器部署多个视频到共享容器。
    /// 每个视频以 videoID 命名，扩展通过 choiceConfiguration 选择对应视频。
    /// - Parameter videoMap: [videoID: 本地视频文件 URL]
    func deployVideosForDisplays(videoMap: [String: URL]) async throws {
        guard isAvailable else { return }
        guard !videoMap.isEmpty else { return }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)

        var newDeployedIDs: Set<String> = []

        for (videoID, videoURL) in videoMap {
            guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
                print("[LockScreenWallpaper] ⚠️ 跳过不存在的视频: \(videoID)")
                continue
            }

            let destURL = videoDir.appendingPathComponent("\(videoID).mp4")

            // 如果目标文件已存在且大小相同，跳过复制（避免不必要的 I/O）
            let srcAttrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
            let dstAttrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
            if let srcSize = srcAttrs?[.size] as? Int,
               let dstSize = dstAttrs?[.size] as? Int,
               srcSize == dstSize {
                newDeployedIDs.insert(videoID)
                continue
            }

            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: videoURL, to: destURL)
            newDeployedIDs.insert(videoID)
            print("[LockScreenWallpaper] ✅ 已部署视频: \(videoID).mp4")
        }

        // 清理不再需要的旧视频
        cleanupOldVideos(in: videoDir, keeping: newDeployedIDs)
        deployedVideoIDs = newDeployedIDs

        // 更新主屏路径（第一个视频作为默认）
        if let firstID = newDeployedIDs.first {
            currentLockScreenVideoPath = videoDir.appendingPathComponent("\(firstID).mp4").path
        }

        // 写入偏好设置
        let prefs = PrefsFile(
            userPaused: false,
            alwaysPauseDesktop: false,
            currentVideoPath: currentLockScreenVideoPath
        )
        let prefsURL = container.appendingPathComponent(prefsFileName)
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: prefsURL, options: .atomic)

        notifyExtensionPrefsChanged()
        if let selectedID = newDeployedIDs.sorted().first {
            selectWaifuXInSystemWallpaper(videoID: selectedID)
            sendSetVideoCommand(videoID: selectedID)
        }
        print("[LockScreenWallpaper] ✅ 多显示器视频部署完成: \(newDeployedIDs.count) 个视频")
    }

    /// 清除所有锁屏动态壁纸
    func clearLockScreenVideo() {
        guard isAvailable else { return }

        guard let container = sharedContainerURL else { return }

        // 清空视频目录
        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: videoDir)

        // 更新偏好设置
        let prefs = PrefsFile(userPaused: false, alwaysPauseDesktop: false, currentVideoPath: nil)
        let prefsURL = container.appendingPathComponent(prefsFileName)
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }

        currentLockScreenVideoPath = nil
        deployedVideoIDs.removeAll()

        // 从系统壁纸配置中移除 WaifuX（恢复默认壁纸）
        removeWaifuXFromSystemWallpaper()

        notifyExtensionPrefsChanged()

        print("[LockScreenWallpaper] ✅ 已清除锁屏视频")
    }

    /// 暂停/恢复锁屏壁纸播放（用户手动控制）
    func setPaused(_ paused: Bool) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.userPaused = paused
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 设置是否仅在锁屏时播放（桌面暂停）
    func setAlwaysPauseDesktop(_ pause: Bool) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.alwaysPauseDesktop = pause
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 设置指定显示器的暂停状态（per-display pause）
    func setDisplayPaused(_ paused: Bool, forDisplayID displayID: UInt32) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        if paused {
            if prefs.pausedDisplayIDs == nil { prefs.pausedDisplayIDs = [] }
            prefs.pausedDisplayIDs?.insert(displayID)
        } else {
            prefs.pausedDisplayIDs?.remove(displayID)
        }
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 查询指定显示器是否处于暂停状态
    func isDisplayPaused(_ displayID: UInt32) -> Bool {
        guard isAvailable else { return false }
        guard let container = sharedContainerURL else { return false }
        let prefsURL = container.appendingPathComponent(prefsFileName)
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(PrefsFile.self, from: data) else { return false }
        return prefs.pausedDisplayIDs?.contains(displayID) ?? false
    }

    /// 设置指定显示器的静音状态（per-display mute）
    func setDisplayMuted(_ muted: Bool, forDisplayID displayID: UInt32) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        if muted {
            if prefs.mutedDisplayIDs == nil { prefs.mutedDisplayIDs = [] }
            prefs.mutedDisplayIDs?.insert(displayID)
        } else {
            prefs.mutedDisplayIDs?.remove(displayID)
        }
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    // MARK: - System Wallpaper Properties

    /// 系统壁纸配置文件路径
    private var wallpaperStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// WaifuX 壁纸扩展 Bundle ID
    private let extensionBundleID = "com.waifux.app.wallpaperextension"

    // MARK: - Integration Helpers

    /// 当用户通过 VideoWallpaperManager 设置本机视频壁纸时，同时部署到锁屏
    func syncFromVideoWallpaper(videoURL: URL, videoID: String) {
        guard isAvailable else {
            print("[LockScreenWallpaper] ⚠️ syncFromVideoWallpaper skipped: isAvailable=false")
            return
        }
        Task {
            do {
                try await deployLockScreenVideo(videoURL: videoURL, videoID: videoID)
                // 通过命令文件通知扩展切换视频（比 Darwin 通知更可靠）
                sendSetVideoCommand(videoID: videoID)
                // selectWaifuXInSystemWallpaper 已在 deployLockScreenVideo 中调用
            } catch {
                print("[LockScreenWallpaper] ❌ syncFromVideoWallpaper 失败: \(error.localizedDescription)")
            }
        }
    }

    /// 当用户通过 WallpaperEngineXBridge 设置 WE 动态壁纸且已烘焙为视频时，同时部署到锁屏
    func syncFromBakedVideo(videoURL: URL, videoID: String) {
        guard isAvailable else {
            print("[LockScreenWallpaper] ⚠️ syncFromBakedVideo skipped: isAvailable=false")
            return
        }
        Task {
            do {
                try await deployLockScreenVideo(videoURL: videoURL, videoID: videoID)
                sendSetVideoCommand(videoID: videoID)
                // selectWaifuXInSystemWallpaper 已在 deployLockScreenVideo 中调用
            } catch {
                print("[LockScreenWallpaper] ❌ syncFromBakedVideo 失败: \(error.localizedDescription)")
            }
        }
    }

    /// 通过命令文件通知扩展切换视频（比 Darwin 通知更可靠）
    private func sendSetVideoCommand(videoID: String, displayID: UInt32? = nil) {
        guard let container = sharedContainerURL else { return }

        let cmdDir = container.appendingPathComponent("Commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: cmdDir, withIntermediateDirectories: true)

        var cmd: [String: Any] = [
            "action": "setVideo",
            "videoID": videoID,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let displayID {
            cmd["displayID"] = displayID
        }

        let fileName = "set-video-\(UUID().uuidString).json"
        let fileURL = cmdDir.appendingPathComponent(fileName)

        guard let data = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        try? data.write(to: fileURL, options: .atomic)

        print("[LockScreenWallpaper] 📝 写入命令文件: \(fileName)")
    }

    // MARK: - System Wallpaper Configuration

    /// 直接写入系统壁纸配置文件 Index.plist，将 WaifuX 设为当前壁纸。
    /// App 无沙箱限制，可以修改此文件。系统 WallpaperAgent 通过 DispatchSource
    /// 监听文件变化，检测到变更后自动加载 WaifuX 扩展。
    /// 路径: ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
    ///
    /// - 优先从现有 plist 中读取显示器 UUID（保证跟系统使用的完全一致）
    /// - 保留已有的所有结构和 Choice（追加而非覆盖）
    /// - 保持原始 plist 格式（binary/XML）
    /// - 先用临时文件写入 + 完整性校验，再覆盖原文件
    /// - 延迟 1.5 秒执行，防止 setPosterAsDesktopWallpaper 触发的系统异步写覆盖
    func selectWaifuXInSystemWallpaper(videoID: String) {
        // 延迟写入，确保 NSWorkspace.setDesktopImageURLForAllSpaces
        // 触发的系统异步写操作先完成，避免覆盖我们的 choice
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.performSelectWallpaper(videoID: videoID)
        }
    }

    /// 构建系统壁纸 Choice 字典
    /// macOS 26 Index.plist 的 Choice 需要 Provider + Configuration(Data) + Files(Array)
    /// Configuration 存储视频 ID 的 UTF-8 Data，扩展的 acquire 方法通过 Mirror 解析还原
    private func makeWaifuXChoice(videoID: String) -> [String: Any] {
        return [
            "Configuration": Data(videoID.utf8),
            "Files": [] as [Any],
            "Provider": extensionBundleID
        ]
    }

    private func performSelectWallpaper(videoID: String) {
        // 读取现有壁纸配置
        guard FileManager.default.fileExists(atPath: wallpaperStoreURL.path) else {
            print("[LockScreenWallpaper] ⚠️ 系统壁纸配置文件不存在: \(wallpaperStoreURL.path)")
            return
        }

        guard let plistData = try? Data(contentsOf: wallpaperStoreURL) else {
            print("[LockScreenWallpaper] ❌ 无法读取系统壁纸配置数据")
            return
        }

        var originalFormat: PropertyListSerialization.PropertyListFormat = .xml
        guard var plist = try? PropertyListSerialization.propertyList(from: plistData, format: &originalFormat) as? [String: Any] else {
            print("[LockScreenWallpaper] ❌ 无法解析系统壁纸配置 plist")
            return
        }

        // 获取显示器 UUID：只使用当前连接的显示器
        let currentDisplays = resolveDisplayUUIDs()
        let currentUUIDs = Set(currentDisplays.map { $0.uuid })
        print("[LockScreenWallpaper] 当前连接的显示器 (\(currentDisplays.count) 个): \(currentUUIDs)")

        guard !currentUUIDs.isEmpty else {
            print("[LockScreenWallpaper] ⚠️ 无法获取任何显示器 UUID，跳过写入")
            return
        }

        let newChoice = makeWaifuXChoice(videoID: videoID)

        // 构建 Displays 字典：保留所有现有条目，但只更新当前已连接的显示器
        var displaysDict = plist["Displays"] as? [String: Any] ?? [:]
        var changed = false

        for displayUUID in currentUUIDs {
            var displayDict = displaysDict[displayUUID] as? [String: Any] ?? [:]

            // 同时更新 Desktop（桌面壁纸）和 Idle（锁屏壁纸）两个 scope
            for scope in ["Desktop", "Idle"] {
                var scopeDict = displayDict[scope] as? [String: Any] ?? [:]
                var contentDict = scopeDict["Content"] as? [String: Any] ?? [:]

                // Choices 是当前选中的内容集合；只追加会让系统看到候选项，
                // 但不会把 WaifuX 切成当前壁纸。
                contentDict["Choices"] = [newChoice]
                contentDict["Shuffle"] = NSNull()
                scopeDict["Content"] = contentDict
                scopeDict["LastSet"] = Date()
                scopeDict["LastUse"] = Date()
                displayDict[scope] = scopeDict
            }

            displaysDict[displayUUID] = displayDict
            changed = true
        }

        plist["Displays"] = displaysDict

        guard changed else {
            print("[LockScreenWallpaper] ⚠️ 没有需要更新的显示器")
            return
        }

        // 序列化（保持原始格式）
        guard let serializedData = try? PropertyListSerialization.data(fromPropertyList: plist, format: originalFormat, options: 0) else {
            print("[LockScreenWallpaper] ❌ 无法序列化壁纸配置")
            return
        }

        // 先写临时文件 → 完整性校验 → 覆盖原文件
        let tempURL = wallpaperStoreURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.createDirectory(at: wallpaperStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try serializedData.write(to: tempURL, options: .atomic)
            let verifyData = try Data(contentsOf: tempURL)
            guard !verifyData.isEmpty else {
                throw NSError(domain: "LockScreenWallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey: "写入的文件为空"])
            }
            if FileManager.default.fileExists(atPath: wallpaperStoreURL.path) {
                try FileManager.default.removeItem(at: wallpaperStoreURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: wallpaperStoreURL)
            print("[LockScreenWallpaper] ✅ 已写入系统壁纸配置，选中 WaifuX (\(videoID))")

            // 通知系统壁纸配置已变更
            postWallpaperChangeNotifications()
        } catch {
            print("[LockScreenWallpaper] ❌ 写入壁纸配置失败: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// 从系统壁纸配置中移除 WaifuX（恢复默认壁纸）
    private func removeWaifuXFromSystemWallpaper() {
        guard FileManager.default.fileExists(atPath: wallpaperStoreURL.path) else { return }

        guard let plistData = try? Data(contentsOf: wallpaperStoreURL),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              var displaysDict = plist["Displays"] as? [String: Any] else {
            print("[LockScreenWallpaper] ❌ 无法读取系统壁纸配置")
            return
        }

        var changed = false

        for (displayUUID, displayValue) in displaysDict {
            guard var displayDict = displayValue as? [String: Any] else { continue }

            // 同时清理 Desktop 和 Idle 两个 scope 中的 WaifuX choice
            for scope in ["Desktop", "Idle"] {
                guard var scopeDict = displayDict[scope] as? [String: Any],
                      var contentDict = scopeDict["Content"] as? [String: Any],
                      var choices = contentDict["Choices"] as? [[String: Any]] else {
                    continue
                }

                let filteredChoices = choices.filter { ($0["Provider"] as? String) != extensionBundleID }
                if filteredChoices.count < choices.count {
                    if filteredChoices.isEmpty {
                        contentDict.removeValue(forKey: "Choices")
                    } else {
                        contentDict["Choices"] = filteredChoices
                    }
                    scopeDict["Content"] = contentDict
                    scopeDict["LastSet"] = Date()
                    scopeDict["LastUse"] = Date()
                    displayDict[scope] = scopeDict
                    changed = true
                }
            }

            if changed {
                displaysDict[displayUUID] = displayDict
            }
        }

        guard changed else { return }

        plist["Displays"] = displaysDict

        if let updatedData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? updatedData.write(to: wallpaperStoreURL, options: .atomic)
            print("[LockScreenWallpaper] ✅ 已从系统壁纸配置中移除 WaifuX")
            postWallpaperChangeNotifications()
        }
    }

    /// 解析当前所有显示器的 UUID（兼容 macOS 26+ 的私有 API 和回退方案）
    private func resolveDisplayUUIDs() -> [(uuid: String, displayID: UInt32)] {
        // 尝试使用 NSCGSDisplayConfiguration 私有 API 获取真实 UUID
        if let configClass = NSClassFromString("NSCGSDisplayConfiguration") as? NSObject.Type,
           let config = configClass.perform(NSSelectorFromString("currentConfiguration"))?.takeUnretainedValue() as? NSObject,
           let uniqueDisplays = config.value(forKey: "uniqueDisplays") as? [NSObject] {
            var results: [(String, UInt32)] = []
            for display in uniqueDisplays {
                if let uuid = (display.value(forKey: "UUID") as? NSUUID)?.uuidString,
                   let displayID = display.value(forKey: "displayID") as? UInt32 {
                    results.append((uuid, displayID))
                }
            }
            if !results.isEmpty {
                return results
            }
            print("[LockScreenWallpaper] 私有 API 返回空，尝试 CGDisplayCreateUUIDFromDisplayID 回退")
        } else {
            print("[LockScreenWallpaper] NSCGSDisplayConfiguration 不可用，使用 CGDisplayCreateUUIDFromDisplayID")
        }

        // 回退：使用 CGDisplayCreateUUIDFromDisplayID 生成稳定的 UUID
        var fallbackResults: [(uuid: String, displayID: UInt32)] = []
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                print("[LockScreenWallpaper] ⚠️ 跳过无法获取 NSScreenNumber 的屏幕: \(screen.localizedName)")
                continue
            }
            let displayID = screenNumber.uint32Value
            if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                let uuidString = CFUUIDCreateString(nil, cfUUID) as String? ?? UUID().uuidString
                fallbackResults.append((uuidString, displayID))
            } else {
                print("[LockScreenWallpaper] ⚠️ 无法为 displayID \(displayID) 创建 UUID")
            }
        }
        return fallbackResults
    }

    // MARK: - Notification Helpers

    /// 通知 Extension 偏好设置已变更
    private func notifyExtensionPrefsChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )
    }

    /// 发送系统壁纸变更通知
    private func postWallpaperChangeNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.apple.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )
        notify_post("com.apple.wallpaper.changed")
        notify_post("com.apple.wallpaper.wallpaperDidChange")
    }

    /// 清理不再需要的旧视频，保留 keepIDs 中的所有视频
    private func cleanupOldVideos(in directory: URL, keeping keepIDs: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if !keepIDs.contains(name) {
                try? fm.removeItem(at: file)
                print("[LockScreenWallpaper] 🗑️ 清理旧视频: \(name)")
            }
        }
    }

    // MARK: - Types

    private struct PrefsFile: Codable {
        var userPaused: Bool = false
        var alwaysPauseDesktop: Bool = false
        var currentVideoPath: String?
        /// Per-display pause: displayID 集合
        var pausedDisplayIDs: Set<UInt32>?
        /// Per-display mute: displayID 集合
        var mutedDisplayIDs: Set<UInt32>?
    }
}

enum LockScreenError: LocalizedError {
    case fileNotFound
    case appGroupNotAvailable
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "视频文件不存在"
        case .appGroupNotAvailable: return "App Group 共享容器不可用"
        case .copyFailed(let msg): return "复制失败: \(msg)"
        }
    }
}
