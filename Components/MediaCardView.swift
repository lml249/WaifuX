import SwiftUI
import Kingfisher

// MARK: - SwiftUI 媒体卡片

struct MediaCardView: View {
    let media: MediaItem
    let isFavorite: Bool
    let cardWidth: CGFloat
    let onTap: (() -> Void)?

    @State private var animatedProbeResult: AnimatedProbeResult?
    @State private var isHovered = false

    private let bottomBarHeight: CGFloat = 44
    private let cornerRadius: CGFloat = 16
    private let maxAnimatedGIFBytes: Int64 = 32 * 1024 * 1024

    private var effectiveAspectRatio: CGFloat {
        let raw = media.exactResolution ?? media.resolutionLabel
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "X", with: "x")
        let parts = raw.split(separator: "x")
        if parts.count == 2,
           let w = Double(parts[0]), w > 0,
           let h = Double(parts[1]), h > 0 {
            let aspect = CGFloat(w / h)
            return min(max(aspect, 0.35), 3.6)
        }
        return 1.6
    }

    private var imageHeight: CGFloat {
        let maxImageHeight: CGFloat = cardWidth * 1.8
        return min(cardWidth / effectiveAspectRatio, maxImageHeight)
    }

    private var cardHeight: CGFloat {
        imageHeight + bottomBarHeight
    }

    private var staticDisplayURL: URL {
        media.coverImageURL
    }

    private var animatedDisplayURL: URL? {
        animatedProbeResult?.animatedURL
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                coverImage
                    .frame(width: cardWidth, height: imageHeight)
                    .task(id: media.id) {
                        animatedProbeResult = nil
                        let result = await probeAnimatedImage()
                        guard !Task.isCancelled else { return }
                        animatedProbeResult = result
                    }

                bottomBar
                    .frame(height: bottomBarHeight)
            }
            .background(Color(hex: "1C2431"))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(
                color: Color.black.opacity(isHovered ? 0.34 : 0.16),
                radius: isHovered ? 18 : 8,
                x: 0,
                y: isHovered ? 12 : 5
            )

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.white.opacity(isHovered ? 0.18 : 0.06),
                    lineWidth: isHovered ? 1.25 : 1
                )

            badgesView
                .padding(10)
        }
        .frame(width: cardWidth, height: cardHeight)
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
        .zIndex(isHovered ? 1 : 0)
        .onTapGesture { onTap?() }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            animatedProbeResult = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidReceiveMemoryPressure)) { _ in
            animatedProbeResult = nil
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let targetWidth = min(cardWidth * scale, 1600)
        let targetHeight = min(imageHeight * scale, 1600)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)

        Group {
            if let animatedDisplayURL {
                KFAnimatedImage.url(animatedDisplayURL)
                    .memoryCacheExpiration(.seconds(60))
                    .diskCacheExpiration(.days(3))
                    .fade(duration: 0.25)
                    .configure { view in
                        configureAnimatedGIFViewForAspectFill(view, autoPlay: true)
                    }
                    .placeholder { _ in Color.black.opacity(0.4) }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: imageHeight)
                    .clipped()
            } else {
                KFImage(staticDisplayURL)
                    .setProcessor(DownsamplingImageProcessor(size: targetSize))
                    .backgroundDecode()
                    .cacheMemoryOnly(false)
                    .memoryCacheExpiration(.seconds(300))
                    .fade(duration: 0.25)
                    .placeholder { _ in Color.black.opacity(0.4) }
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: imageHeight)
                    .clipped()
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(media.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isFavorite ? Color(hex: "FF5A7D") : .white.opacity(0.36))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.46))
    }

    @ViewBuilder
    private var badgesView: some View {
        HStack(alignment: .top) {
            let firstTag = media.primaryTagText
            if !firstTag.isEmpty {
                badgeText(firstTag)
            }

            Spacer()

            if !media.resolutionLabel.isEmpty {
                badgeText(media.resolutionLabel.replacingOccurrences(of: "x", with: "×"))
            }
        }
    }

    private func badgeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.4))
            .cornerRadius(11)
    }

    private struct AnimatedProbeResult: Equatable {
        let animatedURL: URL?
    }

    private func probeAnimatedImage() async -> AnimatedProbeResult {
        for url in animatedProbeCandidates {
            guard !Task.isCancelled else { return AnimatedProbeResult(animatedURL: nil) }
            if await AnimatedImageProbeCache.shared.isAnimatedGIF(url, maxByteCount: maxAnimatedGIFBytes) {
                return AnimatedProbeResult(animatedURL: url)
            }
        }
        return AnimatedProbeResult(animatedURL: nil)
    }

    private var animatedProbeCandidates: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        let candidates = [
            media.posterURLValue,
            Optional(media.thumbnailURLValue),
            Optional(media.coverImageURL)
        ]
        for optionalURL in candidates {
            guard let url = optionalURL else { continue }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

}
