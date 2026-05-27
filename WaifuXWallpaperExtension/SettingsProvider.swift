//  Settings provider for WallpaperAgent.
//
//  扫描 App Group 共享容器中的 WallpaperVideos，为每个视频创建设置项，
//  让用户在「系统设置 → 壁纸」中能看到并选择 WaifuX 的视频壁纸。

import AVFoundation
import AppKit
import Foundation

// MARK: - Public API

/// 构建完整的壁纸设置项列表并返回 XPC 对象。
/// 为共享容器 WallpaperVideos/ 中的每个 MP4 创建一个 SettingsItem。
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.waifux.app.wallpaperextension"
    let groupID = GroupID(id: "waifux-video-wallpapers")

    var items = [SettingsItem]()

    for entry in scanSharedVideos() {
        let videoURL = entry.url

        // 生成缩略图
        let thumbnailURL = await generateThumbnail(for: videoURL, entryID: entry.id)

        let choiceID = ChoiceID(
            id: entry.id,
            descriptor: ChoiceIDDescriptor(
                provider: ChoiceProviderID(rawValue: bundleID),
                identifier: entry.id,
                files: [videoURL],
                configuration: Data(entry.id.utf8)
            )
        )

        let thumb: Thumbnail
        if let thumbURL = thumbnailURL {
            thumb = .image(url: thumbURL)
        } else {
            thumb = .image(url: videoURL)
        }

        let choiceDescriptor = ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: entry.id,
            name: entry.name,
            localizedDescription: "WaifuX 视频壁纸",
            thumbnail: thumb,
            isDownloaded: true,
            options: []
        )

        let item = SettingsItem(
            id: choiceID,
            localizedName: entry.name,
            thumbnail: thumb,
            choice: choiceDescriptor,
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: 0,
            disposability: .removable
        )
        items.append(item)
    }

    let group = SettingsGroup(
        id: groupID,
        items: items,
        localizedName: "WaifuX — 视频壁纸",
        disposability: .none,
        sortOrder: -100,
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: nil,
        thumbnail: nil
    )

    let viewModel = SettingsViewModel(
        groups: [group],
        refreshPolicy: .default,
        isModificationDisabled: false
    )

    let viewModels = SettingsViewModels(
        desktop: viewModel,
        screenSaver: nil
    )

    return remapToRealXPC(viewModels)
}

/// 返回空分组，适用于扩展尚未准备好时充当 fallback。
func makeEmptyGroupsResponse() -> AnyObject? {
    let viewModels = SettingsViewModels(
        desktop: SettingsViewModel(
            groups: [],
            refreshPolicy: .default,
            isModificationDisabled: false
        ),
        screenSaver: nil
    )
    return remapToRealXPC(viewModels)
}

// MARK: - 扫描共享容器

private struct SharedVideoEntry {
    let id: String
    let name: String
    let url: URL
}

private func scanSharedVideos() -> [SharedVideoEntry] {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        extLog("[SettingsProvider] ❌ 共享容器不可用")
        return []
    }

    let videoDir = container.appendingPathComponent("WallpaperVideos", isDirectory: true)
    extLog("[SettingsProvider] 扫描目录: \(videoDir.path)")

    guard FileManager.default.fileExists(atPath: videoDir.path) else {
        extLog("[SettingsProvider] ⚠️ 目录不存在: \(videoDir.path)")
        return []
    }

    guard let files = try? FileManager.default.contentsOfDirectory(at: videoDir, includingPropertiesForKeys: nil) else {
        extLog("[SettingsProvider] ⚠️ 无法读取目录")
        return []
    }

    var entries: [SharedVideoEntry] = []
    for file in files {
        let ext = file.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { continue }
        let id = file.deletingPathExtension().lastPathComponent
        let name = id
        entries.append(SharedVideoEntry(id: id, name: name, url: file))
    }

    entries.sort { $0.id < $1.id }
    extLog("[SettingsProvider] 扫描到 \(entries.count) 个视频")
    return entries
}

// MARK: - 缩略图生成

private func generateThumbnail(for videoURL: URL, entryID: String) async -> URL? {
    let thumbnailDir: URL
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
        thumbnailDir = container.appendingPathComponent("WallpaperCache/thumbnails", isDirectory: true)
    } else {
        thumbnailDir = FileManager.default.temporaryDirectory.appendingPathComponent("waifux-thumbnails", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)

    let thumbnailURL = thumbnailDir.appendingPathComponent("\(entryID).jpg")
    if FileManager.default.fileExists(atPath: thumbnailURL.path) {
        return thumbnailURL
    }

    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 270)

    guard let cgImage = try? await generator.image(at: .zero).image else {
        extLog("[SettingsProvider] 缩略图生成失败: \(videoURL.lastPathComponent)")
        return nil
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
        return nil
    }

    do {
        try jpegData.write(to: thumbnailURL, options: .atomic)
        return thumbnailURL
    } catch {
        extLog("[SettingsProvider] 缩略图写入失败: \(error)")
        return nil
    }
}
