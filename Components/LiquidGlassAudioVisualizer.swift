import SwiftUI
import Combine

// MARK: - 液态玻璃音频可视化器
//
// 配合 SystemAudioCaptureService 使用，将频谱数据渲染为
// 漂亮的液态玻璃风格柱状图。
//
// ═══════════════════════════════════════════════════════════
// 视觉特征：
//   - 磨砂玻璃背景卡片
//   - 渐变色彩柱（从强调色渐变到高亮色）
//   - 圆角柱体 + 顶部发光
//   - 平滑升降动画（无闪烁）
//   - 可选镜面反射底部
//   - 支持 16/32/64 频段切换
//
// 性能优化：
//   - 使用 Canvas API 绘制（比单独 View 更高效）
//   - 平滑系数由 SystemAudioCaptureService 控制
//   - 仅在可见时订阅频谱数据
// ═══════════════════════════════════════════════════════════

public struct LiquidGlassAudioVisualizer: View {
    let config: AudioVisualizerConfig
    let spectrum: [Float]

    @State private var animatedSpectrum: [Float] = []

    public init(config: AudioVisualizerConfig, spectrum: [Float]) {
        self.config = config
        self.spectrum = spectrum
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            barsView
                .frame(height: config.barHeight)

            if config.showLabels {
                HStack {
                    Text("Hz")
                        .font(.system(size: 8, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Text("\(config.barCount) bands")
                        .font(.system(size: 8, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - 柱状图

    private var barsView: some View {
        Canvas { context, size in
            // swiftlint:disable implicit_return
            guard !spectrum.isEmpty else { return }

            let barCount = min(spectrum.count, config.barCount)
            let totalSpacing = CGFloat(barCount - 1) * config.barSpacing
            let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))
            let canvasHeight = size.height

            for i in 0..<barCount {
                let idx = min(i, spectrum.count - 1)
                let value = min(max(spectrum[idx], 0), 1)
                let barHeight = max(1, CGFloat(value) * canvasHeight * config.sensitivity)
                let x = CGFloat(i) * (barWidth + config.barSpacing)
                let y = canvasHeight - barHeight

                let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let bottomColor = config.barColor
                let topColor = config.highlightColor
                let cornerRadius = barWidth * config.cornerRadiusRatio
                let path = RoundedRectangle(cornerRadius: max(0.5, cornerRadius),
                                            style: .continuous).path(in: barRect)
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [bottomColor, topColor]),
                    startPoint: CGPoint(x: 0, y: canvasHeight),
                    endPoint: CGPoint(x: 0, y: 0)
                ))

                if config.showTopGlow && barHeight > 2 {
                    let glowHeight = min(4, barHeight * 0.15)
                    let glowRect = CGRect(x: x, y: y, width: barWidth, height: glowHeight)
                    let glowPath = RoundedRectangle(cornerRadius: max(0.5, cornerRadius),
                                                    style: .continuous).path(in: glowRect)
                    context.fill(glowPath, with: .color(.white.opacity(0.5)))
                }

                if config.showMirror && barHeight > 4 {
                    let mirrorHeight = barHeight * 0.3
                    let mirrorRect = CGRect(x: x, y: canvasHeight, width: barWidth, height: mirrorHeight)
                    let mirrorPath = RoundedRectangle(cornerRadius: max(0.5, cornerRadius),
                                                      style: .continuous).path(in: mirrorRect)
                    context.fill(mirrorPath, with: .linearGradient(
                        Gradient(colors: [bottomColor.opacity(0.2), .clear]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: mirrorHeight)
                    ))
                }
            }
        }
        .animation(config.animationEnabled
                   ? .interactiveSpring(response: 0.25, dampingFraction: 0.7)
                   : nil,
                   value: spectrum
        )
    }
}

// MARK: - 音频可视化配置

public struct AudioVisualizerConfig: Equatable {
    // MARK: - 频段
    /// 柱体数量（16/32/64）
    public var barCount: Int = 32
    /// 柱体高度（视图高度）
    public var barHeight: CGFloat = 48
    /// 柱体间距
    public var barSpacing: CGFloat = 2
    /// 灵敏度（0~2，默认 1.0）
    public var sensitivity: CGFloat = 1.2

    // MARK: - 视觉
    /// 柱体颜色（底部）
    public var barColor: Color = Color(hex: "8B5CF6")
    /// 高亮色（顶部）
    public var highlightColor: Color = Color(hex: "00D4FF")
    /// 圆角比例（0~0.5）
    public var cornerRadiusRatio: CGFloat = 0.35
    /// 显示顶部发光
    public var showTopGlow: Bool = true
    /// 显示镜面反射
    public var showMirror: Bool = false

    // MARK: - 动效
    /// 启用动画
    public var animationEnabled: Bool = true

    // MARK: - 标签
    /// 显示频段标签
    public var showLabels: Bool = false

    public init() {}
}

// MARK: - 预览

#Preview("柱状图 32 频段") {
    let mockSpectrum = (0..<32).map { i -> Float in
        let peak: Float = 0.3 + Float.random(in: 0...0.7)
        return peak * exp(-Float(i) / 12)
    }

    LiquidGlassAudioVisualizer(
        config: {
            var c = AudioVisualizerConfig()
            c.barCount = 32
            c.barHeight = 80
            c.barSpacing = 2.5
            c.sensitivity = 1.5
            c.barColor = Color(hex: "8B5CF6")
            c.highlightColor = Color(hex: "FF3366")
            return c
        }(),
        spectrum: mockSpectrum
    )
    .padding(20)
    .background(Color.black)
    .frame(width: 400, height: 150)
}
