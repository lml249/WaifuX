import SwiftUI
import WebKit

// MARK: - Steam Login WebView
/// 基于 WKWebView 的 Steam 登录视图
/// 打开 Steam OpenID 登录页面，用户登录后获取 Session Cookie
struct SteamLoginWebView: NSViewRepresentable {
    @Binding var isLoggedIn: Bool
    @Binding var steamID: String
    @Binding var isLoading: Bool
    var onLoginSuccess: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // 加载 Steam 登录页面
        let loginURL = URL(string: "https://steamcommunity.com/myworkshopfiles/?appid=431960&browsefilter=mysubscriptions")!
        webView.load(URLRequest(url: loginURL))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 更新逻辑（如需要）
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SteamLoginWebView
        private var hasDetectedLogin = false

        init(_ parent: SteamLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }

            // 检查当前 URL 是否包含订阅页面
            if let url = webView.url {
                let urlString = url.absoluteString

                // 检测是否在订阅页面（已登录状态）
                if urlString.contains("myworkshopfiles") && urlString.contains("browsefilter=mysubscriptions") {
                    // 尝试从页面提取 SteamID
                    webView.evaluateJavaScript("document.body.innerHTML") { result, error in
                        if let html = result as? String {
                            self.extractSteamIDFromPage(html, webView: webView)
                        }
                    }
                }

                // 检测 OpenID 回调
                if urlString.contains("openid.claimed_id") || urlString.contains("openid.identity") {
                    // 登录成功，提取 SteamID
                    self.extractSteamIDFromOpenID(url: url, webView: webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            print("[SteamLogin] Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            print("[SteamLogin] Provisional navigation failed: \(error.localizedDescription)")
        }

        // MARK: - SteamID Extraction

        private func extractSteamIDFromPage(_ html: String, webView: WKWebView) {
            // 从 HTML 中提取 SteamID
            // 常见模式：steamid="76561198000000000" 或 profile/steamid
            let patterns = [
                "steamid=\"(\\d{17})\"",
                "\"steamid\":\"(\\d{17})\"",
                "profile/(\\d{17})",
                "\"steamid64\":\"(\\d{17})\""
            ]

            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                    let steamID = String(html[Range(match.range(at: 1), in: html)!])
                    DispatchQueue.main.async {
                        self.parent.steamID = steamID
                        self.parent.isLoggedIn = true
                        self.parent.onLoginSuccess?(steamID)
                    }
                    return
                }
            }

            // 如果无法提取，尝试从 Cookie 获取
            extractSteamIDFromCookies(webView: webView)
        }

        private func extractSteamIDFromOpenID(url: URL, webView: WKWebView) {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let queryItems = components.queryItems {
                for item in queryItems {
                    if item.name == "openid.identity" || item.name == "openid.claimed_id" {
                        if let value = item.value {
                            // OpenID identity 格式：https://steamcommunity.com/openid/id/76561198000000000
                            let components = value.components(separatedBy: "/")
                            if let steamID = components.last, steamID.count == 17, steamID.allSatisfy(\.isNumber) {
                                DispatchQueue.main.async {
                                    self.parent.steamID = steamID
                                    self.parent.isLoggedIn = true
                                    self.parent.onLoginSuccess?(steamID)
                                }
                                return
                            }
                        }
                    }
                }
            }

            // 如果 OpenID 解析失败，尝试从页面提取
            webView.evaluateJavaScript("document.body.innerHTML") { result, error in
                if let html = result as? String {
                    self.extractSteamIDFromPage(html, webView: webView)
                }
            }
        }

        private func extractSteamIDFromCookies(webView: WKWebView) {
            // 从 WKWebsiteDataStore 获取 Cookie
            webView.configuration.websiteDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                for record in records {
                    if record.displayName.contains("steamcommunity") {
                        // 找到 Steam Cookie，但无法直接读取内容
                        // 需要通过 JavaScript 获取
                        webView.evaluateJavaScript("document.cookie") { result, error in
                            if let cookieString = result as? String {
                                // 解析 Cookie 中的 steamLoginSecure
                                let cookies = cookieString.components(separatedBy: "; ")
                                for cookie in cookies {
                                    if cookie.hasPrefix("steamLoginSecure=") {
                                        // 找到登录 Cookie，但需要 SteamID
                                        // 从页面再次提取
                                        webView.evaluateJavaScript("document.body.innerHTML") { htmlResult, _ in
                                            if let html = htmlResult as? String {
                                                self.extractSteamIDFromPage(html, webView: webView)
                                            }
                                        }
                                        return
                                    }
                                }
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - Steam Login Sheet
/// 包装 SteamLoginWebView 的 Sheet 视图
struct SteamLoginSheet: View {
    @Binding var isPresented: Bool
    @State private var isLoggedIn = false
    @State private var steamID = ""
    @State private var isLoading = false
    @State private var showingSyncSheet = false

    @EnvironmentObject var workshopSourceManager: WorkshopSourceManager

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("Steam 登录")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
                .background(Color.white.opacity(0.1))

            // WebView
            ZStack {
                SteamLoginWebView(
                    isLoggedIn: $isLoggedIn,
                    steamID: $steamID,
                    isLoading: $isLoading
                ) { id in
                    // 登录成功回调
                    workshopSourceManager.steamProfileID = id
                    workshopSourceManager.refreshStoredSteamCredentials()
                }

                if isLoading {
                    VStack {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在加载...")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.5))
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // 底部状态栏
            HStack {
                if isLoggedIn {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("已登录")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Button("同步订阅") {
                        isPresented = false
                        showingSyncSheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LiquidGlassColors.secondaryViolet)
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.orange)
                        Text("请在上方页面登录 Steam 账号")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingSyncSheet) {
            // 触发同步订阅
            // 这里需要通知父组件开始同步
        }
    }
}

// MARK: - Preview
#Preview {
    SteamLoginSheet(isPresented: .constant(true))
        .environmentObject(WorkshopSourceManager.shared)
}
