import Foundation
@testable import BruceOnboardingCore

// MARK: - CredentialStateReducerTests

/// S5c / Task 16: CredentialStateReducer 表驱动纯状态变迁测试.
/// 不触碰 Keychain / OAuth / Task; 只断言枚举归一与字段.
enum CredentialStateReducerTests {
    static func runAll() throws {
        try resolveGateTable()
        try hotPathReuseTable()
        try applyLoginIncrementsRevisionAndClearsBlocked()
        try applyNeedsReauthorizationClearsTokensAndBumpsRevision()
        try applyRefreshResultTable()
        try applyStorageSuccessAndFailureTable()
        try pendingRecordIfCurrentTable()
        try seededUsesResolvedAuthorizationState()
        print("CredentialStateReducer tests passed: 8")
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_752_000_000)

    private static func connectedState(
        access: String = "at",
        refresh: String = "rt",
        expiresIn: TimeInterval = 3600,
        storageBlocked: Bool = false,
        refreshNotBefore: Date? = nil,
        revision: Int = 0,
        email: String? = "user@example.com",
        origin: CodexCredentialOrigin = .Bruce
    ) -> CredentialAccountState {
        CredentialAccountState(
            accessToken: access,
            refreshToken: refresh,
            idToken: "id",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(expiresIn),
            authorizationState: .connected,
            storageBlocked: storageBlocked,
            refreshNotBefore: refreshNotBefore,
            updatedAt: fixedNow,
            revision: revision,
            email: email,
            credentialOrigin: origin
        )
    }

    // MARK: resolveGate

    private static func resolveGateTable() throws {
        struct Case {
            let name: String
            let state: CredentialAccountState
            let force: Bool
            let nowOffset: TimeInterval
            let expected: CredentialResolveGate
        }
        let accountID = "acc-1"
        let cases: [Case] = [
            Case(
                name: "needsReauthorization blocks even force",
                state: CredentialAccountState(authorizationState: .needsReauthorization),
                force: true,
                nowOffset: 0,
                expected: .resolved(.failure(.needsReauthorization(accountID: accountID)))
            ),
            Case(
                name: "storageBlocked reuses unexpired token",
                state: connectedState(expiresIn: 1, storageBlocked: true),
                force: true,
                nowOffset: 0,
                expected: .resolved(.success(
                    accessToken: "at",
                    expiresAt: fixedNow.addingTimeInterval(1)
                ))
            ),
            Case(
                name: "storageBlocked rejects exactly expired",
                state: connectedState(expiresIn: 0, storageBlocked: true),
                force: true,
                nowOffset: 0,
                expected: .resolved(.failure(.storageBlocked(accountID: accountID)))
            ),
            Case(
                name: "storageBlocked rejects past expiry",
                state: connectedState(expiresIn: -1, storageBlocked: true),
                force: false,
                nowOffset: 0,
                expected: .resolved(.failure(.storageBlocked(accountID: accountID)))
            ),
            Case(
                name: "not-before reuses unexpired when not force",
                state: connectedState(
                    expiresIn: 120,
                    refreshNotBefore: fixedNow.addingTimeInterval(60)
                ),
                force: false,
                nowOffset: 0,
                expected: .resolved(.success(
                    accessToken: "at",
                    expiresAt: fixedNow.addingTimeInterval(120)
                ))
            ),
            Case(
                name: "not-before deferred when token expired",
                state: connectedState(
                    expiresIn: -1,
                    refreshNotBefore: fixedNow.addingTimeInterval(60)
                ),
                force: false,
                nowOffset: 0,
                expected: .resolved(.failure(
                    .refreshFailed(accountID: accountID, reason: .deferred)
                ))
            ),
            Case(
                name: "reuse outside refresh window",
                state: connectedState(expiresIn: 61),
                force: false,
                nowOffset: 0,
                expected: .resolved(.success(
                    accessToken: "at",
                    expiresAt: fixedNow.addingTimeInterval(61)
                ))
            ),
            Case(
                name: "needs refresh at exactly 60s window",
                state: connectedState(expiresIn: 60),
                force: false,
                nowOffset: 0,
                expected: .needsNetworkRefresh(refreshToken: "rt")
            ),
            Case(
                name: "force refresh ignores window",
                state: connectedState(expiresIn: 3600),
                force: true,
                nowOffset: 0,
                expected: .needsNetworkRefresh(refreshToken: "rt")
            ),
            Case(
                name: "missing refresh token → needs reauth",
                state: CredentialAccountState(
                    accessToken: "at",
                    refreshToken: nil,
                    accessTokenExpiresAt: fixedNow.addingTimeInterval(10),
                    authorizationState: .connected
                ),
                force: false,
                nowOffset: 0,
                expected: .resolved(.failure(.needsReauthorization(accountID: accountID)))
            ),
            Case(
                name: "force bypasses not-before when token needs refresh",
                state: connectedState(
                    expiresIn: 10,
                    refreshNotBefore: fixedNow.addingTimeInterval(60)
                ),
                force: true,
                nowOffset: 0,
                expected: .needsNetworkRefresh(refreshToken: "rt")
            ),
        ]

        for c in cases {
            let gate = CredentialStateReducer.resolveGate(
                state: c.state,
                accountID: accountID,
                now: fixedNow.addingTimeInterval(c.nowOffset),
                force: c.force
            )
            try reducerExpect(
                gate == c.expected,
                "resolveGate[\(c.name)]: got \(gate), want \(c.expected)"
            )
        }
    }

    // MARK: hotPathReuse

    private static func hotPathReuseTable() throws {
        let reuse = CredentialStateReducer.hotPathReuse(
            state: connectedState(expiresIn: 61),
            now: fixedNow
        )
        try reducerExpect(reuse?.accessToken == "at", "61s 应热路径复用")
        let noReuse = CredentialStateReducer.hotPathReuse(
            state: connectedState(expiresIn: 60),
            now: fixedNow
        )
        try reducerExpect(noReuse == nil, "60s 窗口不得热路径复用")
        let reauth = CredentialStateReducer.hotPathReuse(
            state: CredentialAccountState(authorizationState: .needsReauthorization),
            now: fixedNow
        )
        try reducerExpect(reauth == nil, "needsReauth 不得热路径复用")
    }

    // MARK: login

    private static func applyLoginIncrementsRevisionAndClearsBlocked() throws {
        let previous = connectedState(
            storageBlocked: true,
            revision: 3,
            email: "old@x.com"
        )
        let applied = CredentialStateReducer.applyLogin(
            previous: previous,
            accountID: "acc-1",
            email: "new@x.com",
            accessToken: "new-at",
            refreshToken: "new-rt",
            idToken: "new-id",
            expiresAt: fixedNow.addingTimeInterval(3600),
            now: fixedNow
        )
        try reducerExpect(applied.state.revision == 4, "登录必须递增 revision")
        try reducerExpect(applied.state.storageBlocked == false, "登录清除 blocked")
        try reducerExpect(applied.state.pendingRecord == nil, "登录清除 pending")
        try reducerExpect(applied.state.email == "new@x.com", "登录写入 email")
        try reducerExpect(applied.state.credentialOrigin == .Bruce, "登录 origin=Bruce")
        try reducerExpect(applied.state.authorizationState == .connected, "登录 connected")
        try reducerExpect(applied.record.accessToken == "new-at", "record 含 access")
        try reducerExpect(applied.record.refreshToken == "new-rt", "record 含 refresh")
    }

    // MARK: needs reauth

    private static func applyNeedsReauthorizationClearsTokensAndBumpsRevision() throws {
        let state = connectedState(revision: 2, email: "u@x.com", origin: .legacyCCSwitchDiscovery)
        let applied = CredentialStateReducer.applyNeedsReauthorization(
            state: state,
            accountID: "acc-1",
            now: fixedNow
        )
        try reducerExpect(applied.state.revision == 3, "reauth 递增 revision")
        try reducerExpect(applied.state.accessToken == nil, "清空 access")
        try reducerExpect(applied.state.refreshToken == nil, "清空 refresh")
        try reducerExpect(applied.state.idToken == nil, "清空 id")
        try reducerExpect(applied.state.accessTokenExpiresAt == nil, "清空 expires")
        try reducerExpect(
            applied.state.authorizationState == .needsReauthorization,
            "状态 needsReauthorization"
        )
        try reducerExpect(applied.state.email == "u@x.com", "保留 email")
        try reducerExpect(
            applied.state.credentialOrigin == .legacyCCSwitchDiscovery,
            "保留 origin"
        )
        try reducerExpect(applied.state.pendingRecord != nil, "设置 pending")
        try reducerExpect(applied.state.pendingRevision == 3, "pendingRevision 对齐")
        try reducerExpect(applied.record.accessToken == nil, "record 无 token")
        try reducerExpect(
            applied.record.authorizationState == .needsReauthorization,
            "record 状态"
        )
    }

    // MARK: refresh result

    private static func applyRefreshResultTable() throws {
        let base = connectedState(email: "u@x.com", origin: .Bruce)

        // invalid_grant → 统一 reauth 入口标志, 不直接改 state
        let invalidGrant = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.invalidGrant),
            now: fixedNow
        )
        try reducerExpect(
            invalidGrant.requiresNeedsReauthorizationPersist,
            "invalid_grant 必须走统一 reauth 入口"
        )
        try reducerExpect(
            invalidGrant.state == base,
            "invalid_grant 不在 apply 内直接改 state (防双增 revision)"
        )
        try reducerExpect(
            invalidGrant.resolution == .failure(.needsReauthorization(accountID: "acc-1")),
            "invalid_grant 决议"
        )

        // rate limit with retryAfter
        let rateLimited = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.rateLimit(retryAfter: 120)),
            now: fixedNow
        )
        try reducerExpect(
            rateLimited.state.refreshNotBefore == fixedNow.addingTimeInterval(120),
            "rateLimit 使用 retryAfter"
        )
        try reducerExpect(
            rateLimited.resolution == .failure(
                .refreshFailed(accountID: "acc-1", reason: .rateLimited)
            ),
            "rateLimit 决议 reason"
        )

        // rate limit default 300
        let rateDefault = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.rateLimit(retryAfter: nil)),
            now: fixedNow
        )
        try reducerExpect(
            rateDefault.state.refreshNotBefore == fixedNow.addingTimeInterval(300),
            "rateLimit 默认 300s"
        )

        // server error
        let server = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.serverError(503)),
            now: fixedNow
        )
        try reducerExpect(
            server.resolution == .failure(
                .refreshFailed(accountID: "acc-1", reason: .serviceUnavailable)
            ),
            "serverError → serviceUnavailable"
        )
        try reducerExpect(
            server.state.refreshNotBefore == fixedNow.addingTimeInterval(300),
            "serverError 退避 300s"
        )

        // network
        let network = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.networkUnreachable),
            now: fixedNow
        )
        try reducerExpect(
            network.resolution == .failure(
                .refreshFailed(accountID: "acc-1", reason: .networkError)
            ),
            "network → networkError"
        )

        // httpStatus also networkError
        let http = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.httpStatus(418)),
            now: fixedNow
        )
        try reducerExpect(
            http.resolution == .failure(
                .refreshFailed(accountID: "acc-1", reason: .networkError)
            ),
            "httpStatus → networkError"
        )

        // invalidResponse / cancelled: no state mutation
        let invalid = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.invalidResponse("bad")),
            now: fixedNow
        )
        try reducerExpect(invalid.state == base, "invalidResponse 不改 state")
        try reducerExpect(
            invalid.resolution == .failure(
                .refreshFailed(accountID: "acc-1", reason: .invalidResponse)
            ),
            "invalidResponse reason"
        )
        let cancelled = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .failure(.cancelled),
            now: fixedNow
        )
        try reducerExpect(cancelled.state == base, "cancelled 不改 state")

        // success: updates tokens, preserves email/origin, keeps old refresh if missing
        let success = CredentialStateReducer.applyRefreshResult(
            state: base,
            accountID: "acc-1",
            result: .success(CodexTokenResponse(
                accessToken: "at-new",
                refreshToken: nil,
                idToken: "id-new",
                expiresIn: 3600,
                receivedAt: fixedNow
            )),
            now: fixedNow
        )
        try reducerExpect(success.state.accessToken == "at-new", "success 新 access")
        try reducerExpect(
            success.state.refreshToken == "rt",
            "缺新 refresh 时保留旧 refresh"
        )
        try reducerExpect(success.state.idToken == "id-new", "success 新 id")
        try reducerExpect(success.state.email == "u@x.com", "success 保留 email")
        try reducerExpect(success.state.credentialOrigin == .Bruce, "success 保留 origin")
        try reducerExpect(success.state.refreshNotBefore == nil, "success 清 not-before")
        try reducerExpect(success.recordToPersist != nil, "success 需持久化")
        try reducerExpect(
            success.recordToPersist?.email == "u@x.com",
            "persist record 用缓存 email"
        )
        try reducerExpect(
            !success.requiresNeedsReauthorizationPersist,
            "success 不走 reauth"
        )
        if case .success(let at, _) = success.resolution {
            try reducerExpect(at == "at-new", "success 决议 token")
        } else {
            throw ReducerTestFailure.expectation("success 决议应为 success")
        }
    }

    // MARK: storage

    private static func applyStorageSuccessAndFailureTable() throws {
        var state = connectedState(revision: 5)
        state.storageBlocked = true
        state.pendingRecord = CodexAccountRecord(
            accountID: "acc-1",
            authorizationState: .needsReauthorization,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        state.pendingRevision = 5

        let ok = CredentialStateReducer.applyStorageSuccess(
            state: state, expectedRevision: 5
        )
        try reducerExpect(ok != nil, "revision 匹配应成功")
        try reducerExpect(ok?.storageBlocked == false, "成功解除 blocked")
        try reducerExpect(ok?.pendingRecord == nil, "成功清 pending")

        let stale = CredentialStateReducer.applyStorageSuccess(
            state: state, expectedRevision: 4
        )
        try reducerExpect(stale == nil, "旧 revision 不得清 pending")

        let failed = CredentialStateReducer.applyStorageFailure(
            state: connectedState(revision: 2),
            record: CodexAccountRecord(
                accountID: "acc-1",
                accessToken: "at",
                refreshToken: "rt",
                accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
                authorizationState: .connected,
                credentialOrigin: .Bruce,
                updatedAt: fixedNow
            ),
            revision: 2
        )
        try reducerExpect(failed.storageBlocked, "失败置 blocked")
        try reducerExpect(failed.pendingRecord != nil, "失败保留 pending")
        try reducerExpect(failed.pendingRevision == 2, "pendingRevision")
    }

    private static func pendingRecordIfCurrentTable() throws {
        var state = connectedState(revision: 1)
        try reducerExpect(
            CredentialStateReducer.pendingRecordIfCurrent(state: state) == nil,
            "无 pending 返回 nil"
        )
        let record = CodexAccountRecord(
            accountID: "acc-1",
            authorizationState: .needsReauthorization,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        state.pendingRecord = record
        state.pendingRevision = 1
        try reducerExpect(
            CredentialStateReducer.pendingRecordIfCurrent(state: state) == record,
            "revision 匹配返回 pending"
        )
        state.revision = 2
        try reducerExpect(
            CredentialStateReducer.pendingRecordIfCurrent(state: state) == nil,
            "revision 前进后 pending 失效"
        )
    }

    private static func seededUsesResolvedAuthorizationState() throws {
        // incomplete connected record → fail-closed needsReauthorization
        let incomplete = CodexAccountRecord(
            accountID: "acc-1",
            accessToken: "at",
            refreshToken: nil,
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        let seeded = CredentialAccountState.seeded(from: incomplete)
        try reducerExpect(
            seeded.authorizationState == .needsReauthorization,
            "残缺 record 必须 fail-closed"
        )
        try reducerExpect(seeded.email == incomplete.email, "seed 拷贝 email")
        try reducerExpect(
            seeded.credentialOrigin == .Bruce,
            "seed 拷贝 origin"
        )
    }
}

// MARK: - helpers

private enum ReducerTestFailure: Error, CustomStringConvertible {
    case expectation(String)
    var description: String {
        switch self {
        case .expectation(let message): return message
        }
    }
}

private func reducerExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw ReducerTestFailure.expectation(message) }
}
