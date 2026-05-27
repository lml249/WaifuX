//  XPC handler implementing WallpaperExtensionXPCProtocol

import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    var agentProxy: (any WallpaperExtensionProxyXPCProtocol)?
    private var previousPresentationMode = "default"

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("=== ACQUIRE ===")

        var wallpaperIDString: String?
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                wallpaperIDString = String(idStr[range])
            }
        }

        // Extract displayID and destSize from request via Mirror
        var displayID: UInt32?
        var destSize = CGSize(width: 1920, height: 1080)
        var scaleFactor: CGFloat = 1.0
        var isPreview = false
        var choiceConfiguration: String?

        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let innerValue = mirror.children.first?.value {
                let desc = String(describing: innerValue)
                if let dRange = desc.range(of: "displayID: ") {
                    let after = desc[dRange.upperBound...]
                    if let end = after.range(of: ",") ?? after.range(of: ")") {
                        displayID = UInt32(after[..<end.lowerBound].trimmingCharacters(in: .whitespaces))
                    }
                }
                if let wRange = desc.range(of: "width: "), let hRange = desc.range(of: "height: ") {
                    let afterW = desc[wRange.upperBound...]
                    let afterH = desc[hRange.upperBound...]
                    if let endW = afterW.range(of: ",") ?? afterW.range(of: ")"),
                       let endH = afterH.range(of: ",") ?? afterH.range(of: ")") {
                        destSize.width = CGFloat(Double(afterW[..<endW.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1920)
                        destSize.height = CGFloat(Double(afterH[..<endH.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1080)
                    }
                }
                if let sRange = desc.range(of: "scaleFactor: ") {
                    let after = desc[sRange.upperBound...]
                    if let end = after.range(of: ",") ?? after.range(of: ")") {
                        scaleFactor = CGFloat(Double(after[..<end.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1.0)
                    }
                }
                isPreview = desc.contains("isPreview: true")
                // 尝试解析 String 格式的 configuration: Optional("videoID")
                if let cRange = desc.range(of: "configuration: Optional(\""), let cEnd = desc[cRange.upperBound...].range(of: "\")") {
                    choiceConfiguration = String(desc[cRange.upperBound..<cEnd.lowerBound])
                }
                // 回退：尝试从 Data 格式的 configuration 解析（UTF-8 字节）
                if choiceConfiguration == nil {
                    if let dataRange = desc.range(of: "configuration: Optional("),
                       let bytesRange = desc[dataRange.upperBound...].range(of: "bytes = \""),
                       let endQuote = desc[bytesRange.upperBound...].range(of: "\")") {
                        let hexStr = String(desc[bytesRange.upperBound..<endQuote.lowerBound])
                        if let data = hexStr.data(using: .utf8), !data.isEmpty {
                            choiceConfiguration = String(data: data, encoding: .utf8)
                        }
                    }
                }
            }
        }

        // 回退：如果无法从 request 解析 configuration，使用命令文件设置的 currentVideoID
        if choiceConfiguration == nil || choiceConfiguration?.isEmpty == true {
            let fallbackID = WallpaperState.shared.currentVideoID
            if let fallbackID, !fallbackID.isEmpty {
                extLog("[acquire] ⚠️ choiceConfiguration 为 nil，回退使用 currentVideoID: \(fallbackID)")
                choiceConfiguration = fallbackID
            }
        }

        // Update current video ID from choice
        if let config = choiceConfiguration, !config.isEmpty {
            WallpaperState.shared.currentVideoID = config
        }

        // Create remote CAContext
        var contextOptions: [String: Any] = [:]
        if let did = displayID {
            contextOptions["displayId"] = did
        }
        let caContext: CAContext
        if contextOptions.isEmpty {
            guard let ctx = CAContext.remoteContext() as? CAContext else {
                reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
                return
            }
            caContext = ctx
        } else {
            let result = CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: contextOptions)?.takeUnretainedValue()
            guard let ctx = result as? CAContext else {
                reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
                return
            }
            caContext = ctx
        }
        guard caContext.contextId != 0 else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CAContext"]))
            return
        }

        let contextId = caContext.contextId

        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            reply(nil, NSError(domain: "WaifuXExtension", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create WallpaperRemoteContextXPC"]))
            return
        }

        nonisolated(unsafe) let unsafeReplyObj = replyObj
        let hasReplied = OSAllocatedUnfairLock(initialState: false)
        let doReply: @Sendable (String) -> Void = { source in
            let shouldReply = hasReplied.withLock { replied in
                if replied { return false }
                replied = true
                return true
            }
            if shouldReply {
                extLog("  Replying to acquire [\(source)] (contextId: \(contextId))")
                reply(unsafeReplyObj, nil)
            }
        }

        let layerFrame = CGRect(origin: .zero, size: destSize)
        let rootLayer = CALayer()
        rootLayer.frame = layerFrame
        rootLayer.contentsScale = scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill

        if let cachedImage = loadCachedSnapshotImage() {
            rootLayer.contents = cachedImage
            extLog("  Set cached snapshot as initial layer content")
        }

        let videoURL = findVideoURL(videoID: choiceConfiguration)

        if let videoURL {
            extLog("  Setting up VideoRenderer with: \(videoURL.lastPathComponent) (videoID: \(choiceConfiguration ?? "default"))")
            caContext.layer = rootLayer
            CATransaction.flush()

            nonisolated(unsafe) let unsafeCAContext = caContext
            nonisolated(unsafe) let unsafeRootLayer = rootLayer

            Task {
                let videoRenderer: VideoRenderer
                do {
                    videoRenderer = try await VideoRenderer.create(
                        rootLayer: unsafeRootLayer, videoURL: videoURL
                    )
                } catch {
                    extLog("  [Renderer] Failed to create: \(error)")
                    doReply("renderer failed")
                    return
                }

                let existing = WallpaperState.shared.storeContext(
                    ActiveWallpaper(caContext: unsafeCAContext, rootLayer: unsafeRootLayer, renderer: videoRenderer, displayID: displayID, videoID: choiceConfiguration),
                    id: contextId,
                    wallpaperID: wallpaperIDString
                )
                if let existing {
                    existing.renderer?.stop()
                    extLog("  Stopped existing renderer for wallpaperID: \(wallpaperIDString ?? "?")")
                }
                WallpaperPrefs.shared.setActive(true)

                videoRenderer.start()
                extLog("  VideoRenderer started (reply deferred 500ms)")
                try? await Task.sleep(for: .milliseconds(500))
                doReply("pipeline ready")
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                doReply("timeout")
            }

            if !isPreview {
                let displayW = Int(destSize.width * scaleFactor)
                let displayH = Int(destSize.height * scaleFactor)
                let currentVideoID = WallpaperState.shared.currentVideoID
                Task {
                    await writeBMPSnapshot(videoURL: videoURL, videoID: currentVideoID, displayPixelWidth: displayW, displayPixelHeight: displayH)
                }
            }
        } else {
            extLog("  No video file found — using solid color fallback")
            let gradientLayer = CAGradientLayer()
            gradientLayer.colors = [
                CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1.0),
                CGColor(red: 0.0, green: 0.0, blue: 0.1, alpha: 1.0),
            ]
            gradientLayer.frame = layerFrame
            gradientLayer.contentsScale = scaleFactor
            rootLayer.addSublayer(gradientLayer)
            caContext.layer = rootLayer
            _ = WallpaperState.shared.storeContext(
                ActiveWallpaper(caContext: caContext, rootLayer: rootLayer, renderer: nil, displayID: displayID, videoID: choiceConfiguration),
                id: contextId,
                wallpaperID: wallpaperIDString
            )
            doReply("no video")
        }
    }

    func update(withId _: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        var presentationMode = "?"
        var activityState = "?"
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let innerValue = mirror.children.first?.value {
                let desc = String(describing: innerValue)
                if let modeRange = desc.range(of: "presentationMode: ") {
                    let afterMode = desc[modeRange.upperBound...]
                    if let endRange = afterMode.range(of: ",") ?? afterMode.range(of: ")") {
                        presentationMode = String(afterMode[..<endRange.lowerBound])
                    }
                }
                if let actRange = desc.range(of: "activityState: ") {
                    let afterAct = desc[actRange.upperBound...]
                    if let endRange = afterAct.range(of: ",") ?? afterAct.range(of: ")") {
                        activityState = String(afterAct[..<endRange.lowerBound])
                    }
                }
            }
        }

        WallpaperState.shared.presentationMode = presentationMode
        WallpaperState.shared.activityState = activityState

        if presentationMode == "locked" {
            WallpaperState.shared.isScreenLocked = true
        } else if presentationMode != "?" {
            WallpaperState.shared.isScreenLocked = false
        }

        let prefs = WallpaperPrefs.shared
        let basePolicy = PlaybackPolicy.compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: ProcessInfo.processInfo.thermalState,
            isOnBattery: false,
            batteryLevel: 100
        )

        let modeChanged = presentationMode != previousPresentationMode
        let animated = prefs.alwaysPauseDesktop && activityState == "active" && modeChanged

        // Per-display policy：检查每个显示器是否有独立的暂停设置
        WallpaperState.shared.forEachActiveContext { displayID, renderer in
            let isDisplayPaused = displayID.flatMap { prefs.isDisplayPaused($0) } ?? false
            let effectivePolicy: PlaybackPolicy = isDisplayPaused ? .paused : basePolicy
            renderer.applyPolicy(effectivePolicy, animated: animated)
        }

        previousPresentationMode = presentationMode
        extLog("=== UPDATE === mode: \(presentationMode), activity: \(activityState)")
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        var cleaned = false
        if let idObj = id as? NSObject {
            let idStr = String(describing: Mirror(reflecting: idObj).children.first?.value ?? "")
            if let range = idStr.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}", options: .regularExpression) {
                let uuid = String(idStr[range])
                if let active = WallpaperState.shared.removeContext(wallpaperID: uuid) {
                    active.renderer?.stop()
                    cleaned = true
                }
            }
        }
        let remaining = WallpaperState.shared.activeContextCount
        if remaining == 0 {
            WallpaperPrefs.shared.setActive(false)
        }
        extLog("=== INVALIDATE === (cleaned: \(cleaned), remaining: \(remaining))")
        reply(nil)
    }

    func snapshot(withId _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        extLog("=== SNAPSHOT ===")
        var currentTime: CMTime?
        WallpaperState.shared.forEachRenderer { renderer in
            currentTime = CMTimebaseGetTime(renderer.timebase)
        }
        Task {
            if let snapshotXPC = await createSnapshotViaRuntime(currentTime: currentTime) {
                // 验证 XPC 编码可行性：尝试 NSKeyedArchiver 测试编码
                let canEncode: Bool
                if #available(macOS 26.0, *) {
                    canEncode = (try? NSKeyedArchiver.archivedData(withRootObject: snapshotXPC, requiringSecureCoding: false)) != nil
                } else {
                    canEncode = true
                }
                if canEncode {
                    reply(snapshotXPC, nil)
                    extLog("  Snapshot replied (IOSurface)")
                } else {
                    // XPC 编码会失败（WallpaperSnapshotXPC 缺少 encodeWithCoder:），
                    // 返回 nil 防止 XPC 异常阻断壁纸系统
                    extLog("  ⚠️ Snapshot XPC encode would fail, replying nil to avoid XPC exception")
                    reply(nil, nil)
                }
            } else {
                reply(nil, nil)
                extLog("  Snapshot replied nil")
            }
        }
    }

    // MARK: - Prefs Change Monitoring

    /// 开始监听 App 部署新视频的 Darwin 通知，并通知系统刷新壁纸设置。
    /// 在 agentProxy 设置后调用。
    func startObservingPrefs() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let handler = Unmanaged<WallpaperXPCHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.handlePrefsChanged()
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
        extLog("[XPCHandler] 已注册 prefs 变化监听")
    }

    /// prefs 变化时：通知系统刷新壁纸设置，促使系统选中最新部署的视频
    private func handlePrefsChanged() {
        extLog("[XPCHandler] prefs 已变化，通知系统刷新壁纸设置...")

        // 先清除缓存，确保证 SettingsProvider 扫描到最新文件
        WallpaperState.shared.clearCaches()

        guard let proxy = agentProxy else {
            extLog("[XPCHandler] ⚠️ agentProxy 不可用，跳过刷新")
            return
        }

        nonisolated(unsafe) let unsafeProxy = proxy

        Task {
            // 构建最新的 SettingsViewModels（包含刚部署的视频）
            guard let viewModels = await buildSettingsViewModelsXPC() else {
                extLog("[XPCHandler] ⚠️ buildSettingsViewModelsXPC 返回 nil")
                return
            }

            // 通知系统刷新壁纸设置。系统收到后会重新调用 provideSettingsViewModels，
            // 从而看到最新部署的视频。
            unsafeProxy.updateSettingsViewModels(viewModels) { error in
                if let error {
                    extLog("[XPCHandler] ❌ updateSettingsViewModels 失败: \(error)")
                } else {
                    extLog("[XPCHandler] ✅ 已通知系统刷新壁纸设置")
                }
            }
        }
    }

    // MARK: - Stubs

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        Task {
            let result = await buildSettingsViewModelsXPC()
            reply(result ?? makeEmptyGroupsResponse(), nil)
        }
    }

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func selectedChoicesDidChange(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let identifier = (menuItemID as? String) ?? String(describing: menuItemID ?? "nil")
        extLog("=== CONTEXT MENU ACTION === identifier: \(identifier)")
        reply(nil)
    }

    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(true, nil)
    }

    func download(withChoiceID _: Any?, reply: ((any Error)?) -> Void) -> Any? {
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(false, nil)
    }

    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func handleNotification(withNamed _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - Helpers

    private func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
        guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
              let raw = class_createInstance(realClass, 0) else {
            extLog("  ERROR: Could not create WallpaperRemoteContextXPC")
            return nil
        }

        let obj = raw as AnyObject
        let ptr = Unmanaged.passUnretained(obj).toOpaque()
        let ivarOffset: Int = if let ivar = class_getInstanceVariable(realClass, "box") {
            ivar_getOffset(ivar)
        } else {
            8
        }
        ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
        extLog("  Created WallpaperRemoteContextXPC (contextId: \(contextId), offset: \(ivarOffset))")
        return obj
    }
}
