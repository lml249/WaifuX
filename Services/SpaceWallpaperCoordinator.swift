import AppKit
import Foundation

enum DesktopWallpaperDefaultOptions {
    static var fill: [NSWorkspace.DesktopImageOptionKey: Any] {
        [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: NSNumber(value: true)
        ]
    }
}

enum DesktopSlotPendingClearPolicy {
    case none
    case matching(DesktopSlotPendingKind)
    case any

    var matchingKind: DesktopSlotPendingKind? {
        if case .matching(let kind) = self {
            return kind
        }
        return nil
    }

    var clearsAnyPending: Bool {
        if case .any = self {
            return true
        }
        return false
    }
}

struct SpaceWallpaperIdentification {
    let screenID: String
    let slotID: String?
    let matchedHistoricalToken: Bool
    let currentDesktopURL: URL?
}

@MainActor
final class SpaceWallpaperCoordinator {
    static let shared = SpaceWallpaperCoordinator()

    private struct ConfirmedActiveSlot {
        let slotID: String
        let generation: Int
    }

    private let store = DesktopSlotStore.shared
    private let workspace = NSWorkspace.shared
    private var lastConfirmedActiveSlotsByScreen: [String: ConfirmedActiveSlot] = [:]
    private var spaceGeneration = 0
    private var pendingIdentifyWorkItem: DispatchWorkItem?
    private var pendingScreenWorkItem: DispatchWorkItem?
    private var lastApplyTimeByScreen: [String: Date] = [:]

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func restore() {
        store.restoreSavedData()
        Task { @MainActor in
            await reconcileCurrentSpaces(source: "startup")
        }
    }

    func identifyCurrentSpace(for screen: NSScreen) -> SpaceWallpaperIdentification {
        let screenID = screen.wallpaperScreenIdentifier
        let currentURL = workspace.desktopImageURL(for: screen)
        guard let currentURL, currentURL.isFileURL else {
            return SpaceWallpaperIdentification(
                screenID: screenID,
                slotID: nil,
                matchedHistoricalToken: false,
                currentDesktopURL: currentURL
            )
        }

        let path = store.normalizedPath(for: currentURL)
        guard let match = store.matchTokenPath(path, screenID: screenID) else {
            return SpaceWallpaperIdentification(
                screenID: screenID,
                slotID: nil,
                matchedHistoricalToken: false,
                currentDesktopURL: currentURL
            )
        }

        rememberActiveSlot(match.slotID, for: screenID)
        return SpaceWallpaperIdentification(
            screenID: screenID,
            slotID: match.slotID,
            matchedHistoricalToken: !match.isCurrent,
            currentDesktopURL: currentURL
        )
    }

    func setStaticWallpaper(
        _ sourceURL: URL,
        option: WallpaperOption = .desktop,
        targetScreen: NSScreen?,
        preferredSlotID: String? = nil,
        pendingKind: DesktopSlotPendingKind = .pendingUserSet,
        pendingClearPolicy: DesktopSlotPendingClearPolicy = .any,
        options: [NSWorkspace.DesktopImageOptionKey: Any] = DesktopWallpaperDefaultOptions.fill
    ) async throws {
        let targetScreens = targetScreen.map { [$0] } ?? NSScreen.screens
        let slotOptions = DesktopSlotImageOptions(workspaceOptions: options)

        for screen in targetScreens {
            let slotID: String
            if let preferredSlotID {
                slotID = preferredSlotID
            } else {
                slotID = try slotIDForCurrentWrite(on: screen)
            }
            guard !slotID.isEmpty else { continue }
            let current = identifyCurrentSpace(for: screen)
            let screenID = screen.wallpaperScreenIdentifier
            let rememberedSlotID = rememberedActiveSlotID(for: screenID)
            let canTreatAsCurrent = current.slotID == slotID
                || rememberedSlotID == slotID
                || (preferredSlotID == nil && current.slotID == nil && !store.hasAnyBoundToken(for: screenID))
            if canTreatAsCurrent {
                try await bindAndApplyStaticWallpaper(
                    sourceURL,
                    slotID: slotID,
                    screen: screen,
                    options: slotOptions,
                    pendingClearPolicy: pendingClearPolicy
                )
            } else {
                try await store.setPending(
                    kind: pendingKind,
                    sourceURL: sourceURL,
                    slotID: slotID,
                    screen: screen,
                    options: slotOptions
                )
            }
        }
    }

    func setSchedulerStaticWallpaper(
        _ sourceURL: URL,
        to screen: NSScreen,
        options: [NSWorkspace.DesktopImageOptionKey: Any] = DesktopWallpaperDefaultOptions.fill
    ) async throws {
        let current = identifyCurrentSpace(for: screen)
        guard let slotID = current.slotID else {
            guard let fallbackSlotID = currentActiveSlotID(for: screen) else {
                print("[SpaceWallpaperCoordinator] Scheduler skipped \(screen.localizedName): current Space is not bound")
                return
            }
            try await store.setPending(
                kind: .pendingSchedulerSet,
                sourceURL: sourceURL,
                slotID: fallbackSlotID,
                screen: screen,
                options: DesktopSlotImageOptions(workspaceOptions: options)
            )
            return
        }

        let entry = store.entry(slotID: slotID, for: screen)
        if entry.pendingAction?.kind == .pendingUserSet {
            print("[SpaceWallpaperCoordinator] Scheduler skipped \(entry.screenID): user pending action exists")
            return
        }

        try await bindAndApplyStaticWallpaper(
            sourceURL,
            slotID: slotID,
            screen: screen,
            options: DesktopSlotImageOptions(workspaceOptions: options),
            pendingClearPolicy: .matching(.pendingSchedulerSet)
        )
    }

    func registerAppliedWallpaper(
        _ sourceURL: URL,
        for screen: NSScreen?,
        preferredSlotID: String? = nil,
        pendingKind: DesktopSlotPendingKind = .pendingUserSet,
        options: [NSWorkspace.DesktopImageOptionKey: Any] = DesktopWallpaperDefaultOptions.fill,
        runtimeState: DesktopSlotRuntimeState = .activeStatic,
        pendingClearPolicy: DesktopSlotPendingClearPolicy = .none
    ) async throws {
        let screens = screen.map { [$0] } ?? NSScreen.screens
        for target in screens {
            let slotID: String
            if let preferredSlotID {
                slotID = preferredSlotID
            } else {
                slotID = try slotIDForCurrentWrite(on: target)
            }

            let current = identifyCurrentSpace(for: target)
            let screenID = target.wallpaperScreenIdentifier
            let rememberedSlotID = rememberedActiveSlotID(for: screenID)
            let canTreatAsCurrent = current.slotID == slotID
                || rememberedSlotID == slotID
                || (preferredSlotID == nil && current.slotID == nil && !store.hasAnyBoundToken(for: screenID))

            if canTreatAsCurrent {
                try await bindAndApplyTokenOnly(
                    sourceURL,
                    slotID: slotID,
                    screen: target,
                    options: DesktopSlotImageOptions(workspaceOptions: options),
                    runtimeState: runtimeState,
                    pendingClearPolicy: pendingClearPolicy
                )
            } else {
                try await store.setPending(
                    kind: pendingKind,
                    sourceURL: sourceURL,
                    slotID: slotID,
                    screen: target,
                    options: DesktopSlotImageOptions(workspaceOptions: options)
                )
            }
        }
    }

    func resolvedCurrentSlotID(for screen: NSScreen) -> String? {
        currentActiveSlotID(for: screen)
    }

    func writableSlotIDForCurrentSpace(on screen: NSScreen) throws -> String {
        try slotIDForCurrentWrite(on: screen)
    }

    func schedulerSlotIDIfAllowed(for screen: NSScreen) -> String? {
        guard let slotID = currentActiveSlotID(for: screen) else { return nil }
        let entry = store.entry(slotID: slotID, for: screen)
        if entry.pendingAction?.kind == .pendingUserSet {
            print("[SpaceWallpaperCoordinator] Scheduler skipped \(entry.screenID): user pending action exists")
            return nil
        }
        return slotID
    }

    func registerAppliedFileWallpaperSynchronously(
        _ sourceURL: URL,
        for screen: NSScreen,
        preferredSlotID: String? = nil,
        options: [NSWorkspace.DesktopImageOptionKey: Any] = DesktopWallpaperDefaultOptions.fill,
        runtimeState: DesktopSlotRuntimeState = .activeStatic,
        pendingClearPolicy: DesktopSlotPendingClearPolicy = .none
    ) throws {
        let slotID = try preferredSlotID ?? slotIDForCurrentWrite(on: screen)
        let current = identifyCurrentSpace(for: screen)
        let screenID = screen.wallpaperScreenIdentifier
        let rememberedSlotID = rememberedActiveSlotID(for: screenID)
        let canTreatAsCurrent = current.slotID == slotID
            || rememberedSlotID == slotID
            || (preferredSlotID == nil && current.slotID == nil && !store.hasAnyBoundToken(for: screenID))

        guard canTreatAsCurrent else {
            throw DesktopSlotStoreError.cannotIdentifyCurrentSpace
        }

        let slotOptions = DesktopSlotImageOptions(workspaceOptions: options)
        let tokenURL = try store.createFileToken(sourceURL, slotID: slotID, screen: screen)
        try applyTokenToCurrentSpace(tokenURL, screen: screen, options: slotOptions)
        rememberActiveSlot(slotID, for: screenID)
        try store.markApplied(
            tokenURL: tokenURL,
            slotID: slotID,
            screen: screen,
            options: slotOptions,
            runtimeState: runtimeState,
            sourcePath: store.normalizedPath(for: sourceURL),
            clearsPendingKind: pendingClearPolicy.matchingKind,
            clearsAnyPending: pendingClearPolicy.clearsAnyPending
        )
    }

    func bindCurrentDesktop(slotID: String, screen: NSScreen, applyPendingIfAvailable: Bool) async throws {
        _ = try store.ensureEntry(slotID: slotID, for: screen)

        if applyPendingIfAvailable,
           let pending = store.pendingAction(slotID: slotID, screenID: screen.wallpaperScreenIdentifier) {
            try await applyPendingAction(pending, slotID: slotID, screen: screen)
            return
        }

        guard let currentURL = workspace.desktopImageURL(for: screen),
              currentURL.isFileURL,
              FileManager.default.isReadableFile(atPath: currentURL.path) else {
            throw DesktopSlotStoreError.cannotBindWithoutReadableImage
        }

        try await bindAndApplyStaticWallpaper(
            currentURL,
            slotID: slotID,
            screen: screen,
            options: DesktopSlotImageOptions(workspaceOptions: DesktopWallpaperDefaultOptions.fill),
            pendingClearPolicy: .none
        )
    }

    func applySavedWallpaper(slotID: String, screen: NSScreen) async throws {
        let entry = store.entry(slotID: slotID, for: screen)
        guard let tokenPath = entry.currentTokenPath else {
            throw DesktopSlotStoreError.missingSavedToken
        }
        guard FileManager.default.fileExists(atPath: tokenPath) else {
            throw DesktopSlotStoreError.unreadableSource(URL(fileURLWithPath: tokenPath))
        }

        let tokenURL = URL(fileURLWithPath: tokenPath)
        let options = DesktopSlotImageOptions(workspaceOptions: DesktopWallpaperDefaultOptions.fill)
        try applyTokenToCurrentSpace(tokenURL, screen: screen, options: options)
        try verifyOrForceRefresh(tokenURL, screen: screen, options: options)
        rememberActiveSlot(slotID, for: screen.wallpaperScreenIdentifier)
        try store.setRuntime(entry.runtimeState == .activeDynamic ? .activeDynamic : .activeStatic, slotID: slotID, screenID: screen.wallpaperScreenIdentifier)
    }

    func applyPendingIfCurrent(slotID: String, screen: NSScreen) async throws {
        guard let pending = store.pendingAction(slotID: slotID, screenID: screen.wallpaperScreenIdentifier) else {
            throw DesktopSlotStoreError.missingPendingAction
        }
        try await applyPendingAction(pending, slotID: slotID, screen: screen)
    }

    func reconcileCurrentSpaces(source: String) async {
        do {
            try store.relinkDisplayEntriesForCurrentScreens()
        } catch {
            print("[SpaceWallpaperCoordinator] relink failed from \(source): \(error)")
        }

        let generation = spaceGeneration
        var active: [(slotID: String, screenID: String)] = []
        for screen in NSScreen.screens {
            guard generation == spaceGeneration else { return }
            let identification = identifyCurrentSpace(for: screen)
            guard let slotID = identification.slotID else {
                if source == "appActivation",
                   let lastSlotID = currentActiveSlotID(for: screen) {
                    do {
                        try store.markLostBinding(slotID: lastSlotID, screenID: screen.wallpaperScreenIdentifier)
                    } catch {
                        print("[SpaceWallpaperCoordinator] mark lostBinding failed: \(error)")
                    }
                }
                continue
            }

            active.append((slotID: slotID, screenID: screen.wallpaperScreenIdentifier))
            do {
                let entry = store.entry(slotID: slotID, for: screen)
                let runtimeState: DesktopSlotRuntimeState = entry.runtimeState == .activeDynamic ? .activeDynamic : .activeStatic
                try store.setRuntime(runtimeState, slotID: slotID, screenID: screen.wallpaperScreenIdentifier)
                if shouldMutateDesktopDuringReconcile(source: source) {
                    try await repairOrApplyPendingIfNeeded(slotID: slotID, screen: screen, matchedHistorical: identification.matchedHistoricalToken)
                }
            } catch {
                print("[SpaceWallpaperCoordinator] reconcile failed for slot \(slotID), screen \(screen.localizedName): \(error)")
            }
        }

        do {
            try store.setAllRuntimeInactive(except: active)
        } catch {
            print("[SpaceWallpaperCoordinator] runtime cleanup failed: \(error)")
        }

        StaticWallpaperGrainManager.shared.updateOverlay()
    }

    private func shouldMutateDesktopDuringReconcile(source: String) -> Bool {
        switch source {
        case "startup", "appActivation":
            return false
        default:
            return true
        }
    }

    private func currentActiveSlotID(for screen: NSScreen) -> String? {
        let identification = identifyCurrentSpace(for: screen)
        if let slotID = identification.slotID {
            return slotID
        }
        let screenID = screen.wallpaperScreenIdentifier
        guard let confirmed = lastConfirmedActiveSlotsByScreen[screenID],
              confirmed.generation == spaceGeneration else {
            return nil
        }
        return confirmed.slotID
    }

    private func rememberedActiveSlotID(for screenID: String) -> String? {
        guard let confirmed = lastConfirmedActiveSlotsByScreen[screenID],
              confirmed.generation == spaceGeneration else {
            return nil
        }
        return confirmed.slotID
    }

    private func slotIDForCurrentWrite(on screen: NSScreen) throws -> String {
        if let slotID = currentActiveSlotID(for: screen) {
            return slotID
        }

        if store.slots.isEmpty {
            _ = try? store.createSlot(named: "桌面 1")
        }
        let screenID = screen.wallpaperScreenIdentifier
        if !store.hasAnyBoundToken(for: screenID),
           let defaultSlotID = store.slots.first?.id {
            return defaultSlotID
        }

        throw DesktopSlotStoreError.cannotIdentifyCurrentSpace
    }

    private func bindAndApplyStaticWallpaper(
        _ sourceURL: URL,
        slotID: String,
        screen: NSScreen,
        options: DesktopSlotImageOptions,
        pendingClearPolicy: DesktopSlotPendingClearPolicy
    ) async throws {
        let tokenURL = try await store.createToken(
            sourceURL,
            slotID: slotID,
            screen: screen
        )
        try applyTokenToCurrentSpace(tokenURL, screen: screen, options: options)
        try verifyOrForceRefresh(tokenURL, screen: screen, options: options)
        rememberActiveSlot(slotID, for: screen.wallpaperScreenIdentifier)
        try store.markApplied(
            tokenURL: tokenURL,
            slotID: slotID,
            screen: screen,
            options: options,
            runtimeState: .activeStatic,
            sourcePath: sourceURL.isFileURL ? store.normalizedPath(for: sourceURL) : sourceURL.absoluteString,
            clearsPendingKind: pendingClearPolicy.matchingKind,
            clearsAnyPending: pendingClearPolicy.clearsAnyPending
        )
    }

    private func bindAndApplyTokenOnly(
        _ sourceURL: URL,
        slotID: String,
        screen: NSScreen,
        options: DesktopSlotImageOptions,
        runtimeState: DesktopSlotRuntimeState,
        pendingClearPolicy: DesktopSlotPendingClearPolicy
    ) async throws {
        let tokenURL = try await store.createToken(
            sourceURL,
            slotID: slotID,
            screen: screen
        )
        try applyTokenToCurrentSpace(tokenURL, screen: screen, options: options)
        rememberActiveSlot(slotID, for: screen.wallpaperScreenIdentifier)
        try store.markApplied(
            tokenURL: tokenURL,
            slotID: slotID,
            screen: screen,
            options: options,
            runtimeState: runtimeState,
            sourcePath: sourceURL.isFileURL ? store.normalizedPath(for: sourceURL) : sourceURL.absoluteString,
            clearsPendingKind: pendingClearPolicy.matchingKind,
            clearsAnyPending: pendingClearPolicy.clearsAnyPending
        )
    }

    private func applyPendingAction(_ pending: DesktopSlotPendingAction, slotID: String, screen: NSScreen) async throws {
        let pendingURL = URL(fileURLWithPath: pending.assetPath)
        guard FileManager.default.fileExists(atPath: pendingURL.path) else {
            throw DesktopSlotStoreError.unreadableSource(pendingURL)
        }
        try await bindAndApplyStaticWallpaper(
            pendingURL,
            slotID: slotID,
            screen: screen,
            options: pending.options,
            pendingClearPolicy: .matching(pending.kind)
        )
    }

    private func repairOrApplyPendingIfNeeded(slotID: String, screen: NSScreen, matchedHistorical: Bool) async throws {
        let entry = store.entry(slotID: slotID, for: screen)
        if let pending = entry.pendingAction {
            try await applyPendingAction(pending, slotID: slotID, screen: screen)
            return
        }

        if matchedHistorical,
           let tokenPath = entry.currentTokenPath,
           FileManager.default.fileExists(atPath: tokenPath) {
            let tokenURL = URL(fileURLWithPath: tokenPath)
            try applyTokenToCurrentSpace(tokenURL, screen: screen, options: DesktopSlotImageOptions(workspaceOptions: DesktopWallpaperDefaultOptions.fill))
            return
        }
    }

    private func applyTokenToCurrentSpace(_ tokenURL: URL, screen: NSScreen, options: DesktopSlotImageOptions) throws {
        lastApplyTimeByScreen[screen.wallpaperScreenIdentifier] = Date()
        try workspace.setDesktopImageURL(tokenURL, for: screen, options: options.workspaceOptions)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.desktop"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func verifyOrForceRefresh(_ tokenURL: URL, screen: NSScreen, options: DesktopSlotImageOptions) throws {
        guard let currentURL = workspace.desktopImageURL(for: screen), currentURL.isFileURL else {
            return
        }
        let currentPath = store.normalizedPath(for: currentURL)
        let tokenPath = store.normalizedPath(for: tokenURL)
        guard currentPath != tokenPath else { return }

        if let neutralURL = makeNeutralRefreshImage(for: screen) {
            try? workspace.setDesktopImageURL(neutralURL, for: screen, options: options.workspaceOptions)
        }
        try workspace.setDesktopImageURL(tokenURL, for: screen, options: options.workspaceOptions)
    }

    private func makeNeutralRefreshImage(for screen: NSScreen) -> URL? {
        let url = store.rootDirectory
            .appendingPathComponent("Refresh", isDirectory: true)
            .appendingPathComponent("\(screen.wallpaperScreenIdentifier).jpg")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let size = NSSize(width: 16, height: 16)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                return nil
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[SpaceWallpaperCoordinator] Failed to create refresh image: \(error)")
            return nil
        }
    }

    private func rememberActiveSlot(_ slotID: String, for screenID: String) {
        lastConfirmedActiveSlotsByScreen[screenID] = ConfirmedActiveSlot(
            slotID: slotID,
            generation: spaceGeneration
        )
    }

    @objc private func handleActiveSpaceChanged() {
        spaceGeneration += 1
        pendingIdentifyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reconcileCurrentSpaces(source: "spaceChange")
            }
        }
        pendingIdentifyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    @objc private func handleScreenParametersChanged() {
        spaceGeneration += 1
        pendingScreenWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reconcileCurrentSpaces(source: "screenChange")
            }
        }
        pendingScreenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    @objc private func handleSystemDidWake() {
        Task { @MainActor in
            await reconcileCurrentSpaces(source: "systemWake")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reconcileCurrentSpaces(source: "systemWakeRetry")
            }
        }
    }

    @objc private func handleScreensDidWake() {
        Task { @MainActor in
            await reconcileCurrentSpaces(source: "screensWake")
        }
    }
}
