import SwiftUI
import AppKit

// MARK: - NSVisualEffectView 包装（系统原生毛玻璃）

struct NativeVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

/// 文件夹加密锁定覆盖层
/// 当文件夹启用加密且未解锁时，使用系统原生 NSVisualEffectView 毛玻璃遮盖预览内容
struct LockedFolderOverlay: View {
    /// 是否已解锁
    let isUnlocked: Bool
    /// 锁定图标大小
    var iconSize: CGFloat = 32

    var body: some View {
        if !isUnlocked {
            ZStack {
                // 系统原生厚毛玻璃（使用最厚的 .ultraDark 材质）
                NativeVisualEffectView(
                    material: .ultraDark,
                    blendingMode: .behindWindow,
                    state: .active
                )

                // 深色遮罩增强遮盖效果
                Rectangle()
                    .fill(Color.black.opacity(0.35))

                // 锁定图标
                Image(systemName: "lock.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 3)
            }
        }
    }
}

/// 文件夹卡片的锁定状态指示器（小锁图标，用于非编辑模式）
struct FolderLockBadge: View {
    let isLocked: Bool
    let isUnlocked: Bool

    var body: some View {
        if isLocked {
            Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isUnlocked ? .green.opacity(0.8) : .white.opacity(0.8))
                .padding(6)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.45))
                )
        }
    }
}

// MARK: - 上下文菜单中的加密选项

extension View {
    /// 为文件夹卡片添加上下文菜单中的加密/解密选项
    @ViewBuilder
    func folderLockContextMenu(
        folder: LibraryFolder,
        isUnlocked: Bool,
        onToggleLock: @escaping () -> Void
    ) -> some View {
        contextMenu {
            Button {
                onToggleLock()
            } label: {
                if folder.isLocked {
                    Label("取消加密", systemImage: "lock.open")
                } else {
                    Label("加密文件夹", systemImage: "lock")
                }
            }

            // 原有的解散文件夹选项
            Button(role: .destructive) {
                // 由外部提供
            } label: {
                Label("解散文件夹", systemImage: "folder.badge.minus")
            }
        }
    }
}
