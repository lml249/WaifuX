import SwiftUI

// MARK: - 猜你喜欢 ViewModel

@MainActor
final class GuessYouLikeViewModel: ObservableObject {
    @Published var isShowing: Bool = false
    @Published var items: [GuessYouLikeItem] = []
    @Published var dealingProgress: Double = 0.0 // 0.0 → 1.0

    private var hasPreloaded = false
    /// 预加载 Task 引用，避免 show() 重复发起网络请求
    private var preloadTask: Task<Void, Never>?

    /// 后台预加载推荐数据（不展示 UI），应在 App 启动后的适当时机调用一次
    func preload() {
        guard !hasPreloaded else { return }
        hasPreloaded = true

        preloadTask = Task { @MainActor in
            let recommendations = await GuessYouLikeService.shared.getRecommendations()
            guard !Task.isCancelled else { return }
            if !recommendations.isEmpty {
                items = recommendations
            }
            preloadTask = nil
        }
    }

    /// 强制刷新推荐数据（忽略缓存）
    func refreshInBackground() {
        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            let recommendations = await GuessYouLikeService.shared.forceRefresh()
            guard !Task.isCancelled else { return }
            if !recommendations.isEmpty {
                items = recommendations
            }
            preloadTask = nil
        }
    }

    func show() {
        dealingProgress = 0.0
        isShowing = true

        if items.isEmpty {
            // 无预加载数据 → 异步加载
            items = []
            let shouldAwaitPreload = preloadTask != nil

            Task { @MainActor in
                // 如果预加载 task 仍在执行，先等待它完成，避免重复请求
                if shouldAwaitPreload, let task = preloadTask {
                    _ = await task.value
                    // 预加载完成后 items 可能已非空
                    if !items.isEmpty {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        dealingProgress = 1.0
                        return
                    }
                }

                var recommendations = await GuessYouLikeService.shared.getRecommendations()
                if recommendations.isEmpty {
                    print("[GYL] Service returned empty, using fallback mock data")
                    recommendations = await GuessYouLikeService.shared.forceRefresh()
                }
                if recommendations.isEmpty {
                    print("[GYL] Still empty after retry, using mock data")
                    recommendations = GuessYouLikeItem.mockItems()
                }
                items = recommendations
                try? await Task.sleep(nanoseconds: 200_000_000)
                dealingProgress = 1.0
            }
        } else {
            // 已有预加载数据 → 直接发牌，用户无感知等待
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                dealingProgress = 1.0
            }
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.25)) {
            isShowing = false
            dealingProgress = 0.0
        }
    }

    /// 根据卡片索引获取延迟后的进度（用于顺序发牌）
    func dealingDelay(for index: Int) -> Double {
        Double(index) * 0.08
    }
}
