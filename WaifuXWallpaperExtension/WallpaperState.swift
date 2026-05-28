//  Thread-safe shared state for the wallpaper extension.

import Foundation
import os
import QuartzCore

struct ActiveWallpaper: @unchecked Sendable {
    let caContext: AnyObject
    let rootLayer: CALayer
    let renderer: VideoRenderer?
    let displayID: UInt32?
    let videoID: String?
}

final class WallpaperState: Sendable {
    static let shared = WallpaperState()

    private static let selectedVideoKey = "waifux_selected_video_id"

    private struct State: @unchecked Sendable {
        var activeContexts: [UInt32: ActiveWallpaper] = [:]
        var wallpaperIDToContext: [String: UInt32] = [:]
        var cachedVideoURL: URL?
        var currentVideoID: String? = UserDefaults.standard.string(forKey: WallpaperState.selectedVideoKey)
        var presentationMode: String = "active"
        var activityState: String = "active"
        var isDisplayAsleep: Bool = false
        var isScreenLocked: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    // MARK: - Context Management

    func storeContext(_ context: ActiveWallpaper, id: UInt32, wallpaperID: String?) -> ActiveWallpaper? {
        lock.withLock { state in
            var existing: ActiveWallpaper?
            if let wid = wallpaperID, let oldId = state.wallpaperIDToContext[wid] {
                existing = state.activeContexts.removeValue(forKey: oldId)
            }
            state.activeContexts[id] = context
            if let wid = wallpaperID {
                state.wallpaperIDToContext[wid] = id
            }
            return existing
        }
    }

    func removeContext(wallpaperID: String) -> ActiveWallpaper? {
        lock.withLock { state in
            guard let contextId = state.wallpaperIDToContext.removeValue(forKey: wallpaperID) else { return nil }
            return state.activeContexts.removeValue(forKey: contextId)
        }
    }

    func removeAllContexts() -> [ActiveWallpaper] {
        let removed = lock.withLock { state -> [ActiveWallpaper] in
            let all = Array(state.activeContexts.values)
            state.activeContexts.removeAll()
            state.wallpaperIDToContext.removeAll()
            return all
        }
        for ctx in removed { ctx.renderer?.stop() }
        return removed
    }

    // MARK: - Iteration

    func forEachRenderer(_ body: (VideoRenderer) -> Void) {
        let renderers = lock.withLock { $0.activeContexts.values.compactMap(\.renderer) }
        for renderer in renderers { body(renderer) }
    }

    /// 遍历每个活跃 context 的 renderer 和 displayID（用于 per-display policy）
    func forEachActiveContext(_ body: (UInt32?, VideoRenderer) -> Void) {
        let contexts = lock.withLock { Array($0.activeContexts.values) }
        for ctx in contexts {
            if let renderer = ctx.renderer {
                body(ctx.displayID, renderer)
            }
        }
    }

    func switchActiveRenderers(to videoURL: URL, displayID: UInt32? = nil) -> Int {
        let renderers = lock.withLock {
            $0.activeContexts.values.compactMap { context -> VideoRenderer? in
                if let displayID, context.displayID != displayID {
                    return nil
                }
                return context.renderer
            }
        }
        for renderer in renderers {
            renderer.replaceVideo(with: videoURL)
        }
        return renderers.count
    }

    func uniqueDisplayIDs() -> Set<UInt32> {
        lock.withLock { Set($0.activeContexts.values.compactMap(\.displayID)) }
    }

    var activeContextCount: Int {
        lock.withLock { $0.activeContexts.count }
    }

    func clearCaches() {
        lock.withLock { state in
            state.cachedVideoURL = nil
        }
    }

    // MARK: - Properties

    var cachedVideoURL: URL? {
        get { lock.withLock { $0.cachedVideoURL } }
        set { lock.withLock { $0.cachedVideoURL = newValue } }
    }

    var currentVideoID: String? {
        get { lock.withLock { $0.currentVideoID } }
        set {
            lock.withLock { $0.currentVideoID = newValue }
            UserDefaults.standard.set(newValue, forKey: WallpaperState.selectedVideoKey)
        }
    }

    var presentationMode: String {
        get { lock.withLock { $0.presentationMode } }
        set { lock.withLock { $0.presentationMode = newValue } }
    }

    var activityState: String {
        get { lock.withLock { $0.activityState } }
        set { lock.withLock { $0.activityState = newValue } }
    }

    var isDisplayAsleep: Bool {
        get { lock.withLock { $0.isDisplayAsleep } }
        set { lock.withLock { $0.isDisplayAsleep = newValue } }
    }

    var isScreenLocked: Bool {
        get { lock.withLock { $0.isScreenLocked } }
        set { lock.withLock { $0.isScreenLocked = newValue } }
    }
}
