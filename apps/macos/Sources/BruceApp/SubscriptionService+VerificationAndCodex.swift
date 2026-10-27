import AppKit
import BruceAppCore
import BruceOnboardingCore
import Foundation

@MainActor
extension SubscriptionService {
    /// DeepSeek: API key 写 Keychain 后做真实网络试查 (用户点击触发).
    /// C020 移除月度账本后, 保存路径回归普通 API Key 写入
    /// (不再有 usageTrackingID 预写/回滚事务).
    func saveAndVerifyDeepSeek(apiKey: String) {
        Task { @MainActor in
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                model.setSettingsError("请输入 DeepSeek API key", for: .deepseek)
                return
            }
            model.setBusySubscription(true, for: .deepseek)
            defer { model.setBusySubscription(false, for: .deepseek) }

            let accountID = ProviderAccountIDGenerator.deepseekAccountID(apiKey: key)
            let saved = saveProviderAccountCredential(
                for: .deepseek,
                accountID: accountID,
                displayName: "DeepSeek · \(accountID)",
                credentialJSON: key
            )
            if !saved {
                model.setSettingsError("DeepSeek 凭证写入本机凭据文件失败", for: .deepseek)
                return
            }
            model.setSubscriptionCredentialConfigured(true, for: .deepseek)

            let status = await verifier.verifyDeepSeek(apiKey: key, session: nil)
            finishVerification(.deepseek, status: status)
        }
    }

    /// 火山引擎手动录入: 仅结构校验, 完整额度试查由 Collector 运行时承担.
    func saveAndVerifyVolcengine(accessKey: String, secretKey: String) {
        let ak = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ProviderConnectionVerifier.verifyVolcengineCredentials(
            accessKey: ak, secretKey: sk
        )
        guard status == .ok else {
            finishVerification(.volcengine, status: status)
            return
        }
        // 多账号路径: AK/SK 合成 JSON 写入 ProviderAccountStore.
        let accountID = ProviderAccountIDGenerator.volcengineAccountID(accessKey: ak)
        let dict: [String: String] = ["accessKey": ak, "secretKey": sk]
        let data = (try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )) ?? Data()
        let credentialJSON = String(data: data, encoding: .utf8) ?? "{}"
        guard saveProviderAccountCredential(
            for: .volcengine,
            accountID: accountID,
            displayName: "火山引擎 · \(accountID)",
            credentialJSON: credentialJSON
        ) else { return }
        model.setSubscriptionCredentialConfigured(true, for: .volcengine)
        finishVerification(.volcengine, status: status)
    }

    /// 智谱 Coding Plan 手动录入: 仅结构校验, 完整额度试查由 Collector 运行时承担.
    /// 凭证以 {"api_key":..., "base_url":...} JSON 写入 ProviderAccountStore.
    func saveAndVerifyZhipu(apiKey: String, baseURL: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ProviderConnectionVerifier.verifyZhipuCredentials(
            apiKey: key, baseURL: base
        )
        guard status == .ok else {
            finishVerification(.zhipu, status: status)
            return
        }
        // 多账号路径: api_key + base_url 合成 JSON 写入 ProviderAccountStore.
        let accountID = ProviderAccountIDGenerator.zhipuAccountID(apiKey: key)
        let dict: [String: String] = ["api_key": key, "base_url": base]
        let data = (try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )) ?? Data()
        let credentialJSON = String(data: data, encoding: .utf8) ?? "{}"
        guard saveProviderAccountCredential(
            for: .zhipu,
            accountID: accountID,
            displayName: "Z.ai · \(accountID)",
            credentialJSON: credentialJSON
        ) else { return }
        model.setSubscriptionCredentialConfigured(true, for: .zhipu)
        finishVerification(.zhipu, status: status)
    }

    /// 火山引擎从 CC Switch 导入 (用户在确认对话框同意后调用).
    /// 只读 CC 数据库, 禁止任何写入.
    func importVolcengineFromCCSwitch() {
        Task { @MainActor in
            model.setBusySubscription(true, for: .volcengine)
            defer { model.setBusySubscription(false, for: .volcengine) }
            let databaseURL = homeURL
            .appendingPathComponent(".cc-switch/cc-switch.db")
            let result = await ccSwitchImporter.importCredentials(
            databaseURL: databaseURL
            )
            switch result {
                case .failure(let error):
                model.setSettingsError(
                    "从 CC Switch 导入火山引擎失败: \(error.description)",
                    for: .volcengine
                )
                case .success(let credentials):
                saveAndVerifyVolcengine(
                accessKey: credentials.accessKey,
                secretKey: credentials.secretKey
                )
            }
        }
    }

    /// Kimi For Coding 手动录入: 仅结构校验, 完整额度试查由 Collector 运行时承担.
    /// 凭证为 API key 字符串 (走 api.kimi.com/coding/v1/usages, 与 CC Switch 一致).
    func saveAndVerifyKimi(apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ProviderConnectionVerifier.verifyKimiAPIKey(key)
        guard status == .ok else {
            finishVerification(.kimi, status: status)
            return
        }
        let accountID = ProviderAccountIDGenerator.kimiAccountID(apiKey: key)
        guard saveProviderAccountCredential(
            for: .kimi,
            accountID: accountID,
            displayName: "Kimi · \(accountID)",
            credentialJSON: key
        ) else { return }
        model.setSubscriptionCredentialConfigured(true, for: .kimi)
        finishVerification(.kimi, status: status)
    }

    /// StepFun (Step Plan): 录入 Oasis-Token (支持可选指定站点国内/国际).
    func saveAndVerifyStepFun(token: String, site: StepFunSite? = nil) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ProviderConnectionVerifier.verifyStepFunTokenFormat(trimmed)
        guard status == .ok else {
            finishVerification(.stepfun, status: status)
            return
        }
        let store = accountStore(for: .stepfun)
        let accountID = ProviderAccountIDGenerator.stepfunAccountID(token: trimmed)
        let isGlobal = (site == .global) || ProviderConnectionVerifier.isStepFunGlobalToken(trimmed)
        let displayName = isGlobal
            ? "StepFun (国际) · \(String(accountID.prefix(8)))"
            : "StepFun · \(String(accountID.prefix(8)))"
        guard saveProviderAccountCredential(
            for: .stepfun,
            accountID: accountID,
            displayName: displayName,
            credentialJSON: trimmed
        ) else { return }
        model.setSubscriptionCredentialConfigured(true, for: .stepfun)
        if let summaries = try? store.summaries() {
            model.setProviderAccountSummaries(summaries, for: .stepfun)
        }
        finishVerification(.stepfun, status: status)
    }

    /// TypeSafe Jev: 录入 API Key 与可选账户余额.
    func saveAndVerifyJev(apiKey: String, balance: Double? = nil) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ProviderConnectionVerifier.verifyJevAPIKey(key)
        guard status == .ok else {
            finishVerification(.jev, status: status)
            return
        }
        let store = accountStore(for: .jev)
        let accountID = ProviderAccountIDGenerator.jevAccountID(apiKey: key)
        let displayName = "Jev · \(String(accountID.prefix(8)))"

        let credentialJSON: String
        if let balance, balance >= 0 {
            let dict: [String: Any] = [
                "apiKey": key,
                "balance": balance,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: data, encoding: .utf8) {
                credentialJSON = str
            } else {
                credentialJSON = key
            }
        } else {
            credentialJSON = key
        }

        guard saveProviderAccountCredential(
            for: .jev,
            accountID: accountID,
            displayName: displayName,
            credentialJSON: credentialJSON
        ) else { return }
        model.setSubscriptionCredentialConfigured(true, for: .jev)
        if let summaries = try? store.summaries() {
            model.setProviderAccountSummaries(summaries, for: .jev)
        }
        finishVerification(.jev, status: status)
    }

    /// Cline / ClinePass: 录入 API Key (app.cline.bot Settings > API Keys 创建).
    /// 三窗口额度 (5h/7d/30d) 由 collector 出站读取 plan entitlements 与逐单台账.
    func saveAndVerifyCline(apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ProviderConnectionVerifier.verifyClineAPIKey(key)
        guard status == .ok else {
            finishVerification(.cline, status: status)
            return
        }
        let store = accountStore(for: .cline)
        let accountID = ProviderAccountIDGenerator.clineAccountID(apiKey: key)
        let displayName = "Cline · \(String(accountID.prefix(8)))"
        guard saveProviderAccountCredential(
            for: .cline,
            accountID: accountID,
            displayName: displayName,
            credentialJSON: key
        ) else { return }
        model.setSubscriptionCredentialConfigured(true, for: .cline)
        if let summaries = try? store.summaries() {
            model.setProviderAccountSummaries(summaries, for: .cline)
        }
        finishVerification(.cline, status: status)
    }

    // MARK: - Claude / Grok 手动导入 (Phase 2/3)

    /// Claude: 从本机 CLI 登录态只读导入 (C059: Keychain 静默优先 → 凭证文件回退,
    /// 与 cc-switch 读取序一致; 全程 UISkip 绝不弹窗).
    func importClaudeFromLocal() {
        switch localProbe.claudeLocalCredentialForImport() {
            case .failure(let error):
                model.setSettingsError(
                    "Claude 本机凭证导入失败: \(error.description)", for: .claude
                )
            case .success(let json):
                saveClaudeOAuthJSON(json)
        }
    }

    /// Claude: 引导粘贴导入 (纯 token 或 claudeAiOauth 同构 JSON).
    func importClaudeFromPaste(_ paste: String) {
        switch ClaudePasteParser.parse(paste) {
            case .failure(let error):
            model.setSettingsError(
                "Claude 凭证解析失败: \(error.description)", for: .claude
            )
            case .success(let json):
            saveClaudeOAuthJSON(json)
        }
    }

    /// Claude: 统一保存入口 (evaluator 判定 -> Keychain -> 状态迁移).
    func saveClaudeOAuthJSON(_ json: String) {
        let status = SubscriptionCredentialEvaluator.claudeStatus(
        of: json, now: Date()
        )
        switch status {
            case .missing, .malformed:
            model.setSettingsError("Claude 凭证无效, 请重新粘贴", for: .claude)
            return
            case .valid, .refreshPending:
                // refreshPending (C059): 访问令牌过期但刷新令牌还活着 — 照常入库验证
                // (与 cc-switch「过期也试一把」一致), 查询失败自然落到 needsRelogin,
                // UI 按「运行一次 Claude CLI 可恢复」提示而非要求重新登录.
                // 多账号路径: 写入 ProviderAccountStore (upsert).
                let access = Self.claudeAccessToken(from: json) ?? json
                let accountID = ProviderAccountIDGenerator.claudeAccountID(accessToken: access)
                let displayName = "Claude · " + String(accountID.prefix(8))
                guard saveProviderAccountCredential(
                    for: .claude,
                    accountID: accountID,
                    displayName: displayName,
                    credentialJSON: json
                ) else { return }
                model.setSubscriptionCredentialConfigured(true, for: .claude)
                finishVerification(.claude, status: .ok)
            case .expired:
            // 过期凭证保留粘贴入口, 提示重新登录 (不写入 Keychain)
            model.setSettingsError("Claude 登录已过期, 请粘贴新凭证", for: .claude)
            finishVerification(.claude, status: .needsRelogin)
        }
        refreshOfficialLocalAvailability()
    }

    /// Grok: 从本机 CLI 凭证文件只读导入.
    func importGrokFromLocal() {
        let fileURL = GrokCLICredentialImporter.defaultFileURL(homeURL)
        switch GrokCLICredentialImporter().importCredentials(fileURL: fileURL) {
            case .failure(let error):
            model.setSettingsError(
                "Grok 本机凭证导入失败: \(error.description)", for: .grok
            )
            case .success(let json):
            saveGrokOAuthJSON(json)
        }
    }

    /// Grok: 引导粘贴导入 (纯 token 或 auth.json 同构 JSON).
    func importGrokFromPaste(_ paste: String) {
        switch GrokPasteParser.parse(paste) {
            case .failure(let error):
            model.setSettingsError(
                "Grok 凭证解析失败: \(error.description)", for: .grok
            )
            case .success(let json):
            saveGrokOAuthJSON(json)
        }
    }

    /// Grok: 统一保存入口 (evaluator 判定 -> Keychain -> 状态迁移).
    func saveGrokOAuthJSON(_ json: String) {
        let status = SubscriptionCredentialEvaluator.grokStatus(
        of: json, now: Date()
        )
        switch status {
            case .missing, .malformed:
            model.setSettingsError("Grok 凭证无效, 请重新粘贴", for: .grok)
            return
            // refreshPending 仅 Claude 评估器会产出; 此处防御性同 valid 收口.
            case .valid, .refreshPending:
            // 多账号路径: 写入 ProviderAccountStore (upsert).
            let key = Self.grokKey(from: json) ?? json
            let accountID = ProviderAccountIDGenerator.grokAccountID(key: key)
            let displayName = "Grok · " + String(accountID.prefix(8))
            guard saveProviderAccountCredential(
                for: .grok,
                accountID: accountID,
                displayName: displayName,
                credentialJSON: json
            ) else { return }
            model.setSubscriptionCredentialConfigured(true, for: .grok)
            finishVerification(.grok, status: .ok)
            case .expired:
            // 过期凭证保留粘贴入口, 提示重新登录 (不写入 Keychain)
            model.setSettingsError("Grok 登录已过期, 请粘贴新凭证", for: .grok)
            finishVerification(.grok, status: .needsRelogin)
        }
        refreshOfficialLocalAvailability()
    }

    // MARK: - OpenCode GO 手动导入 (网页会话凭证)

    /// OpenCode GO: 引导粘贴导入 ({"auth": <Fe26 cookie>, "workspaceId": "wrk_..."} JSON).
    func importOpenCodeGoFromPaste(_ paste: String) {
        let trimmed = paste.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            // 已是 JSON: 原样保存
            _ = dict
            saveOpenCodeGoOAuthJSON(trimmed)
        } else {
            model.setSettingsError(
                "OpenCode GO 凭证无效, 请粘贴 auth cookie 与 workspaceId 的 JSON",
                for: .opencodeGo
            )
        }
    }

    /// OpenCode GO: 统一保存入口 (evaluator 判定 -> Keychain -> 状态迁移).
    func saveOpenCodeGoOAuthJSON(_ json: String) {
        let status = SubscriptionCredentialEvaluator.opencodeGoStatus(of: json)
        switch status {
            case .missing, .malformed:
            model.setSettingsError(
                "OpenCode GO 凭证无效, 请粘贴 auth cookie 与 workspaceId",
                for: .opencodeGo
            )
            return
            // refreshPending 仅 Claude 评估器会产出; 此处防御性同 valid 收口.
            case .valid, .refreshPending:
            let workspace = Self.opencodeGoWorkspaceID(from: json) ?? json
            let accountID = ProviderAccountIDGenerator.opencodeGoAccountID(
                accessToken: workspace
            )
            let displayName = "OpenCode GO · " + String(accountID.prefix(8))
            guard saveProviderAccountCredential(
                for: .opencodeGo,
                accountID: accountID,
                displayName: displayName,
                credentialJSON: json
            ) else { return }
            model.setSubscriptionCredentialConfigured(true, for: .opencodeGo)
            finishVerification(.opencodeGo, status: .ok)
            case .expired:
            model.setSettingsError("OpenCode GO 登录已过期, 请粘贴新凭证", for: .opencodeGo)
            finishVerification(.opencodeGo, status: .needsRelogin)
        }
    }

    /// OpenCode GO: 用 Keychain 现有凭证重新触发验证状态迁移
    /// (凭证已存在但验证状态缺失/过期时, 由设置页"重新验证"触发).
    func reverifyOpenCodeGo() {
        Task { await reverify(.opencodeGo) }
    }

    /// 用已存凭证重跑验证状态迁移 (设置页"重新验证"统一入口).
    /// 覆盖 kimi / deepseek / 火山引擎 / 智谱 (本地格式校验) 与
    /// claude / grok / opencodeGo (Evaluator 判定); codex 不提供.
    /// 多账号下取最近更新的账号记录 (见 ProviderAccountStore.index 顺序约定),
    /// 旧账号残留问题不在本次范围 (见下方 `firstAccountRecord`).
    func reverify(_ id: SubscriptionProviderID) async {
        guard let record = firstAccountRecord(for: id) else {
            model.setSettingsError(
                "\(id.displayName) 未找到已保存凭证", for: id
            )
            return
        }
        model.setBusySubscription(true, for: id)
        defer { model.setBusySubscription(false, for: id) }
        switch id {
        case .kimi:
            finishVerification(
                .kimi,
                status: ProviderConnectionVerifier.verifyKimiAPIKey(record.credentialJSON)
            )
        case .deepseek:
            finishVerification(
                .deepseek,
                status: await verifier.verifyDeepSeek(
                    apiKey: record.credentialJSON, session: nil
                )
            )
        case .volcengine:
            guard case let .akSk(ak, sk) = StoredCredentialParser.parse(
                provider: .volcengine, credentialJSON: record.credentialJSON
            ) else {
                model.setSettingsError(
                    "火山引擎凭证形态不兼容, 请重新粘贴 AK/SK", for: .volcengine
                )
                return
            }
            finishVerification(
                .volcengine,
                status: ProviderConnectionVerifier.verifyVolcengineCredentials(
                    accessKey: ak, secretKey: sk
                )
            )
        case .zhipu:
            guard case let .zhipu(key, base) = StoredCredentialParser.parse(
                provider: .zhipu, credentialJSON: record.credentialJSON
            ) else {
                model.setSettingsError(
                    "Z.ai 凭证形态不兼容, 请重新粘贴 API key", for: .zhipu
                )
                return
            }
            finishVerification(
                .zhipu,
                status: ProviderConnectionVerifier.verifyZhipuCredentials(
                    apiKey: key, baseURL: base
                )
            )
        case .claude:
            switch SubscriptionCredentialEvaluator.claudeStatus(
                of: record.credentialJSON, now: Date()
            ) {
            case .valid, .refreshPending:
                // refreshPending 照常放行验证 (C059), 实查询 401 才落 needsRelogin.
                finishVerification(.claude, status: .ok)
            case .missing, .malformed:
                model.setSettingsError("Claude 凭证无效, 请重新粘贴", for: .claude)
            case .expired:
                finishVerification(.claude, status: .needsRelogin)
            }
        case .grok:
            switch SubscriptionCredentialEvaluator.grokStatus(
                of: record.credentialJSON, now: Date()
            ) {
            case .valid, .refreshPending:
                finishVerification(.grok, status: .ok)
            case .missing, .malformed:
                model.setSettingsError("Grok 凭证无效, 请重新粘贴", for: .grok)
            case .expired:
                finishVerification(.grok, status: .needsRelogin)
            }
        case .opencodeGo:
            switch SubscriptionCredentialEvaluator.opencodeGoStatus(
                of: record.credentialJSON
            ) {
            case .valid, .refreshPending:
                finishVerification(.opencodeGo, status: .ok)
            case .missing, .malformed:
                model.setSettingsError("OpenCode GO 凭证不完整, 请重新粘贴", for: .opencodeGo)
            case .expired:
                finishVerification(.opencodeGo, status: .needsRelogin)
            }
        case .stepfun:
            finishVerification(
                .stepfun,
                status: ProviderConnectionVerifier.verifyStepFunTokenFormat(record.credentialJSON)
            )
        case .jev:
            let key: String
            if let parsed = StoredCredentialParser.parse(provider: .jev, credentialJSON: record.credentialJSON),
               case .apiKey(let k) = parsed {
                key = k
            } else {
                key = record.credentialJSON
            }
            finishVerification(
                .jev,
                status: ProviderConnectionVerifier.verifyJevAPIKey(key)
            )
        case .codex:
            // Codex 走 token manager, 不提供本地重新验证.
            model.setSettingsError(
                "\(id.displayName) 暂不支持重新验证", for: id
            )
        case .cline:
            let key: String
            if let parsed = StoredCredentialParser.parse(provider: .cline, credentialJSON: record.credentialJSON),
               case .apiKey(let k) = parsed {
                key = k
            } else {
                key = record.credentialJSON
            }
            finishVerification(
                .cline,
                status: ProviderConnectionVerifier.verifyClineAPIKey(key)
            )
        }
    }

    /// 取 provider 最近更新的账号记录 (index 按更新时间升序, 末位最新).
    /// 找不到返回 nil; 多账号选型语义详见 `reverify(_:)` 的说明.
    func firstAccountRecord(
        for id: SubscriptionProviderID
    ) -> ProviderAccountRecord? {
        let store = accountStore(for: id)
        guard let index = try? store.loadIndex(),
              let last = index.accounts.last,
              let record = try? store.loadRecord(for: last.accountID) else {
            return nil
        }
        return record
    }

    /// 从 OpenCode GO 凭证 JSON 提取 workspaceId; 失败返回 nil.
    static func opencodeGoWorkspaceID(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        let workspace = (dict["workspaceId"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.isEmpty ? nil : workspace
    }

    /// Codex: 从 CLI `~/.codex/auth.json` 发现账号 (用户点击触发).
    /// 只保存账号元数据 (needsReauthorization), 不导入 token.
    func importCodexFromLocalCLI() {
        let fileURL = homeURL.appendingPathComponent(".codex/auth.json")
        guard let json = readCredentialFile(fileURL, usage: "Codex CLI 认证文件") else {
            return
        }
        do {
            let accounts = try CodexDiscovery.fromCLIAuthJSON(json)
            try codexStore.saveDiscoveredAccounts(
            accounts, now: Date()
            )
        } catch {
            model.setSettingsError("Codex 认证文件解析失败, 仅发现账号元数据", for: .codex)
            return
        }
        finishCodexDiscoveryImport()
    }

    /// Codex: 从 CC Switch 账号库发现账号 (用户在确认对话框同意后调用).
    /// 只读 `~/.cc-switch/codex_oauth_auth.json`, 不回写 CC.
    /// 只保存账号元数据 (needsReauthorization), 不导入 token.
    func importCodexFromCCSwitch() {
        let fileURL = homeURL.appendingPathComponent(
        ".cc-switch/codex_oauth_auth.json"
        )
        guard let json = readCredentialFile(fileURL, usage: "CC Switch Codex 账号库") else {
            return
        }
        do {
            let accounts = try CodexDiscovery.fromCCSwitchAccountsJSON(json)
            try codexStore.saveDiscoveredAccounts(
            accounts, now: Date()
            )
        } catch {
            model.setSettingsError("CC Switch Codex 账号库解析失败, 仅发现账号元数据", for: .codex)
            return
        }
        finishCodexDiscoveryImport()
    }

    /// 发现导入的公共收尾: 发布摘要与验证状态.
    /// 发现的账号是 metadata-only (无 token), 不标记"已配置";
    /// "已配置"只在存在真实完整 record 时成立 (fail-closed).
    func finishCodexDiscoveryImport() {
        publishCodexSummaryFromIndex()
        publishCodexCredentialConfigured()
        finishVerification(.codex, status: .none)
    }

    /// 按真实完整 record 发布 Codex"已配置"状态, 索引状态不作数.
    func publishCodexCredentialConfigured() {
        let configured = (try? codexStore.hasConfiguredCredentials()) ?? false
        model.setSubscriptionCredentialConfigured(configured, for: .codex)
    }

    /// Codex: 设备码登录新账号 (用户点击触发, 全程网络只由该点击发起).
    /// UI 展示 user_code 并打开官方验证页; 轮询带过期超时与任务取消;
    /// 成功后复用账号库合并逻辑写入 Keychain 并设为 active, 刷新摘要.
    /// 每步失败都给出可诊断错误, 不写半成品凭证 (fail-closed).
    func loginCodexNewAccount() {
        codexLoginTask?.cancel()
        model.setBusySubscription(true, for: .codex)
        model.setSettingsError(nil)
        codexLoginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.model.setBusySubscription(false, for: .codex) }
            let flow = CodexDeviceFlow()

            let authorization: DeviceAuthorization
            switch await flow.start() {
                case .failure(let error):
                guard error != .cancelled else { return }
                self.codexDeviceLogin = nil
                self.model.setSettingsError(
                    "Codex 登录发起失败: \(error.description)", for: .codex
                )
                return
                case .success(let parsed):
                authorization = parsed
            }

            self.codexDeviceLogin = DeviceLoginPresentation(
            userCode: authorization.userCode,
            verificationURL: authorization.verificationURL,
            stage: .waitingAuthorization
            )
            self.openInBrowser(authorization.verificationURL)

            let grant: CodexDeviceFlow.DeviceGrant
            switch await flow.pollUntilAuthorized(authorization) {
                case .failure(let error):
                if error == .cancelled { self.codexDeviceLogin = nil }
                else { self.finishCodexLogin(with: error) }
                return
                case .success(let parsed):
                grant = parsed
            }

            self.codexDeviceLogin?.stage = .finishing
            switch await flow.exchange(grant) {
                case .failure(let error):
                if error == .cancelled { self.codexDeviceLogin = nil }
                else { self.finishCodexLogin(with: error) }
                return
                case .success(let account):
                do {
                    // 交由 token manager 保存完整 v2 记录 (credentialOrigin=Bruce),
                    // 独立 token 链, 不再合并进旧整体账号库.
                    // 保留服务端 expires_in 和收到时刻, 按
                    // expires_in > JWT exp > 1 小时 计算过期时间.
                    try await self.codexTokenManager.storeLoginResult(
                    accountID: account.accountID,
                    email: account.email,
                    accessToken: account.accessToken,
                    refreshToken: account.refreshToken,
                    idToken: account.idToken,
                    expiresAt: CodexTokenExpiry.expiresAt(
                        from: CodexTokenResponse(
                            accessToken: account.accessToken,
                            refreshToken: account.refreshToken,
                            idToken: account.idToken,
                            expiresIn: account.expiresIn,
                            receivedAt: account.receivedAt
                        ),
                        jwtExp: CodexTokenExpiry.jwtExp(of: account.idToken)
                    )
                    )
                } catch {
                    self.codexDeviceLogin = nil
                    self.model.setSettingsError(
                    "Codex 凭证写入本机凭据文件失败, 登录未完成", for: .codex
                )
                    return
                }
                self.publishCodexCredentialConfigured()
                self.publishCodexSummaryFromIndex()
                self.finishVerification(.codex, status: .ok)
                guard self.codexDeviceLogin != nil else { return }
                self.codexDeviceLogin?.stage = .succeeded
                // 成功状态短暂展示后收起
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.codexDeviceLogin = nil
            }
        }
    }

    /// 取消进行中的 Codex 设备码登录并收起展示.
    func cancelCodexLogin() {
        codexLoginTask?.cancel()
        codexLoginTask = nil
        codexDeviceLogin = nil
        model.setBusySubscription(false, for: .codex)
    }

    /// 重新打开 Codex 验证页 (用户误关浏览器时点击).
    func reopenCodexLoginPage() {
        guard let url = codexDeviceLogin?.verificationURL else { return }
        openInBrowser(url)
    }

    /// Codex 轮询或换码失败的统一收尾, 均 fail-closed.
    func finishCodexLogin(with error: DeviceAuthError) {
        switch error {
            case .authorizationExpired:
            codexDeviceLogin?.stage = .timedOut
            case .authorizationDenied:
            codexDeviceLogin?.stage = .failed("授权被拒绝")
            default:
            codexDeviceLogin?.stage = .failed(error.description)
        }
        model.setSettingsError("Codex 登录未完成: \(error.description)", for: .codex)
    }
}
