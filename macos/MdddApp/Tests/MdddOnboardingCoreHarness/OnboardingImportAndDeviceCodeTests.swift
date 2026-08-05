import Foundation
@testable import MdddOnboardingCore

// MARK: - Import pure logic / CC Switch volc / device code

extension MdddOnboardingCoreHarness {
    // MARK: - 订阅凭证导入纯逻辑 (全部临时目录 fixture, 禁真实主目录)

    /// 与 collect_usage.py _volc_decode_secret 对齐: 非 base64 立即停止,
    /// 只保留原始候选. "notbase64!" 去掉非字母表字符后长度 % 4 == 1, 必然解码失败.
    static func volcDecoderStopsWhenNotBase64() throws {
        let candidates = VolcengineSecretDecoder.decodeCandidates("notbase64!")
        try coreExpect(candidates == ["notbase64!"], "非 base64 必须只保留 raw, got \(candidates)")
    }

    /// 一次编码与两次编码都要完整展开候选链.
    static func volcDecoderSingleAndDoubleEncoded() throws {
        let plain = "sk-real-secret-0001"
        let single = Data(plain.utf8).base64EncodedString()
        let double = Data(single.utf8).base64EncodedString()
        try coreExpect(
            VolcengineSecretDecoder.decodeCandidates(single) == [single, plain],
            "一次编码候选链不符"
        )
        try coreExpect(
            VolcengineSecretDecoder.decodeCandidates(double) == [double, single, plain],
            "两次编码候选链不符"
        )
    }

    /// 导入 Keychain 取最深成功解码; 不可解码时保留 raw.
    static func volcFullyDecodedPicksDeepestCandidate() throws {
        let plain = "sk-real-secret-0002"
        let double = Data(Data(plain.utf8).base64EncodedString().utf8)
            .base64EncodedString()
        try coreExpect(
            VolcengineSecretDecoder.fullyDecoded(double) == plain,
            "两次编码必须解到原文"
        )
        try coreExpect(
            VolcengineSecretDecoder.fullyDecoded("notbase64!") == "notbase64!",
            "不可解码必须保留 raw"
        )
    }

    static func kimiPasteParsesFullJSON() throws {
        let result = KimiPasteParser.parse(
            " {\"access_token\":\"a1\",\"refresh_token\":\"r1\"} "
        )
        guard case .success(let json) = result else {
            throw CoreTestFailure.expectation("整段 JSON 必须解析成功, got \(result)")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyKimiWebTokensJSON(json) == .ok,
            "解析结果必须通过结构校验"
        )
    }

    /// 两段 token (空白或换行分隔) 与单段 token 的映射.
    static func kimiPasteParsesTokenPairs() throws {
        guard case .success(let pair) = KimiPasteParser.parse("a2\nr2") else {
            throw CoreTestFailure.expectation("两段 token 必须解析成功")
        }
        try coreExpect(
            pair.contains("\"access_token\":\"a2\"")
                && pair.contains("\"refresh_token\":\"r2\""),
            "两段 token 顺序映射不符: \(pair)"
        )
        try coreExpect(
            ProviderConnectionVerifier.verifyKimiWebTokensJSON(pair) == .ok,
            "两段 token 必须 ok"
        )
        // 单段 token 只有 access, 结构校验必须 needsRelogin
        guard case .success(let single) = KimiPasteParser.parse("a-only") else {
            throw CoreTestFailure.expectation("单段 token 必须解析成功")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyKimiWebTokensJSON(single) == .needsRelogin,
            "单段 token 必须 needsRelogin"
        )
    }

    static func kimiPasteRejectsEmptyAndBrokenJSON() throws {
        guard case .failure(let empty) = KimiPasteParser.parse("   ") else {
            throw CoreTestFailure.expectation("空输入必须失败")
        }
        guard case .missingField = empty else {
            throw CoreTestFailure.expectation("空输入必须 missingField, got \(empty)")
        }
        guard case .failure(let broken) = KimiPasteParser.parse("{not json") else {
            throw CoreTestFailure.expectation("坏 JSON 必须失败")
        }
        try coreExpect(broken == .invalidJSON, "坏 JSON 必须 invalidJSON, got \(broken)")
        guard case .failure = KimiPasteParser.parse("{}") else {
            throw CoreTestFailure.expectation("空对象必须失败")
        }
    }

    /// 结构与 collect_usage.py:1128-1143 的消费方式对齐.
    static func codexAuthFileParsesValidAccount() throws {
        let json = """
            {"tokens": {"account_id": "acc-1", "refresh_token": "rt",
             "access_token": "at", "id_token": "it", "email": "u@example.com"}}
            """
        guard case .success(let account) = CodexAuthFileParser.parse(json) else {
            throw CoreTestFailure.expectation("合法 auth.json 必须解析成功")
        }
        try coreExpect(account.accountID == "acc-1", "account_id 不符")
        try coreExpect(account.email == "u@example.com", "email 不符")
        try coreExpect(account.refreshToken == "rt", "refresh_token 不符")
        try coreExpect(account.idToken == "it", "id_token 不符")
    }

    static func codexAuthFileRejectsMissingFields() throws {
        let cases = [
            ("not json", "非 JSON"),
            ("{}", "缺 tokens"),
            ("{\"tokens\": {}}", "缺 account_id"),
            ("{\"tokens\": {\"account_id\": \"a\"}}", "缺 refresh_token"),
            ("{\"tokens\": {\"account_id\": \"a\", \"refresh_token\": \"rt\"}}",
             "缺 access_token"),
        ]
        for (json, label) in cases {
            guard case .failure = CodexAuthFileParser.parse(json) else {
                throw CoreTestFailure.expectation("\(label) 必须解析失败")
            }
        }
    }

    /// 合并: 空库创建, 异 id 保留, 同 id 覆盖; 合并结果必须通过账号库结构校验.
    static func codexLibraryMergingCreatesPreservesUpdates() throws {
        let account1 = CodexCLIAuthAccount(
            accountID: "acc-1", email: "u1@example.com",
            refreshToken: "rt1", accessToken: "at1", idToken: nil
        )
        guard case .success(let created) = CodexAccountsLibrary.merging(
            existingJSON: nil, account: account1
        ) else {
            throw CoreTestFailure.expectation("空库合并必须成功")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyCodexAccountsJSON(created) == .ok,
            "新建账号库必须通过结构校验"
        )

        let account2 = CodexCLIAuthAccount(
            accountID: "acc-2", email: nil,
            refreshToken: "rt2", accessToken: "at2", idToken: "it2"
        )
        guard case .success(let merged) = CodexAccountsLibrary.merging(
            existingJSON: created, account: account2
        ) else {
            throw CoreTestFailure.expectation("追加合并必须成功")
        }
        try coreExpect(
            CodexAccountsLibrary.accountIDs(of: merged) == ["acc-1", "acc-2"],
            "异 id 必须保留两个账号"
        )

        let account1Updated = CodexCLIAuthAccount(
            accountID: "acc-1", email: "u1@example.com",
            refreshToken: "rt1-new", accessToken: "at1-new", idToken: nil
        )
        guard case .success(let updated) = CodexAccountsLibrary.merging(
            existingJSON: merged, account: account1Updated
        ) else {
            throw CoreTestFailure.expectation("同 id 合并必须成功")
        }
        try coreExpect(
            CodexAccountsLibrary.accountIDs(of: updated) == ["acc-1", "acc-2"],
            "同 id 覆盖不得增加账号数"
        )
        try coreExpect(
            updated.contains("rt1-new"),
            "同 id 必须覆盖为新 token"
        )
    }

    /// 摘要: 邮箱取 @ 前缀, 无 email 回落 id 前 8 位 (collect_usage.py:1148).
    static func codexLibrarySummaryCountAndPrefixes() throws {
        let json = """
            {"accounts": {
             "acc-aaaaaaaabbbb": {"email": "alice@example.com",
              "refresh_token": "rt", "access_token": "at"},
             "acc-bbbbbbbbcccc": {"refresh_token": "rt", "access_token": "at"}}}
            """
        let summary = CodexAccountsLibrary.summary(of: json)
        try coreExpect(summary.count == 2, "账号数不符: \(summary.count)")
        try coreExpect(
            summary.emailPrefixes == ["alice", "acc-bbbb"],
            "前缀列表不符: \(summary.emailPrefixes)"
        )
        let empty = CodexAccountsLibrary.summary(of: "not json")
        try coreExpect(
            empty.count == 0 && empty.emailPrefixes.isEmpty,
            "非法 JSON 摘要必须为空"
        )
    }

    static func codexChooseActiveAccountPriority() throws {
        let ids = ["acc-1", "acc-2"]
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: "acc-2", existingActive: "acc-1", accountIDs: ids
            ) == "acc-2",
            "CLI 当前账号必须优先"
        )
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: "gone", existingActive: "acc-1", accountIDs: ids
            ) == "acc-1",
            "CLI 不在库中必须保留既有 active"
        )
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: nil, existingActive: nil, accountIDs: ids
            ) == "acc-1",
            "都不可用必须回落第一个账号"
        )
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: nil, existingActive: nil, accountIDs: []
            ) == nil,
            "空库必须返回 nil"
        )
    }

    // MARK: - CC Switch 火山导入 (临时目录 fixture, 禁写入)

    /// 构造带火山 provider 行的 CC Switch fixture 数据库.
    static func createVolcCCSwitchFixture(
        at dbURL: URL, metaJSON: String
    ) throws {
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (
                id TEXT, name TEXT, app_type TEXT,
                settings_config TEXT, meta TEXT, is_current INTEGER
            );
            INSERT INTO providers VALUES (
                'p1', '火山Codingplan', 'ark', '{}', '\(metaJSON)', 1);
            """)
    }

    /// 只读导入: AK 原样, SK 按 _volc_decode_secret 解码; 数据库字节不得变化.
    static func ccSwitchVolcImportReadsFixtureDatabase() async throws {
        let tempDir = makeTempDir("ccvolc-ok")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        let plainSK = "sk-real-secret-0003"
        let encodedSK = Data(plainSK.utf8).base64EncodedString()
        try createVolcCCSwitchFixture(
            at: dbURL,
            metaJSON: "{\"usage_script\": {\"accessKeyId\": \"AKLTfixture0000\", \"secretAccessKey\": \"\(encodedSK)\"}}"
        )
        let bytesBefore = try Data(contentsOf: dbURL)

        let importer = CCSwitchVolcengineImporter()
        let result = await importer.importCredentials(databaseURL: dbURL)
        guard case .success(let credentials) = result else {
            throw CoreTestFailure.expectation("导入必须成功, got \(result)")
        }
        try coreExpect(
            credentials.accessKey == "AKLTfixture0000",
            "AK 不符: \(credentials.accessKey)"
        )
        try coreExpect(
            credentials.secretKey == plainSK,
            "SK 必须解码, got \(credentials.secretKey)"
        )

        // 只读红线: 数据库文件不得被修改
        let bytesAfter = try Data(contentsOf: dbURL)
        try coreExpect(bytesBefore == bytesAfter, "导入不得修改 CC Switch 数据库")
    }

    /// CC 中无火山 provider 行时必须给出可诊断错误, 不静默为空.
    static func ccSwitchVolcImportMissingProviderRow() async throws {
        let tempDir = makeTempDir("ccvolc-norow")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (
                id TEXT, name TEXT, app_type TEXT,
                settings_config TEXT, meta TEXT, is_current INTEGER
            );
            INSERT INTO providers VALUES ('p2', 'DeepSeek', 'ds', '{}', '{}', 1);
            """)

        let importer = CCSwitchVolcengineImporter()
        let result = await importer.importCredentials(databaseURL: dbURL)
        guard case .failure(let error) = result else {
            throw CoreTestFailure.expectation("无火山行必须失败")
        }
        guard case .providerRowNotFound = error else {
            throw CoreTestFailure.expectation(
                "必须 providerRowNotFound, got \(error)"
            )
        }
    }

    static func ccSwitchVolcImportMissingFile() async throws {
        let importer = CCSwitchVolcengineImporter()
        let result = await importer.importCredentials(
            databaseURL: URL(fileURLWithPath: "/nonexistent/cc-\(UUID().uuidString).db")
        )
        guard case .failure(let error) = result else {
            throw CoreTestFailure.expectation("文件缺失必须失败")
        }
        guard case .fileNotFound = error else {
            throw CoreTestFailure.expectation("必须 fileNotFound, got \(error)")
        }
    }

    // MARK: - 订阅配置状态迁移

    /// applyingVerification: ok 才启用; failed / needsRelogin 即使之前
    /// 已启用也必须回落禁用 (fail-closed).
    static func subscriptionConfigApplyingVerificationTransitions() throws {
        var entry = SubscriptionProviderConfiguration()
        entry = entry.applyingVerification(.ok, verifiedAt: "2026-07-30T00:00:00Z")
        try coreExpect(entry.enabled, "ok 必须启用")
        try coreExpect(
            entry.lastVerifiedAt == "2026-07-30T00:00:00Z",
            "ok 必须记录验证时间"
        )

        let failed = entry.applyingVerification(
            .failed(reason: "API key 无效或已过期"),
            verifiedAt: "2026-07-30T01:00:00Z"
        )
        try coreExpect(!failed.enabled, "failed 必须禁用")
        try coreExpect(
            failed.verificationStatus == .failed(reason: "API key 无效或已过期"),
            "failed 必须保留原因"
        )
        try coreExpect(
            failed.lastVerifiedAt == "2026-07-30T01:00:00Z",
            "failed 必须更新验证时间"
        )

        let relogin = entry.applyingVerification(
            .needsRelogin, verifiedAt: "2026-07-30T02:00:00Z"
        )
        try coreExpect(!relogin.enabled, "needsRelogin 必须禁用")
        try coreExpect(
            relogin.verificationStatus == .needsRelogin,
            "needsRelogin 状态必须保留"
        )
    }

    // MARK: - 设备码登录 (全部 mock session, 禁真实外网)

    /// 按 URL 分桶计数的假 URLSession, handler 收到该 URL 第 N 次调用序号.
    final class CountingMockSession: URLSessionProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var recordedRequests: [URLRequest] = []
        let handler: (URLRequest, Int) throws -> (Data, URLResponse)

        init(handler: @escaping (URLRequest, Int) throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let nth = record(request)
            return try handler(request, nth)
        }

        /// 记录请求并返回该 URL 的调用序号; 同步方法避开 async 上下文锁限制.
        private func record(_ request: URLRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let key = request.url?.absoluteString ?? ""
            counts[key, default: 0] += 1
            recordedRequests.append(request)
            return counts[key] ?? 0
        }
    }

    /// 线程安全的值盒子, 供 @Sendable 回调回传捕获.
    final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    static func httpResponse(
        _ request: URLRequest, _ code: Int
    ) -> URLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: code,
            httpVersion: nil, headerFields: nil
        )!
    }

    /// 构造未签名的测试 JWT (仅 payload 有效).
    static func makeUnsignedJWT(payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(b64)."
    }

    static func requestBodyString(_ request: URLRequest?) -> String {
        guard let data = request?.httpBody else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// stdin 注入: 凭证经管道传给子进程 (gh --with-token 的依赖能力).
    static func probeStandardInputPipesToProcess() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(
            executablePath: "/bin/cat",
            arguments: [],
            standardInput: "fixture-token-123\n"
        )
        try coreExpect(
            result == .success(output: "fixture-token-123"),
            "stdin 必须原样到达子进程, got \(result)"
        )
    }

    // MARK: Codex 设备码流程

    /// PKCE code_verifier: 43 字符 base64url, 两次生成不相同.
    static func codexPKCEVerifierFormat() throws {
        let v1 = CodexPKCE.codeVerifier()
        let v2 = CodexPKCE.codeVerifier()
        try coreExpect(v1.count == 43, "verifier 必须 43 字符, got \(v1.count)")
        let pattern = #"^[A-Za-z0-9\-_]+$"#
        try coreExpect(
            v1.range(of: pattern, options: .regularExpression) != nil,
            "verifier 必须只含 base64url 字符, got \(v1)"
        )
        try coreExpect(v1 != v2, "两次生成必须不同")
    }

    /// Codex 申请请求: POST JSON client_id; 解析 device_auth_id/user_code.
    static func codexDeviceStartRequestAndParse() throws {
        let request = CodexDeviceFlow.startRequest()
        try coreExpect(request.httpMethod == "POST", "必须是 POST")
        try coreExpect(
            request.url == CodexDeviceFlow.userCodeURL,
            "必须指向 deviceauth/usercode"
        )
        let body = requestBodyString(request)
        try coreExpect(
            body.contains(#""client_id":"app_EMoamEEZ73f0CkXaXp7hrann""#),
            "body 必须带 client_id, got \(body)"
        )
        try coreExpect(
            request.value(forHTTPHeaderField: "Content-Type") == "application/json",
            "Content-Type 必须是 application/json"
        )

        guard case .success(let auth) = CodexDeviceFlow.parseStartResponse(
            Data(#"{"device_auth_id":"da-1","user_code":"WXYZ-00"}"#.utf8),
            statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("合法响应必须解析成功")
        }
        try coreExpect(auth.deviceCode == "da-1", "device_auth_id 不符")
        try coreExpect(auth.userCode == "WXYZ-00", "user_code 不符")
        try coreExpect(
            auth.verificationURL.absoluteString == "https://auth.openai.com/codex/device",
            "验证页 URL 不符: \(auth.verificationURL)"
        )
        try coreExpect(auth.interval == 5, "缺省 interval 必须 5")
        try coreExpect(auth.expiresIn == 900, "缺省 expires_in 必须 900")

        guard case .success(let custom) = CodexDeviceFlow.parseStartResponse(
            Data(
                #"{"device_auth_id":"da","user_code":"uc","interval":2,"expires_in":60}"#
                    .utf8
            ),
            statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("带 interval 响应必须解析成功")
        }
        try coreExpect(
            custom.interval == 2 && custom.expiresIn == 60,
            "服务端 interval/expires_in 必须生效"
        )
        guard case .failure = CodexDeviceFlow.parseStartResponse(
            Data("{}".utf8), statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("缺字段必须失败")
        }
        try coreExpect(
            CodexDeviceFlow.parseStartResponse(Data(), statusCode: 500)
                == .failure(.httpError(statusCode: 500)),
            "500 必须 httpError"
        )
    }

    /// 轮询与换码编解码: 403/404 pending, 200 带 code_verifier,
    /// 缺省回落本地 PKCE; 换码表单带齐 grant_type/redirect_uri/code_verifier.
    static func codexDevicePollAndExchangeParsing() throws {
        let pollRequest = CodexDeviceFlow.pollRequest(
            deviceAuthID: "da-1", userCode: "WXYZ-00"
        )
        let body = requestBodyString(pollRequest)
        try coreExpect(
            body.contains(#""device_auth_id":"da-1""#),
            "轮询必须带 device_auth_id, got \(body)"
        )
        try coreExpect(
            body.contains(#""user_code":"WXYZ-00""#),
            "轮询必须带 user_code, got \(body)"
        )

        for pendingCode in [403, 404] {
            try coreExpect(
                CodexDeviceFlow.parsePollResponse(Data(), statusCode: pendingCode)
                    == .success(.pending),
                "\(pendingCode) 必须 pending"
            )
        }
        let granted = CodexDeviceFlow.parsePollResponse(
            Data(#"{"authorization_code":"ac-1","code_verifier":"cv-1"}"#.utf8),
            statusCode: 200
        )
        try coreExpect(
            granted == .success(.authorized(
                CodexDeviceFlow.DeviceGrant(
                    authorizationCode: "ac-1", codeVerifier: "cv-1"
                )
            )),
            "200 必须 authorized, got \(granted)"
        )
        // 服务端缺省 code_verifier 时回落本地 PKCE 生成
        guard case .success(.authorized(let fallback)) = CodexDeviceFlow
            .parsePollResponse(
                Data(#"{"authorization_code":"ac-2"}"#.utf8), statusCode: 200
            ) else {
            throw CoreTestFailure.expectation("缺 verifier 必须回落生成")
        }
        try coreExpect(
            fallback.codeVerifier.count == 43,
            "回落 verifier 必须 43 字符"
        )
        guard case .failure(.invalidResponse) = CodexDeviceFlow.parsePollResponse(
            Data("{}".utf8), statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("缺 authorization_code 必须失败")
        }
        try coreExpect(
            CodexDeviceFlow.parsePollResponse(Data(), statusCode: 500)
                == .failure(.httpError(statusCode: 500)),
            "500 必须 httpError"
        )

        let grant = CodexDeviceFlow.DeviceGrant(
            authorizationCode: "ac-1", codeVerifier: "cv-1"
        )
        let exchangeBody = requestBodyString(
            CodexDeviceFlow.exchangeRequest(grant)
        )
        for fragment in [
            "grant_type=authorization_code",
            "client_id=app_EMoamEEZ73f0CkXaXp7hrann",
            "code=ac-1",
            "redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback",
            "code_verifier=cv-1",
        ] {
            try coreExpect(
                exchangeBody.contains(fragment),
                "换码表单缺少 \(fragment), got \(exchangeBody)"
            )
        }
        let tokenJSON = """
            {"id_token":"it","access_token":"at","refresh_token":"rt"}
            """
        let fixedReceived = Date(timeIntervalSince1970: 1_752_000_000)
        try coreExpect(
            CodexDeviceFlow.parseTokenResponse(
                Data(tokenJSON.utf8),
                statusCode: 200,
                receivedAt: fixedReceived
            ) == .success(CodexDeviceFlow.TokenSet(
                idToken: "it",
                accessToken: "at",
                refreshToken: "rt",
                receivedAt: fixedReceived
            )),
            "三令牌齐备必须解析成功"
        )
        guard case .failure(.invalidResponse) = CodexDeviceFlow
            .parseTokenResponse(
                Data(#"{"id_token":"it","access_token":"at"}"#.utf8),
                statusCode: 200
            ) else {
            throw CoreTestFailure.expectation("缺 refresh_token 必须失败")
        }
    }

    /// id_token claim 提取: namespaced 优先, 顶层其次, organizations 兜底.
    static func codexIDTokenClaimsParsing() throws {
        let namespaced = try makeUnsignedJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"],
            "email": "u@example.com",
        ])
        try coreExpect(
            CodexIDTokenParser.accountID(of: namespaced) == "acct-1",
            "namespaced claim 必须优先"
        )
        try coreExpect(
            CodexIDTokenParser.email(of: namespaced) == "u@example.com",
            "email 必须提取"
        )
        let topLevel = try makeUnsignedJWT(payload: [
            "chatgpt_account_id": "acct-2",
        ])
        try coreExpect(
            CodexIDTokenParser.accountID(of: topLevel) == "acct-2",
            "顶层 claim 必须兜底"
        )
        let orgs = try makeUnsignedJWT(payload: [
            "organizations": [["id": "org-9"]],
        ])
        try coreExpect(
            CodexIDTokenParser.accountID(of: orgs) == "org-9",
            "organizations 必须兜底"
        )
        let none = try makeUnsignedJWT(payload: ["sub": "x"])
        try coreExpect(
            CodexIDTokenParser.accountID(of: none) == nil,
            "无 claim 必须 nil"
        )
        try coreExpect(
            CodexIDTokenParser.accountID(of: "not-a-jwt") == nil,
            "非法 JWT 必须 nil"
        )
    }

    /// 全流程状态机: usercode -> poll 403 pending -> poll 200 -> 换码 -> 入库.
    static func codexDeviceFullFlowStoresAccount() async throws {
        let idToken = try makeUnsignedJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-42"],
            "email": "dev@example.com",
        ])
        let session = CountingMockSession { request, nth in
            let url = request.url?.absoluteString ?? ""
            switch url {
            case CodexDeviceFlow.userCodeURL.absoluteString:
                let json = """
                    {"device_auth_id":"da-1","user_code":"WXYZ-00","interval":0}
                    """
                return (Data(json.utf8), httpResponse(request, 200))
            case CodexDeviceFlow.deviceTokenURL.absoluteString:
                if nth == 1 {
                    return (Data(), httpResponse(request, 403))
                }
                let json = #"{"authorization_code":"ac-1","code_verifier":"cv-1"}"#
                return (Data(json.utf8), httpResponse(request, 200))
            default:
                let json = """
                    {"id_token":"\(idToken)","access_token":"at-1",
                     "refresh_token":"rt-1"}
                    """
                return (Data(json.utf8), httpResponse(request, 200))
            }
        }
        let box = LockedBox<DeviceAuthorization?>(nil)
        let result = await CodexDeviceFlow().login(session: session) { auth in
            box.set(auth)
        }
        guard case .success(let account) = result else {
            throw CoreTestFailure.expectation("全流程必须成功, got \(result)")
        }
        try coreExpect(account.accountID == "acct-42", "账号 id 不符")
        try coreExpect(account.email == "dev@example.com", "email 不符")
        try coreExpect(account.refreshToken == "rt-1", "refresh_token 不符")
        try coreExpect(account.accessToken == "at-1", "access_token 不符")
        try coreExpect(account.idToken == idToken, "id_token 不符")
        try coreExpect(
            box.value?.userCode == "WXYZ-00",
            "onAuthorization 必须回传验证码"
        )
        // 换码请求必须带服务端下发的 code_verifier
        let exchangeRequest = session.requests.last {
            $0.url == CodexDeviceFlow.oauthTokenURL
        }
        try coreExpect(
            requestBodyString(exchangeRequest).contains("code_verifier=cv-1"),
            "换码必须带服务端 code_verifier"
        )
        // 入库: 复用账号库合并, 结果必须通过结构校验
        guard case .success(let merged) = CodexAccountsLibrary.merging(
            existingJSON: nil, account: account
        ) else {
            throw CoreTestFailure.expectation("账号库合并必须成功")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyCodexAccountsJSON(merged) == .ok,
            "入库 JSON 必须通过结构校验"
        )
        try coreExpect(
            CodexAccountsLibrary.accountIDs(of: merged) == ["acct-42"],
            "入库账号列表不符"
        )
        let summary = CodexAccountsLibrary.summary(of: merged)
        try coreExpect(
            summary.count == 1 && summary.emailPrefixes == ["dev"],
            "摘要不符: \(summary)"
        )
    }

    /// 设备码换码保留服务端 expires_in 和 receivedAt, 不丢失过期信息.
    static func codexDeviceFlowPreservesExpiresIn() async throws {
        let idToken = try makeUnsignedJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-ei"],
            "email": "ei@example.com",
        ])
        let session = CountingMockSession { request, nth in
            let url = request.url?.absoluteString ?? ""
            switch url {
            case CodexDeviceFlow.userCodeURL.absoluteString:
                let json = #"{"device_auth_id":"da-1","user_code":"WX-00","interval":0}"#
                return (Data(json.utf8), httpResponse(request, 200))
            case CodexDeviceFlow.deviceTokenURL.absoluteString:
                if nth == 1 {
                    return (Data(), httpResponse(request, 403))
                }
                let json = #"{"authorization_code":"ac-1","code_verifier":"cv-1"}"#
                return (Data(json.utf8), httpResponse(request, 200))
            default:
                let json = """
                    {"id_token":"\(idToken)","access_token":"at-1",\
                    "refresh_token":"rt-1","expires_in":7200}
                    """
                return (Data(json.utf8), httpResponse(request, 200))
            }
        }
        let result = await CodexDeviceFlow().login(session: session) { _ in }
        guard case .success(let account) = result else {
            throw CoreTestFailure.expectation("换码应成功, got \(result)")
        }
        try coreExpect(
            account.expiresIn == 7200,
            "expires_in 必须保留: \(account.expiresIn ?? -1)"
        )
        // receivedAt 由 exchange() 内部 Date() 写入, 非空即保留
        try coreExpect(
            account.receivedAt <= Date(),
            "receivedAt 应为换码时刻"
        )
        // 按 expires_in > JWT exp > 1 小时 计算过期时间, expires_in 优先
        let expiresAt = CodexTokenExpiry.expiresAt(
            from: CodexTokenResponse(
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                idToken: account.idToken,
                expiresIn: account.expiresIn,
                receivedAt: account.receivedAt
            ),
            jwtExp: CodexTokenExpiry.jwtExp(of: account.idToken)
        )
        let expected = account.receivedAt.addingTimeInterval(7200)
        try coreExpect(
            expiresAt == expected,
            "expires_in 优先计算过期时间: \(expiresAt) != \(expected)"
        )
    }

    /// 过期时间三层优先级: 有效 expires_in > JWT exp (未来) > 1 小时回落.
    static func codexExpiryPriorityExpiresInOverJWTAndFallback() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_750_000_000)

        // 1. expires_in 优先于 JWT exp
        let jwtWithExp = try makeUnsignedJWT(payload: [
            "exp": receivedAt.addingTimeInterval(9999).timeIntervalSince1970,
        ])
        let withBoth = CodexTokenResponse(
            accessToken: "at", refreshToken: nil, idToken: jwtWithExp,
            expiresIn: 1800, receivedAt: receivedAt
        )
        try coreExpect(
            CodexTokenExpiry.expiresAt(
                from: withBoth, jwtExp: CodexTokenExpiry.jwtExp(of: jwtWithExp)
            ) == receivedAt.addingTimeInterval(1800),
            "expires_in 必须优先于 JWT exp"
        )

        // 2. 无 expires_in 时使用 JWT exp (未来)
        let futureExp = receivedAt.addingTimeInterval(5400).timeIntervalSince1970
        let jwtOnly = CodexTokenResponse(
            accessToken: "at", refreshToken: nil, idToken: nil,
            expiresIn: nil, receivedAt: receivedAt
        )
        try coreExpect(
            CodexTokenExpiry.expiresAt(from: jwtOnly, jwtExp: futureExp)
                == receivedAt.addingTimeInterval(5400),
            "无 expires_in 时必须使用 JWT exp"
        )

        // 3. 两者都缺失: 回落 1 小时
        let neither = CodexTokenResponse(
            accessToken: "at", refreshToken: nil, idToken: nil,
            expiresIn: nil, receivedAt: receivedAt
        )
        try coreExpect(
            CodexTokenExpiry.expiresAt(from: neither, jwtExp: nil)
                == receivedAt.addingTimeInterval(3600),
            "两者缺失必须回落 1 小时"
        )
    }

    /// 错误路径可诊断: 申请网络失败, 轮询网络失败, 换码 500,
    /// id_token 缺账号 id 均 fail-closed.
    static func codexDeviceErrorPaths() async throws {
        let flow = CodexDeviceFlow()
        let startNetFail = CountingMockSession { _, _ in
            throw URLError(.timedOut)
        }
        let startResult = await flow.start(session: startNetFail)
        try coreExpect(
            startResult == .failure(.networkUnreachable),
            "申请网络错误必须 networkUnreachable, got \(startResult)"
        )

        let pollNetFail = CountingMockSession { _, _ in
            throw URLError(.secureConnectionFailed)
        }
        let auth = DeviceAuthorization(
            deviceCode: "da-1", userCode: "WXYZ-00",
            verificationURL: CodexDeviceFlow.verificationURL,
            interval: 0, expiresIn: 60
        )
        let pollResult = await flow.pollUntilAuthorized(
            auth, session: pollNetFail
        )
        try coreExpect(
            pollResult == .failure(.networkUnreachable),
            "轮询网络错误必须 networkUnreachable, got \(pollResult)"
        )

        let grant = CodexDeviceFlow.DeviceGrant(
            authorizationCode: "ac-1", codeVerifier: "cv-1"
        )
        let exchange500 = CountingMockSession { request, _ in
            (Data(), httpResponse(request, 500))
        }
        let exchangeResult = await flow.exchange(grant, session: exchange500)
        try coreExpect(
            exchangeResult == .failure(.httpError(statusCode: 500)),
            "换码 500 必须 httpError, got \(exchangeResult)"
        )

        let noAccountJWT = try makeUnsignedJWT(payload: ["sub": "x"])
        let noAccountSession = CountingMockSession { request, _ in
            let json = """
                {"id_token":"\(noAccountJWT)","access_token":"at",
                 "refresh_token":"rt"}
                """
            return (Data(json.utf8), httpResponse(request, 200))
        }
        let noAccount = await flow.exchange(grant, session: noAccountSession)
        guard case .failure(.invalidResponse) = noAccount else {
            throw CoreTestFailure.expectation(
                "id_token 缺账号 id 必须 invalidResponse, got \(noAccount)"
            )
        }
    }

    /// 设备码已过期: 不发任何轮询请求即 authorizationExpired.
    static func codexDeviceExpiredSkipsPolling() async throws {
        let session = CountingMockSession { request, _ in
            (Data(), httpResponse(request, 200))
        }
        let expired = DeviceAuthorization(
            deviceCode: "da-1", userCode: "WXYZ-00",
            verificationURL: CodexDeviceFlow.verificationURL,
            interval: 0, expiresIn: 0
        )
        let result = await CodexDeviceFlow().pollUntilAuthorized(
            expired, session: session
        )
        try coreExpect(
            result == .failure(.authorizationExpired),
            "过期必须 authorizationExpired, got \(result)"
        )
        try coreExpect(session.requests.isEmpty, "已过期不得发起轮询请求")
    }

}
