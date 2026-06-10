import AppKit
import Foundation

/// Backward-compatible facade for older call sites.
///
/// The previous implementation stored one "last wallpaper" per screen and rewrote it
/// on every Space switch. That conflicts with per-desktop slots, so this facade now
/// delegates to `SpaceWallpaperCoordinator` and only touches the current active Space.
@MainActor
final class DesktopWallpaperSyncManager {
    static let shared = DesktopWallpaperSyncManager()

    private init() {}

    func registerWallpaperSet(
        _ url: URL,
        for screen: NSScreen? = nil,
        options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
    ) {
        Task { @MainActor in
            do {
                try await SpaceWallpaperCoordinator.shared.registerAppliedWallpaper(
                    url,
                    for: screen,
                    options: options.isEmpty ? DesktopWallpaperDefaultOptions.fill : options,
                    runtimeState: .activeStatic
                )
            } catch {
                print("[DesktopWallpaperSyncManager] Failed to register wallpaper in slot store: \(error)")
            }
        }
    }

    func clearRegistration(for screen: NSScreen? = nil) {
        if let screen {
            let identification = SpaceWallpaperCoordinator.shared.identifyCurrentSpace(for: screen)
            guard let slotID = identification.slotID else { return }
            try? DesktopSlotStore.shared.clearPending(slotID: slotID, screenID: screen.wallpaperScreenIdentifier)
        } else {
            for screen in NSScreen.screens {
                clearRegistration(for: screen)
            }
        }
    }

    func syncOnAppActivation() {
        Task { @MainActor in
            await SpaceWallpaperCoordinator.shared.reconcileCurrentSpaces(source: "appActivation")
        }
    }
}
