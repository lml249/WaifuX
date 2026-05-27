//  Video library access for the extension.
//  Reads the shared container to find the currently selected video.

import Foundation

/// 根据 videoID 查找对应的视频文件。
/// 多显示器场景下系统会为每个显示器发送不同的 choiceConfiguration（即 videoID），
/// 扩展需要根据 ID 定位到具体视频文件而非总是返回第一个。
func findVideoURL(videoID: String? = nil) -> URL? {
    guard let sharedContainer = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.waifux.app"
    ) else { return nil }

    let videoDir = sharedContainer.appendingPathComponent("WallpaperVideos")

    // 1. 如果有 videoID，优先按 ID 精确匹配
    if let videoID, !videoID.isEmpty {
        // 尝试直接匹配文件名（videoID.mp4）
        let candidates = ["\(videoID).mp4", "\(videoID).mov", "\(videoID).m4v"]
        for name in candidates {
            let url = videoDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                WallpaperState.shared.cachedVideoURL = url
                return url
            }
        }

        // 尝试模糊匹配：文件名包含 videoID
        if let files = try? FileManager.default.contentsOfDirectory(at: videoDir, includingPropertiesForKeys: nil) {
            let match = files.first { file in
                let name = file.deletingPathExtension().lastPathComponent
                return name.contains(videoID) || videoID.contains(name)
            }
            if let match {
                WallpaperState.shared.cachedVideoURL = match
                return match
            }
        }

        extLog("[VideoLibrary] ⚠️ 未找到 videoID=\(videoID) 的视频，回退到默认")
    }

    // 2. 回退：检查缓存
    if let cached = WallpaperState.shared.cachedVideoURL,
       FileManager.default.fileExists(atPath: cached.path) {
        return cached
    }

    // 3. 回退：从 prefs 读取
    let prefsURL = sharedContainer.appendingPathComponent("waifux-wallpaper-prefs.json")
    if let data = try? Data(contentsOf: prefsURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let path = json["currentVideoPath"] as? String,
       FileManager.default.fileExists(atPath: path) {
        let url = URL(fileURLWithPath: path)
        WallpaperState.shared.cachedVideoURL = url
        return url
    }

    // 4. 最终回退：目录中的第一个 MP4
    if let files = try? FileManager.default.contentsOfDirectory(at: videoDir, includingPropertiesForKeys: nil) {
        if let mp4 = files.first(where: { $0.pathExtension.lowercased() == "mp4" }) {
            WallpaperState.shared.cachedVideoURL = mp4
            return mp4
        }
    }

    return nil
}
