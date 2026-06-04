import Foundation

// MARK: - 壁纸动态文本解析器
//
// 从 scene.json 中提取文本对象，检测时钟/日期行为，输出 sidecar JSON。
// 替代旧 `lw_renderer_get_dynamic_texts_json()` C API 的纯 Swift 方案。
//
// ═══════════════════════════════════════════════════════════
// 使用场景：
//   烘焙完成后 → parseSceneJSON() → 检测是否有时钟/日期文本
//   → 有则写入 sidecar JSON → 播放时读取 → 决定是否显示 clock overlay
// ═══════════════════════════════════════════════════════════

public struct DynamicTextEntry: Codable, Equatable, Sendable {
    /// 时钟/日期行为类型
    public let behavior: String  // "clock" | "date" | "weekday" | "unknown"
    /// 文本对象名称（壁纸作者命名）
    public let name: String
    /// Lua 脚本（含 os.date / os.time 调用）
    public let script: String?
    /// 设计时文本值
    public let value: String?
    /// 是否可见
    public let visible: Bool
    /// 格式字符串，如 "hh"（时）、"mm"（分）、"ss"（秒）、"hh:mm"（完整时间）
    /// 从 text.scriptproperties.format 提取；nil 表示未知（回退到完整时间 "HH:mm"）
    public var format: String? = nil

    /// renderer sidecar 中的原始文本对象字段（用于按 Wallpaper Engine 场景坐标恢复 overlay）。
    public var id: String? = nil
    public var x: Double? = nil
    public var y: Double? = nil
    public var originX: Double? = nil
    public var originY: Double? = nil
    public var finalOriginX: Double? = nil
    public var finalOriginY: Double? = nil
    public var finalX: Double? = nil
    public var finalY: Double? = nil
    public var width: Double? = nil
    public var height: Double? = nil
    public var maxWidth: Double? = nil
    public var fontFamily: String? = nil
    public var fontPath: String? = nil
    public var fontSize: Double? = nil
    public var effectiveFontSize: Double? = nil
    public var color: [Double]? = nil
    public var alpha: Double? = nil
    public var rotation: Double? = nil
    public var finalAngle: Double? = nil
    public var scaleX: Double? = nil
    public var scaleY: Double? = nil
    public var finalScaleX: Double? = nil
    public var finalScaleY: Double? = nil
    public var alignment: String? = nil
    public var renderOrder: Int? = nil

    /// 返回仅修改 format 的新副本，保留所有其他字段
    func withFormat(_ newFormat: String?) -> DynamicTextEntry {
        var copy = self
        copy.format = newFormat
        return copy
    }
}

public struct WallpaperDynamicTextsInfo: Codable, Equatable, Sendable {
    /// 是否包含时钟/日期/星期行为
    public let hasDynamicText: Bool
    /// 具体行为列表
    public let entries: [DynamicTextEntry]
    /// renderer sidecar 的场景尺寸，用于将 scene 坐标映射到当前屏幕。
    public var sceneWidth: Double? = nil
    public var sceneHeight: Double? = nil
    /// 提取时间
    public let extractedAt: Date

    public static let empty = WallpaperDynamicTextsInfo(
        hasDynamicText: false,
        entries: [],
        extractedAt: Date()
    )
}

// MARK: - 解析器

public enum WallpaperDynamicTextParser {

    /// 从 scene.json 解析出动态文本信息
    public static func extract(from sceneJSON: URL) throws -> WallpaperDynamicTextsInfo {
        let data = try Data(contentsOf: sceneJSON)
        guard let scene = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return extract(from: scene)
    }

    /// 从 scene.pkg 中提取 scene.json 再解析
    public static func extract(fromPkg pkgURL: URL) throws -> WallpaperDynamicTextsInfo {
        let sceneData = try extractSceneJSONFromPkg(pkgURL)
        guard let scene = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            return .empty
        }
        return extract(from: scene)
    }

    /// 从已解析的 scene dict 中提取
    public static func extract(from scene: [String: Any]) -> WallpaperDynamicTextsInfo {
        guard let objects = scene["objects"] as? [[String: Any]] else {
            return .empty
        }

        var entries: [DynamicTextEntry] = []

        for obj in objects {
            // 检测文本对象：scene.json 可能用 "text"（旧格式）或 "textProperties"（新格式）
            // 且不一定有明确的 "type": "text" 字段
            let textObj: [String: Any]?
            if let tp = obj["textProperties"] as? [String: Any] {
                textObj = tp
            } else if let t = obj["text"] as? [String: Any] {
                textObj = t
            } else if let type = obj["type"] as? String, type.lowercased() == "text",
                      let tp = obj["textProperties"] as? [String: Any] {
                textObj = tp
            } else {
                textObj = nil
            }
            guard let tp = textObj else { continue }

            let name = (obj["name"] as? String) ?? ""
            let script = tp["script"] as? String
            let value = tp["value"] as? String
            let visible = (obj["visible"] as? Bool) ?? true

            // 提取格式：scriptproperties / scriptProperties 中的 format 字段
            let format: String?
            if let sp = tp["scriptproperties"] as? [String: Any],
               let f = sp["format"] as? String {
                format = f
            } else if let sp = tp["scriptProperties"] as? [String: Any],
                      let f = sp["format"] as? String {
                format = f
            } else {
                format = nil
            }

            let behavior = detectBehavior(name: name, script: script, format: format)
            // 不再过滤 "unknown" 行为：所有可见文本对象都应保留到 overlay 中，
            // 即使无法检测行为类型。renderedText 的 default 分支会显示原始 value。
            entries.append(DynamicTextEntry(
                behavior: behavior,
                name: name,
                script: script,
                value: value,
                visible: visible,
                format: format
            ))
        }

        return WallpaperDynamicTextsInfo(
            hasDynamicText: !entries.isEmpty,
            entries: entries,
            extractedAt: Date()
        )
    }

    // MARK: - 行为检测

    /// 与 web 模板 detectBehavior() 一致的逻辑
    /// - Parameters:
    ///   - format: 从 text.scriptproperties.format 提取的显式格式字符串（如 "hh"、"mm"、"dd"）
    private static func detectBehavior(name: String, script: String?, format: String? = nil) -> String {
        // 优先使用显式 format 字段判断
        // Wallpaper Engine 格式约定：hh/h=小时, mm/m=分钟, ss/s=秒, dd/d=日,
        // MM/M=月份(大写), yyyy/yy=年, EEEE/EEE=星期(大写)
        if let fmt = format {
            let lower = fmt.lowercased()

            // 星期标记
            if fmt.contains("EEEE") || fmt.contains("EEE") || fmt == "E" { return "weekday" }

            // 年标记
            if lower.contains("yyyy") || lower.contains("yy") { return "date" }

            // 月标记（原始大写 MM）
            if fmt.contains("MMMM") || fmt.contains("MMM") || fmt == "MM" { return "date" }

            // 日标记
            if lower.contains("dd") || lower == "d" { return "date" }

            // 时间标记（小写 hh/h/mm/m/ss/s）
            if lower.contains("hh") || lower == "h" { return "clock" }
            if lower.contains("mm") || lower == "m" { return "clock" }
            if lower.contains("ss") || lower == "s" { return "clock" }
        }

        let lowerName = name.lowercased().replacingOccurrences(of: " ", with: "")
        let lowerScript = (script ?? "").lowercased()

        // 时钟：script 含 hour/minute/second 或名称暗示（支持中文）
        let isClock = lowerScript.contains("hour") || lowerScript.contains("minute")
            || lowerScript.contains("second")
            || lowerScript.contains("%h") || lowerScript.contains("%m") || lowerScript.contains("%s")
            || lowerScript.contains("gethours") || lowerScript.contains("getminutes") || lowerScript.contains("getseconds")
            || lowerScript.contains("os.time") || lowerScript.contains("os.date")
            || lowerName.contains("clock") || lowerName.contains("time")
            // 中文名称匹配：时钟/时间/时/分钟/分钟/秒钟/秒
            || lowerName.contains("时钟") || lowerName.contains("时间") || lowerName == "时"
            || lowerName.contains("分钟") || lowerName.contains("分秒")
            || lowerName.contains("秒钟") || lowerName == "秒"
        if isClock { return "clock" }

        // 时段（AM/PM 指示器，如"下午"、"凌晨"）
        if lowerName.contains("时段") || lowerName.contains("ampm") {
            return "period"
        }

        // 星期优先于日期（支持中文）
        if lowerName == "day" || lowerName.contains("weekday") || lowerName.contains("week")
            || lowerName.contains("星期") || lowerName == "周" {
            return "weekday"
        }
        if lowerName.contains("day") && !lowerName.contains("date") {
            return "weekday"
        }
        if lowerName.contains("date") || lowerName.contains("日期") {
            return "date"
        }

        // script fallback
        let hasWeekday = lowerScript.contains("%a") || lowerScript.contains("%w")
            || (lowerScript.contains("getday") && !lowerScript.contains("getdate"))
        let hasDate = lowerScript.contains("%e") || lowerScript.contains("%d")
            || lowerScript.contains("%b") || lowerScript.contains("%m")
            || lowerScript.contains("getdate") || lowerScript.contains("getmonth") || lowerScript.contains("getfullyear")

        if hasWeekday && !hasDate { return "weekday" }
        if hasDate { return "date" }

        return "unknown"
    }

    // MARK: - Sidecar 文件管理

    /// Sidecar JSON 路径约定：与 MP4 同目录同名 .json
    public static func sidecarPath(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("json")
    }

    /// 保存 sidecar JSON
    public static func saveSidecar(_ info: WallpaperDynamicTextsInfo, for videoURL: URL) throws {
        let url = sidecarPath(for: videoURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        try data.write(to: url)
    }

    /// 读取 sidecar JSON
    public static func loadSidecar(for videoURL: URL) -> WallpaperDynamicTextsInfo? {
        let url = sidecarPath(for: videoURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }

        if let info = try? JSONDecoder().decode(WallpaperDynamicTextsInfo.self, from: data) {
            return info
        }

        return loadLegacyRendererSidecar(from: data)
    }

    /// 是否有 sidecar JSON 且包含动态文本
    public static func hasDynamicText(for videoURL: URL) -> Bool {
        guard let info = loadSidecar(for: videoURL) else { return false }
        return info.hasDynamicText
    }
}

// MARK: - Legacy Renderer Sidecar Compatibility

private extension WallpaperDynamicTextParser {

    /// 兼容 `wallpaperengine-cli` / renderer 直接写出的动态文本 JSON。
    ///
    /// App 自己写出的 sidecar 是 `WallpaperDynamicTextsInfo`；旧 CLI 路径会把
    /// `lw_renderer_get_dynamic_texts_json()` 的原始 JSON 写到同名 `.json`，常见形态为
    /// `{ "texts": [...] }` 或直接 `[...]`。如果这里不兜底，`shouldShowClock()` 会把
    /// 有动态文本的烘焙视频误判为 false，从而不创建桌面时钟窗口。
    static func loadLegacyRendererSidecar(from data: Data) -> WallpaperDynamicTextsInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let textObjects: [[String: Any]]
        let isRendererDynamicTextList: Bool
        let sceneWidth: Double?
        let sceneHeight: Double?
        if let dict = json as? [String: Any] {
            sceneWidth = legacyDouble(dict["sceneWidth"])
            sceneHeight = legacyDouble(dict["sceneHeight"])
            if let explicitHasDynamicText = dict["hasDynamicText"] as? Bool {
                return WallpaperDynamicTextsInfo(
                    hasDynamicText: explicitHasDynamicText,
                    entries: legacyEntries(from: dict["entries"] ?? dict["texts"] ?? dict["dynamicTexts"]),
                    sceneWidth: sceneWidth,
                    sceneHeight: sceneHeight,
                    extractedAt: Date()
                )
            }

            isRendererDynamicTextList = dict["texts"] != nil || dict["dynamicTexts"] != nil
            textObjects = legacyTextObjects(from: dict["texts"] ?? dict["dynamicTexts"] ?? dict["objects"])
        } else {
            sceneWidth = nil
            sceneHeight = nil
            isRendererDynamicTextList = true
            textObjects = legacyTextObjects(from: json)
        }

        let entries = textObjects.compactMap(legacyEntry(from:))
        // 后处理：对同名的 clock 条目推断格式（hh/mm/ss）
        let inferredEntries = inferLegacyClockFormats(entries: entries)
        return WallpaperDynamicTextsInfo(
            hasDynamicText: !inferredEntries.isEmpty || (isRendererDynamicTextList && !textObjects.isEmpty),
            entries: inferredEntries,
            sceneWidth: sceneWidth,
            sceneHeight: sceneHeight,
            extractedAt: Date()
        )
    }

    static func legacyTextObjects(from value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    static func legacyEntries(from value: Any?) -> [DynamicTextEntry] {
        legacyTextObjects(from: value).compactMap(legacyEntry(from:))
    }

    static func legacyEntry(from object: [String: Any]) -> DynamicTextEntry? {
        let behavior = legacyBehavior(from: object)
        // 注意：不再过滤 "unknown" 行为。即使行为未知，只要 renderer 输出了该对象
        //（有位置/颜色/字体信息），就应该在 overlay 中保留其位置占位。
        // 对于 "unknown" 条目，renderedText 的 default 分支会显示原始 value。

        // 从 scriptproperties 提取 format
        let format: String?
        if let sp = object["scriptproperties"] as? [String: Any],
           let f = legacyString(sp["format"]) {
            format = f
        } else if let sp = object["scriptProperties"] as? [String: Any],
                  let f = legacyString(sp["format"]) {
            format = f
        } else {
            format = nil
        }

        var entry = DynamicTextEntry(
            behavior: behavior,
            name: legacyString(object["name"] ?? object["id"]) ?? "",
            script: legacyString(object["script"]),
            value: legacyString(object["value"] ?? object["text"]),
            visible: legacyBool(object["visible"]) ?? true,
            format: format
        )
        entry.id = legacyString(object["id"])
        entry.x = legacyDouble(object["x"])
        entry.y = legacyDouble(object["y"])
        entry.originX = legacyDouble(object["originX"])
        entry.originY = legacyDouble(object["originY"])
        entry.finalOriginX = legacyDouble(object["finalOriginX"])
        entry.finalOriginY = legacyDouble(object["finalOriginY"])
        entry.finalX = legacyDouble(object["finalX"])
        entry.finalY = legacyDouble(object["finalY"])
        entry.width = legacyDouble(object["width"])
        entry.height = legacyDouble(object["height"])
        entry.maxWidth = legacyDouble(object["maxWidth"])
        entry.fontFamily = legacyString(object["fontFamily"])
        entry.fontPath = legacyString(object["fontPath"])
        entry.fontSize = legacyDouble(object["fontSize"])
        entry.effectiveFontSize = legacyDouble(object["effectiveFontSize"])
        entry.color = legacyDoubleArray(object["color"])
        entry.alpha = legacyDouble(object["alpha"])
        entry.rotation = legacyDouble(object["rotation"])
        entry.finalAngle = legacyDouble(object["finalAngle"])
        entry.scaleX = legacyDouble(object["scaleX"])
        entry.scaleY = legacyDouble(object["scaleY"])
        entry.finalScaleX = legacyDouble(object["finalScaleX"])
        entry.finalScaleY = legacyDouble(object["finalScaleY"])
        entry.alignment = legacyString(object["alignment"])
        if let renderOrder = legacyDouble(object["renderOrder"]) {
            entry.renderOrder = Int(renderOrder)
        }
        return entry
    }

    static func legacyBehavior(from object: [String: Any]) -> String {
        let rawBehavior = legacyString(object["behavior"] ?? object["type"] ?? object["kind"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawBehavior {
        case "clock", "time":
            return "clock"
        case "date":
            return "date"
        case "weekday", "week", "day":
            return "weekday"
        default:
            break
        }

        let name = legacyString(object["name"] ?? object["id"]) ?? ""
        let script = legacyString(object["script"])
        // 尝试从 scriptproperties 提取 format
        let format: String?
        if let sp = object["scriptproperties"] as? [String: Any],
           let f = legacyString(sp["format"]) {
            format = f
        } else if let sp = object["scriptProperties"] as? [String: Any],
                  let f = legacyString(sp["format"]) {
            format = f
        } else {
            format = nil
        }
        return detectBehavior(name: name, script: script, format: format)
    }

    /// 后处理：对同名的 clock 条目推断格式（hh/mm/ss）。
    /// 当 renderer sidecar 未提供 format 字段时，根据条目位置/名称推断格式。
    static func inferLegacyClockFormats(entries: [DynamicTextEntry]) -> [DynamicTextEntry] {
        let clockIndices = entries.indices.filter { idx in
            entries[idx].behavior == "clock" && entries[idx].format == nil
        }
        guard !clockIndices.isEmpty else { return entries }

        var result = entries

        // 同名条目按 X 位置从左到右推断 hh/mm/ss
        let groupedByName = Dictionary(grouping: clockIndices) { entries[$0].name }
        for (_, indices) in groupedByName where indices.count >= 2 {
            let sorted = indices.sorted { lhs, rhs in
                let lx = entries[lhs].finalOriginX ?? entries[lhs].originX ?? entries[lhs].finalX ?? 0
                let rx = entries[rhs].finalOriginX ?? entries[rhs].originX ?? entries[rhs].finalX ?? 0
                return lx < rx
            }
            let formats = ["hh", "mm", "ss"]
            for (i, idx) in sorted.enumerated() where i < formats.count {
                result[idx] = result[idx].withFormat(formats[i])
            }
        }

        // 对未配对的独立条目：仅当名称明确指向时间组件（秒/分）时才推断格式
        // 名称含"时钟"/"time"等主时钟词汇的保留 format=nil → 显示完整时间 HH:mm
        for idx in clockIndices where result[idx].format == nil {
            let lowerName = result[idx].name.lowercased()
            if lowerName.contains("second") || lowerName.contains("秒钟") || lowerName == "秒" || lowerName.contains("sec") {
                result[idx] = result[idx].withFormat("ss")
            } else if lowerName.contains("minute") || lowerName.contains("分钟") || lowerName == "分" || lowerName.contains("min") {
                result[idx] = result[idx].withFormat("mm")
            }
        }

        return result
    }

    static func legacyString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func legacyDouble(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func legacyDoubleArray(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        let values = array.compactMap(legacyDouble)
        return values.isEmpty ? nil : values
    }

    static func legacyBool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let lower = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(lower) { return true }
            if ["false", "no", "0"].contains(lower) { return false }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - PKG 解析（复用 SceneBakeEligibilityService 逻辑）

private extension WallpaperDynamicTextParser {

    static func extractSceneJSONFromPkg(_ pkgURL: URL) throws -> Data {
        let data = try Data(contentsOf: pkgURL)
        var o = 0
        let slen = try readU32LE(data, &o)
        guard o + Int(slen) <= data.count else { throw PkgError.truncated }
        o += Int(slen)
        let nfiles = try readU32LE(data, &o)
        var entries: [(name: String, offset: UInt32, length: UInt32)] = []
        for _ in 0..<Int(nfiles) {
            let es = try readU32LE(data, &o)
            guard o + Int(es) <= data.count else { throw PkgError.truncated }
            let nameData = data.subdata(in: o..<o + Int(es))
            o += Int(es)
            let name = String(data: nameData, encoding: .utf8) ?? ""
            let fileOff = try readU32LE(data, &o)
            let fileLen = try readU32LE(data, &o)
            entries.append((name, fileOff, fileLen))
        }
        let base = o
        for e in entries {
            if e.name == "scene.json" || e.name.hasSuffix("/scene.json") {
                let start = base + Int(e.offset)
                let end = start + Int(e.length)
                guard end <= data.count else { throw PkgError.truncated }
                return data.subdata(in: start..<end)
            }
        }
        throw PkgError.sceneNotFound
    }

    static func readU32LE(_ data: Data, _ o: inout Int) throws -> UInt32 {
        guard o + 4 <= data.count else { throw PkgError.truncated }
        let v = UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
        o += 4
        return v
    }

    enum PkgError: Error {
        case truncated
        case sceneNotFound
    }
}
