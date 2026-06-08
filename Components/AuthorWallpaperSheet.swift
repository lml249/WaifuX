import SwiftUI
import Kingfisher

// MARK: - 作者壁纸弹出层 - 液态玻璃底部弹窗
struct AuthorWallpaperSheet: View {
    let uploader: Wallpaper.Uploader
    let wallpapers: [Wallpaper]
    let isLoading: Bool
    let onSelectWallpaper: (Wallpaper) -> Void
    let onDismiss: () -> Void
    let onLoadMore: (() -> Void)?

    @State private var isVisible = false
    private let cardSpacing: CGFloat = 14
    private let cornerRadius: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = min(max(geometry.size.width * 0.72, 720), 1040)
            let panelHeight = min(max(geometry.size.height * 0.78, 620), 820)
            let bottomOffset = panelHeight + 40

            ZStack(alignment: .bottom) {
                // 半透明背景
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismiss()
                    }
                    .opacity(isVisible ? 1 : 0)

                // 底部弹窗面板
                VStack(spacing: 0) {
                    // 拖拽指示条
                    Capsule()
                        .fill(LiquidGlassColors.textQuaternary)
                        .frame(width: 36, height: 4)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    authorHeader
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 18)

                    dividerLine
                        .padding(.horizontal, 28)

                    HStack {
                        Text(t("authorWallpapers"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        }
                        if !wallpapers.isEmpty {
                            Text("\(wallpapers.count)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(LiquidGlassColors.textTertiary)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    wallpaperGrid(width: panelWidth)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: panelWidth, height: panelHeight)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                )
                .liquidGlassSurface(
                    .prominent,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .shadow(color: .black.opacity(0.35), radius: 48, y: -8)
                .offset(y: isVisible ? 0 : bottomOffset)
                .opacity(isVisible ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0)) {
                isVisible = true
            }
        }
    }

    // MARK: - 作者信息头部
    private var authorHeader: some View {
        HStack(spacing: 16) {
            authorAvatar
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                Text(uploader.username)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Label("wallhaven", systemImage: "photo.stack")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(LiquidGlassColors.glassTint)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 作者头像
    @ViewBuilder
    private var authorAvatar: some View {
        let avatarURL = selectBestAvatarURL()

        if let url = avatarURL {
            KFImage(url)
                .placeholder { _ in
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(LiquidGlassColors.borderSubtle, lineWidth: 1)
                )
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(LiquidGlassColors.glassTint)
                )
        }
    }

    // MARK: - 壁纸网格
    private func wallpaperGrid(width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if wallpapers.isEmpty && !isLoading {
                emptyState
            } else {
                let columnCount = max(2, min(4, Int(width / 240)))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: cardSpacing), count: columnCount),
                    spacing: cardSpacing
                ) {
                    ForEach(wallpapers) { wallpaper in
                        AuthorWallpaperCard(
                            wallpaper: wallpaper,
                            onTap: {
                                onSelectWallpaper(wallpaper)
                            }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)

                // 加载更多触发器
                if let onLoadMore = onLoadMore, !wallpapers.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            onLoadMore()
                        }
                }
            }

            // 底部安全区
            Color.clear
                .frame(height: 12)
        }
        .iosSmoothScroll()

    }

    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundStyle(LiquidGlassColors.textQuaternary)

            Text(t("noWallpapers"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 分隔线
    private var dividerLine: some View {
        Rectangle()
            .fill(LiquidGlassColors.borderSubtle)
            .frame(height: 1)
    }

    // MARK: - Helper
    private func selectBestAvatarURL() -> URL? {
        // 优先使用 200px，其次 128px，再次 32px
        let urls = [
            uploader.avatar.px200,
            uploader.avatar.px128,
            uploader.avatar.px32
        ]
        for urlString in urls {
            if let url = URL(string: urlString), !urlString.isEmpty {
                return url
            }
        }
        return nil
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85, blendDuration: 0)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - 作者壁纸卡片
private struct AuthorWallpaperCard: View {
    let wallpaper: Wallpaper
    let onTap: () -> Void

    @State private var isHovered = false
    private let cardCornerRadius: CGFloat = 14

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 壁纸封面
                KFImage(coverImageURL)
                    .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                    .backgroundDecode()
                    .cancelOnDisappear(true)
                    .placeholder { _ in
                        Rectangle()
                            .fill(.white.opacity(0.05))
                    }
                    .fade(duration: 0.15)
                    .resizable()
                    .scaledToFill()
                    .frame(height: cardImageHeight)
                    .clipped()

                // 底部信息
                HStack(spacing: 6) {
                    // 分类标签
                    if !wallpaper.category.isEmpty {
                        Text(wallpaper.categoryDisplayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.08))
                            )
                    }

                    Spacer(minLength: 0)

                    // 分辨率
                    if !wallpaper.resolution.isEmpty {
                        Text(wallpaper.resolution)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(isHovered ? .white.opacity(0.2) : .white.opacity(0.06), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .scaleEffect(isHovered ? 1.01 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovered)
        }
        .buttonStyle(.plain)
        .throttledHover(interval: 0.08) { hovering in
            isHovered = hovering
        }
    }

    /// 根据当前视图宽度自适应卡片图片高度
    private var cardImageHeight: CGFloat {
        120
    }

    private var coverImageURL: URL? {
        wallpaper.thumbURL ?? wallpaper.smallThumbURL ?? wallpaper.fullImageURL
    }

    private var targetImageSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: 240 * scale, height: cardImageHeight * scale)
    }
}
