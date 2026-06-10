import Foundation

// MARK: - 规则加载器

actor RuleLoader {
    static let shared = RuleLoader()

    private var rules: [String: DataSourceRule] = [:]
    private var hasLoadedRules = false
    private let rulesDirectory: URL
    private let fileManager = FileManager.default

    init() {
        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // 使用临时目录作为回退
            self.rulesDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("WaifuX", isDirectory: true)
                .appendingPathComponent("Rules", isDirectory: true)
            try? fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
            Task {
                await copyDefaultRulesFromBundle()
            }
            return
        }
        self.rulesDirectory = supportDir
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("Rules", isDirectory: true)

        // 创建目录
        try? fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)

        // 首次启动：从 Bundle 复制默认规则
        Task {
            await copyDefaultRulesFromBundle()
        }
    }

    // MARK: - 从 Bundle 复制默认规则

    private func copyDefaultRulesFromBundle() async {
        // 检查是否已经复制过
        let copiedKey = "default_rules_copied_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: copiedKey) else {
            _ = await loadAllRules()
            return
        }

        // 从 Bundle 加载默认规则
        guard let rulesURL = Bundle.main.url(forResource: "Rules", withExtension: nil) else {
            print("[RuleLoader] Rules directory not found in bundle")
            _ = await loadAllRules()
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: rulesURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            for file in files {
                let destination = rulesDirectory.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: file, to: destination)
                    print("[RuleLoader] Copied default rule: \(file.lastPathComponent)")
                }
            }

            defaults.set(true, forKey: copiedKey)
            print("[RuleLoader] Default rules copied successfully")

            // 重新加载规则
            _ = await loadAllRules()
        } catch {
            print("[RuleLoader] Failed to copy default rules: \(error)")
        }
    }

    // MARK: - 加载所有规则

    func loadAllRules() async -> [DataSourceRule] {
        guard let files = try? fileManager.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            return []
        }

        var loadedRules: [DataSourceRule] = []
        var nextRules: [String: DataSourceRule] = [:]

        for file in files {
            do {
                let rule = try loadRule(from: file)
                // 检查是否已存在，如果存在则覆盖
                nextRules[rule.id] = rule
                loadedRules.append(rule)
            } catch {
                if isLegacyAnimeRule(at: file) {
                    try? fileManager.removeItem(at: file)
                    print("[RuleLoader] Removed legacy anime rule: \(file.lastPathComponent)")
                }
            }
        }

        rules = nextRules
        hasLoadedRules = true
        return loadedRules
    }

    // MARK: - 从文件加载

    func loadRule(from url: URL) throws -> DataSourceRule {
        let data = try Data(contentsOf: url)
        guard !Self.isLegacyAnimeRuleData(data) else {
            throw RuleError.invalidRule
        }
        return try JSONDecoder().decode(DataSourceRule.self, from: data)
    }

    // MARK: - 保存规则到本地

    func saveRule(_ rule: DataSourceRule) throws {
        let data = try JSONEncoder().encode(rule)
        let filePath = rulesDirectory.appendingPathComponent("\(rule.id).json")
        try data.write(to: filePath)
        rules[rule.id] = rule
        hasLoadedRules = true
    }

    // MARK: - 从 URL 下载并安装

    func installRule(from urlString: String) async throws -> DataSourceRule {
        guard let remoteURL = URL(string: urlString) else {
            throw RuleError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: remoteURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RuleError.downloadFailed
        }

        guard !Self.isLegacyAnimeRuleData(data) else {
            throw RuleError.invalidRule
        }
        let rule = try JSONDecoder().decode(DataSourceRule.self, from: data)

        // 保存到本地
        try saveRule(rule)

        return rule
    }

    // MARK: - 从 GitHub 仓库安装

    func installRuleFromGitHub(owner: String, repo: String, path: String, branch: String = "main") async throws -> DataSourceRule {
        let rawURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
        return try await installRule(from: rawURL)
    }

    // MARK: - 获取规则

    func rule(for id: String) async -> DataSourceRule? {
        await loadRulesIfNeeded()
        return rules[id]
    }

    // MARK: - 按类型获取规则

    func rules(for contentType: ContentType) async -> [DataSourceRule] {
        await loadRulesIfNeeded()
        return rules.values
            .filter { $0.contentType == contentType && !$0.deprecated }
            .sorted { $0.name < $1.name }
    }

    // MARK: - 获取所有规则

    func allRules() async -> [DataSourceRule] {
        await loadRulesIfNeeded()
        return Array(rules.values).sorted { $0.name < $1.name }
    }

    /// 后台释放前台资源时只清内存，不删除用户安装/同步到本地的规则文件。
    func clearInMemoryCache() {
        rules.removeAll(keepingCapacity: false)
        hasLoadedRules = false
    }

    // MARK: - 删除规则

    func removeRule(id: String) throws {
        rules.removeValue(forKey: id)
        let filePath = rulesDirectory.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: filePath.path) {
            try fileManager.removeItem(at: filePath)
        }
        hasLoadedRules = true
    }

    // MARK: - 导出规则

    func exportRule(id: String) throws -> Data? {
        guard let rule = rules[id] else {
            throw RuleError.ruleNotFound(id)
        }
        return try JSONEncoder().encode(rule)
    }

    // MARK: - 更新规则

    func updateRule(id: String) async throws -> DataSourceRule? {
        // 这里可以实现从远程更新逻辑
        // 暂时先重新加载本地文件
        let filePath = rulesDirectory.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: filePath.path) else {
            throw RuleError.ruleNotFound(id)
        }
        let rule = try loadRule(from: filePath)
        rules[id] = rule
        return rule
    }

    private func isLegacyAnimeRule(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return Self.isLegacyAnimeRuleData(data)
    }

    private func loadRulesIfNeeded() async {
        if !hasLoadedRules {
            _ = await loadAllRules()
        }
    }

    private static func isLegacyAnimeRuleData(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawContentType = object["contentType"] as? String
        else {
            return false
        }
        return rawContentType.caseInsensitiveCompare("anime") == .orderedSame
    }
}
