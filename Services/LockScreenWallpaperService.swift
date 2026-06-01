//  LockScreenWallpaperService.swift
//  WaifuX
//
//  管理锁屏镜像实例的共享状态与偏好同步。
//  仅在 macOS 26.0+ 生效，通过 WallpaperExtensionKit 私有框架实现。
//
//  支持多显示器：每个显示器可以部署不同的视频，扩展根据 choiceConfiguration 选择对应视频。

import AVFoundation
import Foundation
import AppKit
import ImageIO
import notify

/// 锁屏镜像实例管理服务
///
/// 真实业务模型是：
/// 1. 扩展为每个显示器暴露一个固定的锁屏实例，用户在系统设置中手动选择一次
/// 2. 主 App 维护“显示器 -> 当前桌面视频源”映射
/// 3. 实例激活后，主 App 仅向对应显示器实例推送桌面帧，不自动切换系统壁纸选择
@MainActor
final class LockScreenWallpaperService {
    static let shared = LockScreenWallpaperService()

    struct DisplayInstance: Codable, Sendable {
        let id: String
        let displayID: UInt32
        let name: String
        let thumbnailPath: String?
    }

    /// 功能是否可用（macOS 26.0+ 且已配置 App Group）
    var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return sharedContainerURL != nil
    }

    /// 当前写入共享容器的镜像帧源路径
    private(set) var currentMirroringSourcePath: String?

    /// 已写入共享容器的视频 ID 集合（兼容旧缓存清理）
    private var deployedVideoIDs: Set<String> = []

    private let appGroupID = "group.com.waifux.app"
    private let prefsFileName = "waifux-wallpaper-prefs.json"
    private let videoDirName = "WallpaperVideos"
    private let displayInstancesFileName = "waifux-display-instances.json"

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private init() {}

    var displayInstancesURL: URL? {
        sharedContainerURL?.appendingPathComponent(displayInstancesFileName)
    }

    // MARK: - Public API

    /// 将指定桌面视频源写入共享容器，供锁屏实例在需要时读取缩略图/兜底内容。
    /// - Parameters:
    ///   - videoURL: 本地视频文件路径（MP4/MOV）
    ///   - videoID: 壁纸唯一标识（用于区分不同壁纸）
    func cacheMirroringSource(videoURL: URL, videoID: String) async throws {
        guard isAvailable else {
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return
        }

        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] 动态锁屏已关闭，跳过")
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

        // 用 hard link 将视频放到共享容器（同一卷不占额外空间）
        let destURL = videoDir.appendingPathComponent("\(videoID).mp4")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        do {
            try FileManager.default.linkItem(at: videoURL, to: destURL)
        } catch {
            try FileManager.default.copyItem(at: videoURL, to: destURL)
        }

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

        currentMirroringSourcePath = destURL.path

        // 先更新显示器实例目录
        syncInstanceCatalogToSocketServer()

        // 再通知 Extension 刷新（此时 SocketServer 已有最新数据）
        notifyExtensionPrefsChanged()

        // 生成缩略图
        generateThumbnail(for: destURL, videoID: videoID)

        print("[LockScreenWallpaper] ✅ 已更新锁屏镜像帧源缓存: \(destURL.lastPathComponent)")
    }

    /// 清空当前锁屏镜像帧源缓存。
    /// 不触碰用户在系统设置里手动选择的显示器实例。
    func clearMirroringSourceCache() {
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

        currentMirroringSourcePath = nil
        deployedVideoIDs.removeAll()
        if #available(macOS 26.0, *) {
            WallpaperExtensionSocketServer.shared.clearDisplayVideos()
        }

        notifyExtensionPrefsChanged()

        print("[LockScreenWallpaper] ✅ 已清空锁屏镜像帧源缓存")
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

    // MARK: - Notification Helpers

    /// 通知 Extension 偏好设置已变更
        func notifyExtensionPrefsChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )
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

    // MARK: - Display Instances

    /// 当前显示器对应的锁屏实例目录。
    /// 用户在系统设置里手动为每块显示器选择一次这些实例，之后实例只负责接收对应显示器的推帧。
    func currentDisplayInstances() -> [DisplayInstance] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = screenNumber.uint32Value
            let instanceID = "display-\(displayID)"
            let thumbnailPath = posterThumbnailPath(for: screen)
            return DisplayInstance(
                id: instanceID,
                displayID: displayID,
                name: screen.localizedName,
                thumbnailPath: thumbnailPath
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.displayID < rhs.displayID }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func syncDisplayInstancesToSocketServer() {
        guard #available(macOS 26.0, *), isAvailable else { return }

        let instances = currentDisplayInstances()
        persistDisplayInstances(instances)

        let videos = instances.map { instance in
            IPCVideoInfo(
                id: instance.id,
                name: instance.name,
                videoPath: "",
                thumbnailPath: instance.thumbnailPath ?? ""
            )
        }
        WallpaperExtensionSocketServer.shared.updateVideos(videos)
        notifyExtensionPrefsChanged()
        print("[LockScreenWallpaper] 🖥️ 已同步 \(instances.count) 个显示器实例到 Socket 服务端")
    }

    func loadDisplayInstances() -> [DisplayInstance] {
        guard let url = displayInstancesURL,
              let data = try? Data(contentsOf: url),
              let instances = try? JSONDecoder().decode([DisplayInstance].self, from: data) else {
            return currentDisplayInstances()
        }
        return instances
    }

    /// 彻底清理锁屏实例：清除视频缓存、偏好设置、显示器实例列表、推送管线。
    /// 用户不再使用锁屏动态壁纸时调用。
    func clearLockScreenInstances() {
        guard isAvailable else { return }

        // 1. 清空视频缓存和偏好
        clearMirroringSourceCache()

        // 2. 删除显示器实例列表
        if let url = displayInstancesURL {
            try? FileManager.default.removeItem(at: url)
        }

        // 3. 清空 Socket 服务端可用实例
        WallpaperExtensionSocketServer.shared.updateVideos([])

        // 4. 通知扩展刷新
        notifyExtensionPrefsChanged()

        print("[LockScreenWallpaper] ✅ 已彻底清理锁屏实例")
    }

    private func persistDisplayInstances(_ instances: [DisplayInstance]) {
        guard let url = displayInstancesURL,
              let data = try? JSONEncoder().encode(instances) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func posterThumbnailPath(for screen: NSScreen) -> String? {
        let thumbDir = sharedContainerURL?.appendingPathComponent("WallpaperCache/thumbnails")
        let candidates = [
            "display-\(screen.wallpaperScreenIdentifier).jpg",
            "\(screen.wallpaperScreenIdentifier).jpg"
        ]
        for name in candidates {
            if let url = thumbDir?.appendingPathComponent(name),
               FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }

    // MARK: - 缩略图

    /// 生成视频的 JPEG 缩略图并写入共享容器供扩展读取
    private func generateThumbnail(for videoURL: URL, videoID: String) {
        guard let container = sharedContainerURL else { return }
        let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let thumbURL = thumbDir.appendingPathComponent("\(videoID).jpg")

        if FileManager.default.fileExists(atPath: thumbURL.path) { return }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        var actualTime: CMTime = .zero
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: &actualTime) else {
            print("[LockScreenWallpaper] ⚠️ 缩略图生成失败: \(videoURL.lastPathComponent)")
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            print("[LockScreenWallpaper] ✅ 缩略图已生成: \(thumbURL.lastPathComponent)")
        }
    }

    // MARK: - Socket IPC 集成

    /// 将当前显示器实例目录同步到 Socket IPC 服务端。
    func syncInstanceCatalogToSocketServer() {
        guard #available(macOS 26.0, *) else { return }
        let instances = loadDisplayInstances()
        let instanceInfos = instances.map { instance in
            IPCVideoInfo(
                id: instance.id,
                name: instance.name,
                videoPath: "",
                thumbnailPath: instance.thumbnailPath ?? ""
            )
        }
        WallpaperExtensionSocketServer.shared.updateVideos(instanceInfos)
        print("[LockScreenWallpaper] 📋 已同步 \(instanceInfos.count) 个显示器实例到 Socket 服务端")
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
