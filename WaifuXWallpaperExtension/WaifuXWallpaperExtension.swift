//  WaifuX Wallpaper Extension
//  基于 WallpaperExtensionKit 私有框架实现锁屏动态壁纸
//  仅在 macOS 26.0+ 生效

import AppKit
import ExtensionFoundation
import Foundation
import os

struct WallpaperExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extLog("XPC from PID=\(connection.processIdentifier)")

        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)

        // 构建 XPC 类型白名单（从运行时加载的 WallpaperExtensionKit 类）
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]

        let allTypes = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            } else {
                missing.append(name)
            }
        }
        if !missing.isEmpty {
            extLog("  MISSING types: \(missing.joined(separator: ", "))")
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>

        let selectors: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]

        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)

        let handler = WallpaperXPCHandler()
        connection.exportedObject = handler

        connection.interruptionHandler = { extLog("XPC interrupted") }
        connection.invalidationHandler = { [weak handler] in
            handler?.agentProxy = nil
            let removed = WallpaperState.shared.removeAllContexts()
            if !removed.isEmpty {
                WallpaperPrefs.shared.setActive(false)
                extLog("XPC invalidated — cleaned up \(removed.count) active context(s)")
            } else {
                extLog("XPC invalidated")
            }
        }

        connection.resume()

        handler.agentProxy = connection.remoteObjectProxy as? WallpaperExtensionProxyXPCProtocol

        // 注册 pref 变化监听：当 App 部署新视频时通知系统刷新壁纸设置
        handler.startObservingPrefs()

        extLog("XPC accepted with full protocol")
        return true
    }
}

@main
final class WaifuXWallpaperExtension: NSObject, AppExtension {
    typealias Configuration = WallpaperExtensionConfiguration

    var configuration: WallpaperExtensionConfiguration {
        WallpaperExtensionConfiguration()
    }

    override required init() {
        super.init()

        guard #available(macOS 26.0, *) else {
            extLog("INIT — macOS < 26, WallpaperExtensionKit disabled")
            return
        }

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            _ = handle
            extLog("INIT (PID: \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
            swizzleSnapshotEncodeIfNeeded()
            WallpaperPrefs.shared.observeChanges()
            observeLibraryChanges()
            observeCommands()
            observeDisplaySleepWake()
            observeScreenLockState()
        } else {
            let err = String(cString: dlerror())
            extLog("INIT — dlopen failed: \(err)")
        }
    }

    // MARK: - SnapshotXPC Swizzle

    private func swizzleSnapshotEncodeIfNeeded() {
        guard let snapshotClass = NSClassFromString("WallpaperSnapshotXPC") else { return }
        let sel = NSSelectorFromString("encodeWithCoder:")
        guard let origMethod = class_getInstanceMethod(snapshotClass, sel) else { return }
        let origIMP = method_getImplementation(origMethod)
        typealias EncodeFunc = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let origFunc = unsafeBitCast(origIMP, to: EncodeFunc.self)
        guard let nsxpcCoderClass = NSClassFromString("NSXPCCoder") else { return }

        let block: @convention(block) (AnyObject, NSCoder) -> Void = { obj, coder in
            let origClass: AnyClass = object_getClass(coder)!
            object_setClass(coder, nsxpcCoderClass)
            origFunc(obj, sel, coder)
            object_setClass(coder, origClass)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(origMethod, newIMP)
        extLog("  [Swizzle] Patched WallpaperSnapshotXPC encodeWithCoder:")
    }

    // MARK: - Display Sleep/Wake

    private func observeDisplaySleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = true
            WallpaperState.shared.forEachRenderer { $0.applyPolicy(.paused) }
            extLog("[Extension] Displays asleep — paused all renderers")
        }
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isDisplayAsleep = false
            Self.recomputeAndApplyPolicy()
            extLog("[Extension] Displays awake — recomputed policy")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Self.recomputeAndApplyPolicy()
            }
        }
    }

    // MARK: - Screen Lock

    private func observeScreenLockState() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = true
            extLog("[Extension] Screen locked")
        }
        dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in
            WallpaperState.shared.isScreenLocked = false
            Self.recomputeAndApplyPolicy()
            extLog("[Extension] Screen unlocked — recomputed policy")
        }
    }

    // MARK: - Library Changes

    private func observeLibraryChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                WallpaperState.shared.clearCaches()
                extLog("[Extension] Library changed — cleared caches")
            },
            "com.waifux.app.wallpaper.prefsChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Command IPC (App → Extension via shared container)

    /// 监听 App 写入的命令文件，实现可靠的 App → 扩展通信。
    /// App 在共享容器的 Commands/ 目录写入 JSON 文件，扩展定期扫描处理。
    /// 使用 Timer 轮询而非 DispatchSource，避免沙箱下 open() 被拦截的问题。
    private func observeCommands() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
            extLog("[Commands] ⚠️ 共享容器不可用，命令监听不可用")
            return
        }

        let cmdDir = container.appendingPathComponent("Commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: cmdDir, withIntermediateDirectories: true)

        // 每 1 秒轮询命令目录（开销极小，避免沙箱下 DispatchSource + open() 不可用）
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.processCommands(in: cmdDir)
        }

        extLog("[Commands] 命令目录轮询已启动: \(cmdDir.path)")

        // 立即处理可能积压的命令
        processCommands(in: cmdDir)
    }

    /// 扫描并处理 Commands 目录中的所有命令文件
    private func processCommands(in cmdDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cmdDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // 按修改时间排序，逐个处理
        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                     < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

        var parsedCommands: [(url: URL, action: String, command: [String: Any])] = []
        for fileURL in sorted {
            guard let data = try? Data(contentsOf: fileURL),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = cmd["action"] as? String else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            parsedCommands.append((fileURL, action, cmd))
        }

        guard !parsedCommands.isEmpty else { return }

        // setVideo is last-write-wins. Replaying stale video switches on startup can
        // trigger a storm of settings refreshes and renderer acquisitions.
        let setVideoCommands = parsedCommands.filter { $0.action == "setVideo" }
        if setVideoCommands.count > 1 {
            extLog("[Commands] 合并 \(setVideoCommands.count) 条积压 setVideo，仅处理最新一条")
        }

        let latestSetVideoURL = setVideoCommands.last?.url
        let commandsToProcess = parsedCommands.filter { item in
            item.action != "setVideo" || item.url == latestSetVideoURL
        }

        for item in commandsToProcess {
            let action = item.action
            extLog("[Commands] 处理命令: \(action)")

            switch action {
            case "setVideo":
                handleSetVideoCommand(item.command)
            default:
                extLog("[Commands] 未知命令: \(action)")
            }
        }

        // 处理后删除本轮扫描到的命令，包括被合并跳过的过期 setVideo。
        for item in parsedCommands {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    /// 处理设置壁纸命令
    private func handleSetVideoCommand(_ cmd: [String: Any]) {
        guard let videoID = cmd["videoID"] as? String else {
            extLog("[Commands] setVideo 缺少 videoID")
            return
        }

        extLog("[Commands] 切换到视频: \(videoID)")

        // 更新扩展状态（只更新 currentVideoID，不停止已有渲染器）
        // 系统负责每个显示器单独的 acquire/释放生命周期
        WallpaperState.shared.currentVideoID = videoID
        WallpaperState.shared.cachedVideoURL = nil
        WallpaperState.shared.clearCaches()

        let displayID = (cmd["displayID"] as? NSNumber)?.uint32Value ?? cmd["displayID"] as? UInt32
        if let videoURL = findVideoURL(videoID: videoID) {
            let switched = WallpaperState.shared.switchActiveRenderers(to: videoURL, displayID: displayID)
            if switched > 0 {
                extLog("[Commands] 已直接切换 \(switched) 个活跃 renderer 到视频: \(videoID)")
            } else {
                extLog("[Commands] 当前没有活跃 renderer，等待 WallpaperAgent acquire: \(videoID)")
            }
        } else {
            extLog("[Commands] ⚠️ 未找到命令指定的视频文件: \(videoID)")
        }

        // 通知 App 侧状态变化
        WallpaperPrefs.shared.setActive(true)

        // 发送 Darwin 通知，触发 XPCHandler.handlePrefsChanged() → updateSettingsViewModels
        // 这样系统会立即收到刷新信号，知晓新视频可用
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )

        extLog("[Commands] 视频切换完成: \(videoID)")
    }

    static func recomputeAndApplyPolicy() {
        let state = WallpaperState.shared
        let prefs = WallpaperPrefs.shared
        let effectiveMode = state.isScreenLocked && state.presentationMode != "locked"
            ? "locked"
            : state.presentationMode

        let policy = PlaybackPolicy.compute(
            presentationMode: effectiveMode,
            activityState: state.activityState,
            userPaused: prefs.userPaused,
            alwaysPauseDesktop: prefs.alwaysPauseDesktop,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: ProcessInfo.processInfo.thermalState,
            isOnBattery: false,
            batteryLevel: 100
        )
        WallpaperState.shared.forEachRenderer { renderer in
            renderer.applyPolicy(policy)
        }
    }
}

// MARK: - Logging

let extLogFileURL = URL(fileURLWithPath: "/tmp/waifux-extension.log")

func extLog(_ message: String) {
    if #available(macOS 11.0, *) {
        os_log("[WaifuXExt] %{public}@", log: .default, type: .info, message)
    } else {
        print("[WaifuXExt] \(message)")
    }
    // 也写入文件便于调试
    let line = "[\(Date())] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: extLogFileURL) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        try? handle.close()
    } else {
        try? line.write(to: extLogFileURL, atomically: true, encoding: .utf8)
    }
}
