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
/// 预览内容本身在调用方先做高斯模糊，这里只负责叠加玻璃质感与锁定状态。
struct LockedFolderOverlay: View {
    /// 是否已解锁
    let isUnlocked: Bool
    /// 锁定图标大小
    var iconSize: CGFloat = 32

    var body: some View {
        if !isUnlocked {
            ZStack {
                NativeVisualEffectView(
                    material: .hudWindow,
                    blendingMode: .withinWindow,
                    state: .active
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.06),
                        Color.black.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)

                Rectangle()
                    .fill(Color.black.opacity(0.18))

                Image(systemName: "lock.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(iconSize * 0.55)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 4)
            }
        }
    }
}
