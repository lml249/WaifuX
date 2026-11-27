import Foundation
import Kanna

// MARK: - XPath HTML 解析器

enum HTMLXPathParserError: Error, LocalizedError {
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let message):
            return message
        }
    }
}

class HTMLXPathParser {

    /// 使用 XPath 解析搜索结果
    static func parseSearchResults(
        html: String,
        searchList: String,
        searchName: String,
        searchResult: String,
        searchQuery: String? = nil
    ) throws -> [(name: String, src: String)] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw HTMLXPathParserError.parseFailed("无法解析 HTML")
        }

        var results: [(name: String, src: String)] = []

        // 无效标题列表（导航、页脚等常见非内容链接）
        let invalidTitles = ["首页", "主页", "home", "上一页", "下一页", "尾页", "关于我们", "联系我们", "帮助", "登录", "注册"]
        _ = ["/", "/index.html", "/index.php", "#", ""] // invalidPaths 保留供将来使用

        // 使用 searchList XPath 查找所有结果项
        let elements = doc.xpath(searchList)

        for element in elements {
            do {
                // 提取标题 - 使用在当前元素内查找的策略
                let name = extractTextFromElement(element, xpath: searchName)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""

                // 提取链接 (href 属性) - 使用在当前元素内查找的策略
                let src = extractHrefFromElement(element, xpath: searchResult) ?? ""

                // 过滤无效标题
                let lowerTitle = name.lowercased()
                if invalidTitles.contains(where: { lowerTitle == $0.lowercased() || lowerTitle.hasPrefix($0.lowercased()) }) {
                    print("[HTMLXPathParser] ⚠️ 跳过导航项: \(name)")
                    continue
                }

                // 规则侧 XPath 解析只依赖选择器，不做标题-关键词启发式过滤。
                
                // 过滤无效路径（只匹配完整的无效路径，不使用 hasSuffix 避免误判）
                let lowerSrc = src.lowercased()
                let invalidPaths = ["/", "/index.html", "/index.php", "#", ""]
                if invalidPaths.contains(lowerSrc) {
                    print("[HTMLXPathParser] ⚠️ 跳过无效链接: \(src) (标题: \(name))")
                    continue
                }
                
                // 额外检查：过滤常见的首页/导航链接（必须以 / 开头且没有路径深度）
                if lowerSrc == "/" || lowerSrc == "/index.html" || lowerSrc == "/index.php" {
                    print("[HTMLXPathParser] ⚠️ 跳过首页链接: \(src) (标题: \(name))")
                    continue
                }

                // 过滤纯锚点链接
                if src.hasPrefix("#") {
                    print("[HTMLXPathParser] ⚠️ 跳过锚点链接: \(src)")
                    continue
                }

                if !name.isEmpty && !src.isEmpty {
                    results.append((name: name, src: src))
                }
            }
        }

        return results
    }

    /// 检测验证码。
    static func detectCaptcha(
        html: String,
        captchaImageXPath: String?,
        captchaButtonXPath: String?
    ) -> Bool {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            return false
        }

        // 检查验证码图片
        if let imageXPath = captchaImageXPath, !imageXPath.isEmpty {
            if doc.xpath(imageXPath).first != nil {
                return true
            }
        }

        // 检查验证码按钮
        if let buttonXPath = captchaButtonXPath, !buttonXPath.isEmpty {
            if doc.xpath(buttonXPath).first != nil {
                return true
            }
        }

        return false
    }

    // MARK: - 辅助方法

    /// 从指定元素中提取文本内容
    /// 优先在 element 范围内查找，避免全局搜索
    private static func extractTextFromElement(_ element: Kanna.XMLElement, xpath: String) -> String? {
        // 策略1: 尝试作为相对路径在当前元素内查找
        let relativeXPath = makeRelativeXPath(xpath)
        if let node = element.xpath(relativeXPath).first {
            return node.text
        }
        
        // 策略2: 如果 xpath 指向属性（如 @href），需要特殊处理
        if xpath.contains("@") {
            return extractAttributeFromElement(element, xpath: xpath)
        }
        
        // 策略3: 尝试直接在当前元素内查找子节点
        if let node = element.at_xpath(relativeXPath) {
            return node.text
        }
        
        return nil
    }
    
    /// 从指定元素中提取 href 属性
    private static func extractHrefFromElement(_ element: Kanna.XMLElement, xpath: String) -> String? {
        // 如果 xpath 本身就是属性选择器
        if xpath.hasPrefix("@") {
            let attrName = String(xpath.dropFirst())
            return element[attrName]
        }
        
        // 查找目标元素然后获取 href
        let relativeXPath = makeRelativeXPath(xpath)
        if let node = element.xpath(relativeXPath).first {
            return node["href"]
        }
        
        return nil
    }
    
    /// 从 xpath 中提取属性值（如 "//a/@href" -> 提取 href）
    private static func extractAttributeFromElement(_ element: Kanna.XMLElement, xpath: String) -> String? {
        // 处理 //tag/@attr 格式
        if let range = xpath.range(of: "/@") {
            let tagPath = String(xpath[..<range.lowerBound])
            let attrName = String(xpath[range.upperBound...])
            let relativeTagPath = makeRelativeXPath(tagPath)
            if let node = element.xpath(relativeTagPath).first {
                return node[attrName]
            }
        }
        return nil
    }

    /// 将绝对 XPath 转换为相对 XPath
    /// 在 element.xpath() 中使用时，绝对路径（如 //div）会在整个文档中查找
    /// 而相对路径（如 .//div）才会在当前元素内部查找
    static func makeRelativeXPath(_ xpath: String) -> String {
        let trimmed = xpath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // 如果已经是相对路径，直接返回
        if trimmed.hasPrefix(".") {
            return trimmed
        }

        // 将 // 开头的 XPath 转换为 .// 开头的相对 XPath
        if trimmed.hasPrefix("//") {
            return "." + trimmed
        }

        // 其他情况（如绝对路径 /html/body/...）也转换为相对路径
        if trimmed.hasPrefix("/") {
            return "." + trimmed
        }

        return trimmed
    }
}
