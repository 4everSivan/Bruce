import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

// MARK: - Merger + previous qualification

extension RefreshSchedulerHarness {
// MARK: - 任务 7: 四源快照合并器

/// 任务 7 固定测试向量 (与 collect_usage.py _codex_service_id 对齐).

/// 构造单账号 Codex service (任务 7 契约字段).
static func mergerCodexService(
    id: String,
    status: String,
    usedPercent: Double,
    capturedAt: String?,
    freshness: String?,
    failureKind: String? = nil,
    note: String? = nil
) -> JSONValue {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "name": .string("Codex · user"),
        "app": .string("codex"),
        "status": .string(status),
        "kind": .string("windows"),
        "plan": .string("team"),
        "windows": .array([
            .object([
                "label": .string("5小时窗口"),
                "usedPercent": .double(usedPercent),
                "windowMinutes": .integer(300),
                "resetsAt": .null,
            ]),
        ]),
    ]
    if let capturedAt {
        object["capturedAt"] = .string(capturedAt)
    }
    if let freshness {
        object["freshness"] = .string(freshness)
    }
    if let failureKind {
        object["failureKind"] = .string(failureKind)
    }
    if let note {
        object["note"] = .string(note)
    }
    return .object(object)
}

/// 构造 artifact: codex services + 非 codex service + agents.
static func mergerArtifact(
    codexServices: [JSONValue],
    generatedAt: String,
    includeKimi: Bool = true
) -> JSONValue {
    var services = codexServices
    if includeKimi {
        services.append(.object([
            "id": .string("kimi"),
            "name": .string("Kimi"),
            "status": .string("ok"),
            "kind": .string("windows"),
            "windows": .array([]),
        ]))
    }
    return .object([
        "schemaVersion": .integer(1),
        "module": .string("agent-usage"),
        "generatedAt": .string(generatedAt),
        "agents": .array([
            .object([
                "id": .string("codex"),
                "name": .string("Codex"),
                "status": .string("ok"),
                "today": .object([
                    "input": .integer(100), "output": .integer(50),
                    "cacheRead": .integer(0), "cacheCreation": .integer(0),
                    "total": .integer(150),
                ]),
                "daily": .array([]),
                "hours": .array(Array(repeating: .integer(0), count: 24)),
            ]),
        ]),
        "services": .array(services),
        "totalCostUsd": .null,
    ])
}

/// 单账号 available 决议 (currentID 由 CodexAccountIdentity 生成).
static func mergerDecision(
    index: Int,
    accountID: String,
    outcome: CodexTokenDecision.Outcome
) -> CodexTokenDecision {
    CodexTokenDecision(
        index: index,
        accountID: accountID,
        serviceID: CodexAccountIdentity.serviceID(for: accountID),
        displayName: "Codex · user",
        outcome: outcome
    )
}

/// 从合并结果取 service 列表 (id -> JSONValue).
static func mergerServices(
    _ artifact: JSONValue
) throws -> [String: JSONValue] {
    guard case .object(let object) = artifact,
          case .array(let services)? = object["services"] else {
        throw RefreshTestFailure.expectation("合并结果 services 结构不符")
    }
    return Dictionary(
        uniqueKeysWithValues: services.compactMap { service -> (String, JSONValue)? in
            guard let id = service.stringId() else { return nil }
            return (id, service)
        }
    )
}

static func mergerServiceValue(
    _ artifact: JSONValue,
    id: String
) throws -> [String: JSONValue] {
    guard let service = try mergerServices(artifact)[id],
          case .object(let object) = service else {
        throw RefreshTestFailure.expectation("缺少 service \(id)")
    }
    return object
}

/// 1. previous 成功 + 本轮网络失败 -> stale 且保留旧 capturedAt.
static func codexMergerPreviousSuccessKeepsStaleData() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 45,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "本轮失败 + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("network"),
        "必须保留本轮 failureKind, got \(service["failureKind"] ?? .null)"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("旧 windows 必须保留")
    }
    try refreshExpect(used == 45, "必须保留旧窗口 45%")
}

// MARK: - 任务 4: previous 成功资格 (MERGE-01 ~ MERGE-08)

/// 任务 4 判定辅助: 本轮失败 (error + failureKind) 的 first, previous 由调用方传入.
static func mergerQualifiedCheck(
    previous: JSONValue?,
    expectedFreshness: String,
    expectedCapturedAt: String?,
    expectDiagnostic: String? = nil
) throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string(expectedFreshness),
        "freshness 应为 \(expectedFreshness), got \(service["freshness"] ?? .null)"
    )
    if let expectedCapturedAt {
        try refreshExpect(
            service["capturedAt"] == .string(expectedCapturedAt),
            "capturedAt 应为 \(expectedCapturedAt)"
        )
    } else {
        try refreshExpect(
            service["capturedAt"] == nil,
            "capturedAt 应为空"
        )
    }
    if let expectDiagnostic {
        try refreshExpect(
            result.diagnostics.contains { $0.code == expectDiagnostic },
            "应产生诊断 \(expectDiagnostic)"
        )
    }
}

// MERGE-01: previous freshness=unavailable + capturedAt -> 本轮失败 -> unavailable, 无 lastSuccessAt
static func codexMergerPreviousUnavailableNotQualified() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "unavailable",
                failureKind: "auth"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-02: previous status=error + capturedAt -> 本轮失败 -> unavailable, 无 lastSuccessAt
static func codexMergerPreviousErrorNotQualified() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "unavailable",
                failureKind: "auth"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// 旧格式必须显式 status=ok 或 status=""; 缺失 status 不能伪装为成功快照.
static func codexMergerPreviousMissingStatusNotQualified() throws {
    guard case .object(var service) = mergerCodexService(
        id: mergerService1,
        status: "ok",
        usedPercent: 21,
        capturedAt: "2026-07-28T09:00:00Z",
        freshness: nil
    ) else {
        throw RefreshTestFailure.expectation("previous fixture 不是 object")
    }
    service.removeValue(forKey: "status")
    let previous = mergerArtifact(
        codexServices: [.object(service)],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-03: legacy 格式 status=ok + capturedAt -> 本轮失败 -> stale, 继承成功时间
static func codexMergerLegacyOKQualifiedStale() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 33,
                capturedAt: "2026-07-28T08:00:00Z", freshness: nil
            ),
        ],
        generatedAt: "2026-07-28T08:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "stale",
        expectedCapturedAt: "2026-07-28T08:00:00Z"
    )
}

// MERGE-04: freshness=fresh 但 capturedAt 无效 -> 本轮失败 -> unavailable
static func codexMergerPreviousInvalidCapturedAt() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 20,
                capturedAt: "not-a-date", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-05: freshness=stale + 有效 capturedAt -> 本轮失败 -> stale, 成功时间不前移
static func codexMergerStalePreviousKeepsSuccessTime() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T07:00:00Z", freshness: "stale"
            ),
        ],
        generatedAt: "2026-07-28T07:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "stale",
        expectedCapturedAt: "2026-07-28T07:00:00Z"
    )
}

// MERGE-06: 首次失败, 无 previous -> unavailable, 无 capturedAt
static func codexMergerFirstFailureUnavailable() throws {
    try mergerQualifiedCheck(
        previous: nil,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-07: current 与 legacy 同时存在 -> 本轮失败 -> 只用合格 current, legacy 丢弃
static func codexMergerCurrentDisqualifiedLegacyDropped() throws {
    // previous: currentID 为失败 (不合格), legacyID 为成功
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "unavailable",
                failureKind: "auth"
            ),
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 80,
                capturedAt: "2026-07-28T08:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-08: legacy ID 匹配多个当前账号 -> 不复用额度, 输出诊断
static func codexMergerLegacyAmbiguousFailure() throws {
    // 两个不同 accountID 共享前 8 位 -> 相同 legacyID (歧义);
    // serviceID (SHA-256 前 16 位) 不同, 按决策生成 first services
    let accountA = "shareme-1a"
    let accountB = "shareme-1b"
    let serviceA = CodexAccountIdentity.serviceID(for: accountA)
    let serviceB = CodexAccountIdentity.serviceID(for: accountB)
    try refreshExpect(
        CodexAccountIdentity.legacyServiceID(for: accountA)
            == CodexAccountIdentity.legacyServiceID(for: accountB),
        "前置: 两账号 legacyID 必须相同"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: serviceA, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
            mergerCodexService(
                id: serviceB, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: CodexAccountIdentity.legacyServiceID(for: accountA),
                status: "ok", usedPercent: 90,
                capturedAt: "2026-07-28T08:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T08:00:00Z"
    )
    let decisions = [
        mergerDecision(index: 0, accountID: accountA, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
        mergerDecision(index: 1, accountID: accountB, outcome: .available(
            accessToken: "at2", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: decisions
    )
    // 两个 service 都不复用旧额度 (歧义)
    for id in [serviceA, serviceB] {
        let service = try mergerServiceValue(result.artifact, id: id)
        try refreshExpect(
            service["freshness"] == .string("unavailable"),
            "歧义 legacy 不得复用旧额度"
        )
        try refreshExpect(
            service["capturedAt"] == nil,
            "歧义 legacy 不得继承 capturedAt"
        )
    }
    try refreshExpect(
        result.diagnostics.contains { $0.code == "CODEX_LEGACY_AMBIGUOUS" },
        "应产生歧义诊断"
    )
}

/// 2. 无 previous + 本轮失败 -> unavailable 且没有 capturedAt.
static func codexMergerNoPreviousFailureUnavailable() throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("unavailable"),
        "无旧数据必须为 unavailable"
    )
    try refreshExpect(
        service["capturedAt"] == nil,
        "unavailable 不得有 capturedAt"
    )
    try refreshExpect(
        service["failureKind"] == .string("auth"),
        "必须写 failureKind=auth"
    )
}

/// 3. 首轮 401 + retry 成功 -> fresh.
static func codexMergerFirst401RetrySuccessFresh() throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(service["status"] == .string("ok"), "retry 成功必须覆盖 status")
    try refreshExpect(
        service["freshness"] == .string("fresh"),
        "retry 成功必须为 fresh"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T12:01:00Z"),
        "fresh 必须使用本轮 capturedAt"
    )
    // 整体状态按最终 artifact 重算, 不直接采用 retry response 状态
    try refreshExpect(
        result.recomputedStatus == .success,
        "全部 ok 时整体状态应为 success"
    )
}

/// 4. 首轮 401 + retry 401 -> stale/auth 或 unavailable/auth.
static func codexMergerRetry401StaleAuth() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 60,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "第二次 401 + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("auth"),
        "第二次 401 failureKind 必须为 auth"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "第二次 401 必须保留旧 capturedAt"
    )

    // 无 previous 时 -> unavailable/auth, 无 capturedAt.
    let noPrevious = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let unavailable = try mergerServiceValue(noPrevious.artifact, id: mergerService1)
    try refreshExpect(
        unavailable["freshness"] == .string("unavailable"),
        "第二次 401 + 无旧数据必须为 unavailable"
    )
    try refreshExpect(
        unavailable["capturedAt"] == nil,
        "unavailable 不得有 capturedAt"
    )
    try refreshExpect(
        unavailable["failureKind"] == .string("auth"),
        "unavailable 必须写 failureKind=auth"
    )
}

/// 5. token storageBlocked + previous 成功 -> stale/storage.
static func codexMergerStorageBlockedStale() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 55,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 首轮无该账号 service (storageBlocked 决议 -> 未注入 Bridge)
    let first = mergerArtifact(codexServices: [], generatedAt: "2026-07-28T12:00:00Z")
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [
            mergerDecision(index: 0, accountID: mergerAccount1, outcome: .storageBlocked),
        ]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "storageBlocked + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("storage"),
        "storageBlocked failureKind 必须为 storage, got \(service["failureKind"] ?? .null)"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "storageBlocked 必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("storageBlocked 必须保留旧 windows")
    }
    try refreshExpect(used == 55, "storageBlocked 必须保留旧窗口 55%")
}

/// 6. 删除账号后旧 service 不再出现.
static func codexMergerDeletedAccountDropped() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 45,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 70,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 本轮只有 acc-1 (acc-2 已断开, 未出现在 index)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 42,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(services[mergerService1] != nil, "当前账号必须保留")
    try refreshExpect(
        services[mergerService2] == nil,
        "已删除账号的旧 service 不得出现"
    )
}

/// 7. retry 响应缺失账号时保留旧快照.
static func codexMergerRetryMissingAccountKeepsPrevious() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 50,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 首轮 401 (unavailable/auth), retry 不含该账号 (collector 未返回)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(codexServices: [], generatedAt: "2026-07-28T12:01:00Z")
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "retry 缺失账号 + 首轮失败 + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "retry 缺失时必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("retry 缺失时必须保留旧 windows")
    }
    try refreshExpect(used == 50, "retry 缺失时必须保留旧窗口 50%")
}

/// 8. legacy ID + 本轮失败 -> 旧额度迁移到新 ID 并标记 stale.
static func codexMergerLegacyFailureMigratesToNewID() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 48,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 本轮失败, 输出必须使用新 ID (currentID)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "rateLimit", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(
        services[mergerLegacy1] == nil,
        "输出不得再出现 legacy ID"
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "legacy 迁移 + 本轮失败必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("rateLimit"),
        "legacy 迁移失败必须保留 failureKind"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "legacy 迁移必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("legacy 迁移必须保留旧 windows")
    }
    try refreshExpect(used == 48, "legacy 迁移必须保留旧窗口 48%")
}

/// 9. legacy ID + 本轮成功 -> 输出新 ID 和 fresh 数据.
static func codexMergerLegacySuccessNewIDFresh() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 48,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 30,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(
        services[mergerLegacy1] == nil,
        "成功迁移后不得残留 legacy ID"
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("fresh"),
        "legacy 迁移 + 本轮成功必须为 fresh"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T12:00:00Z"),
        "本轮成功必须使用新 capturedAt"
    )
}

/// 10. current ID 和 legacy ID 同时存在时优先 current ID.
static func codexMergerCurrentIDPreferredOverLegacy() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 80,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "fresh"
            ),
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 60,
                capturedAt: "2026-07-28T08:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(
        services[mergerLegacy1] == nil,
        "previous 中的 legacy 条目必须丢弃"
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T09:00:00Z"),
        "必须使用 current ID 的旧数据 (80%), 而非 legacy (60%)"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("current ID 旧 windows 必须保留")
    }
    try refreshExpect(used == 80, "必须保留 current ID 的旧窗口 80%")
}

/// 11. legacy ID 匹配多个账号时不跨账号复用额度.
static func codexMergerLegacyAmbiguousNoCrossAccount() throws {
    // acc-1 与 acc-2 的 legacy ID 相同 (构造账号名使前 8 位一致)
    let accountA = "shareacc-1a"
    let accountB = "shareacc-1b"
    let legacyShared = "codex_" + String(accountA.prefix(8))
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: legacyShared, status: "ok", usedPercent: 75,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 本轮两个账号都失败且没有 currentID service
    let first = mergerArtifact(codexServices: [], generatedAt: "2026-07-28T12:00:00Z")
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [
            mergerDecision(index: 0, accountID: accountA, outcome: .temporarilyUnavailable(retryAt: nil)),
            mergerDecision(index: 1, accountID: accountB, outcome: .temporarilyUnavailable(retryAt: nil)),
        ]
    )
    let services = try mergerServices(result.artifact)
    let serviceAID = CodexAccountIdentity.serviceID(for: accountA)
    let serviceBID = CodexAccountIdentity.serviceID(for: accountB)
    let serviceA = try mergerServiceValue(result.artifact, id: serviceAID)
    let serviceB = try mergerServiceValue(result.artifact, id: serviceBID)
    // 歧义时不复用旧额度 -> unavailable/tokenUnavailable, 无 capturedAt
    try refreshExpect(
        serviceA["freshness"] == .string("unavailable"),
        "legacy 歧义账号 A 不得复用旧额度"
    )
    try refreshExpect(
        serviceB["freshness"] == .string("unavailable"),
        "legacy 歧义账号 B 不得复用旧额度"
    )
    try refreshExpect(serviceA["capturedAt"] == nil, "歧义账号 A 不得有 capturedAt")
    try refreshExpect(serviceB["capturedAt"] == nil, "歧义账号 B 不得有 capturedAt")
    try refreshExpect(
        serviceA["failureKind"] == .string("tokenUnavailable"),
        "歧义账号 A failureKind 应为 tokenUnavailable"
    )
    try refreshExpect(services[legacyShared] == nil, "歧义 legacy 条目必须丢弃")
}

/// 补充: Codex services 始终按当前账号 index 排序 (低 index 失败账号也排在
/// 高 index 成功账号之前).
static func codexMergerServicesOrderedByAccountIndex() throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 30,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // acc-1 (index 0) storageBlocked 未注入 -> 合成条目必须排在 acc-2 之前
    let result = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: nil,
        decisions: [
            mergerDecision(index: 0, accountID: mergerAccount1, outcome: .storageBlocked),
            mergerDecision(index: 1, accountID: mergerAccount2, outcome: .available(
                accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
            )),
        ]
    )
    guard case .object(let object) = result.artifact,
          case .array(let services)? = object["services"] else {
        throw RefreshTestFailure.expectation("合并结果 services 结构不符")
    }
    let codexOrder = services.compactMap { service -> String? in
        guard isCodexServiceTest(service) else { return nil }
        return service.stringId()
    }
    try refreshExpect(
        codexOrder == [mergerService1, mergerService2],
        "Codex services 必须按账号 index 排序, got \(codexOrder)"
    )
}

static func isCodexServiceTest(_ value: JSONValue) -> Bool {
    guard case .object(let object) = value,
          case .string(let app)? = object["app"] else {
        return false
    }
    return app == "codex"
}

/// 补充: stale 条目不参与 quota alert 阈值穿越.
static func quotaAlertSkipsStaleEntries() throws {
    // stale Codex service 保留 85% 旧窗口, 不得触发预警
    let stale = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 85,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "stale",
                failureKind: "network"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let staleEntries = QuotaAlertEvaluator.overThresholdEntries(artifact: stale)
    try refreshExpect(
        staleEntries.isEmpty,
        "stale 条目不得触发 quota alert, got \(staleEntries)"
    )

    // fresh 同窗口仍正常报警
    let fresh = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 85,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let freshEntries = QuotaAlertEvaluator.overThresholdEntries(artifact: fresh)
    try refreshExpect(
        freshEntries.count == 1,
        "fresh 超过阈值条目必须报警, got \(freshEntries)"
    )
}
}
