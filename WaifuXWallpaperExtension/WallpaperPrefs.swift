//  Extension-side reader for shared preferences written by the main app.

import Foundation
import os

final class WallpaperPrefs: @unchecked Sendable {
    static let shared = WallpaperPrefs()

    private struct PrefsFile: Codable {
        var userPaused: Bool = false
        var alwaysPauseDesktop: Bool = false
        var currentVideoPath: String?
        /// Per-display pause: displayID 集合，这些显示器的视频应暂停
        var pausedDisplayIDs: Set<UInt32>?
        /// Per-display mute: displayID 集合，这些显示器的视频应静音
        var mutedDisplayIDs: Set<UInt32>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: PrefsFile())

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")
    }

    private static var prefsURL: URL? {
        sharedContainerURL?.appendingPathComponent("waifux-wallpaper-prefs.json")
    }

    private init() { reload() }

    var userPaused: Bool { lock.withLock { $0.userPaused } }
    var alwaysPauseDesktop: Bool { lock.withLock { $0.alwaysPauseDesktop } }

    var currentVideoPath: String? {
        lock.withLock { $0.currentVideoPath }
    }

    /// 指定 displayID 是否应暂停
    func isDisplayPaused(_ displayID: UInt32) -> Bool {
        lock.withLock { $0.pausedDisplayIDs?.contains(displayID) ?? false }
    }

    /// 指定 displayID 是否应静音
    func isDisplayMuted(_ displayID: UInt32) -> Bool {
        lock.withLock { $0.mutedDisplayIDs?.contains(displayID) ?? false }
    }

    // MARK: - I/O

    func reload() {
        guard let url = Self.prefsURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PrefsFile.self, from: data) else { return }
        lock.withLock { $0 = decoded }
    }

    // MARK: - State (extension -> app)

    func setActive(_ active: Bool) {
        let state: [String: Any] = [
            "isActive": active,
            "videoID": WallpaperState.shared.currentVideoID ?? "",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let url = Self.sharedContainerURL?.appendingPathComponent("waifux-wallpaper-state.json") {
            try? data.write(to: url, options: .atomic)
        }
        postStateNotification()
    }

    func observeChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<WallpaperPrefs>.fromOpaque(observer).takeUnretainedValue().reload()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func postStateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.stateChanged" as CFString),
            nil, nil, true
        )
    }
}
