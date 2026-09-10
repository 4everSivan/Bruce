# Bruce 全项目死代码流程与迁移残留审计

日期: 2026-08-24 · 基线: HEAD c616273 (工作树干净) · 方法: 5 个子系统扫描器并行取证 + 每区独立对抗性复核 (10 agent, 1718 次工具调用)

**结论概览**: 原始发现 69 条, 复核确认 64 条, 驳回 4 条 (含 1 条部分成立). 区域间重叠去重后约 61 条独立项. 直接可删代码约 550-650 行; 另有约 300 行受「补实现 or 两端同删」产品决策门控的跨端死流; 文档漂移约 150 行需改写而非删除.

本审计在 commit 99eb750 (rust-collector-dead-code-cleanup) 之后执行, 所有行号基于当前 HEAD.

> 2026-09-09 追记: 本文提出的 Antigravity dead flow 已按"两端同删"完成收敛. 下方相关文字保留历史证据, 文件行号和"待决策"表述不再代表当前实现.

**红线保护, 未列入发现** (扫描约束明确排除):

- metrics 字段集 (`cpu_user_ms`/`peak_rss_bytes`/`retry_count` 等) — 受既有规格 `incremental-collector-refresh` SHALL 条款保护
- Bridge capability 白名单 (`localSessions`/`localPricing`/`externalQuotas`) 与 Swift 授予端 — 跨进程契约
- Claude/Grok 双路径兜底 — AGENTS.md 第 7 节明示的有意兼容, 均验证可达
- `tests/fixtures/bridge/*.json` 与 `bin/*-fixture.rs` — canonical parity 工具
- Codex v1→v2 迁移机器 (~400 行) — 每次启动幂等执行, cleanupPending 重试语义要求常驻, 21 处 Harness 覆盖
- CC Switch 导入链路整体 — SettingsView 经 confirmationDialog 可达, 按钮有存在性门控, 属活路径
- verify-local.sh 的 Python 资产扫描 — b7a68b3 引入的防回归 tripwire

---

## A. 跨端死流程 — 需要产品决策 (补实现或两端同删, 不可单端动手)

1. **[疑似现网 bug] volcengine 注入凭证键名错配** — Swift 发 `access_key`/`secret_key`, Rust 要求 `accessKeyId`/`secretAccessKey`; App 注入的火山额度查询必然失败. 这是正确性问题而非死代码, 建议单独修复. [macos/BruceApp/Sources/BruceAppCore/CollectorRunInput.swift:452]
2. **[已处理] Antigravity 额度查询链路整体死亡** — Rust、Bridge、Swift 和测试中的残留已在 2026-09-09 两端同步移除, 不再补齐该 Provider.
3. **credentialUpdates 写回链路生产者死亡** — Rust 全仓无任何代码填充 `credential_updates`; Swift 整条 apply 管道生产中不可达 (~100 行). [rust/...collector-application/src/execution.rs:18]
4. **成本链恒 null 空转** — `localPricing` 能力已授予但 Rust 无任何定价实现; `todayCostUsd`/`totalCostUsd`/`costUsd` 三层消费代码惯性空转 (~35 行). 注意白名单条目本身是契约, 动的是定价实现缺失这个事实. [rust/...collector-aggregate/src/lib.rs:171]
5. **artifact `agents[].quota` 恒为 null** — 全仓唯一构造点硬编码 `quota: None` (aggregate/lib.rs:203); widget renderQuota 的 agents 分支永不可达; Swift 不解码该字段. 可删字段+widget 分支 (~10 行), 两端同步. [rust/...collector-domain/src/lib.rs:522] ✅对抗复核确认
6. **`services[].isCurrent` 恒为 false** — 生产端无置 true 路径, widget「当前」徽标暂不显示. ⚠️但 widget 是活跃消费方 (renderQuota 读 s.isCurrent、徽标渲染、Codex 组排序置前), Swift 也解码 — **字段不可删**, 只能决定是否实现置 true 逻辑. [rust/...collector-provider/src/lib.rs:140]
7. **`context.paths` 会话路径覆盖机制无发送方** — 含 kimi_cli_sessions 等 10 个子键, 所有层均无人发送 (~30 行). [rust/...collector-application/src/lib.rs:596] ✅确认
8. **`subscriptionQuotaOnly`/`subscriptionProviders` 发而不读** — Swift 定向刷新发送, Rust 仅白名单放行从不读取 (~12 行). 删除需两端同步. [macos/...CollectorRunInput.swift:238] ✅确认
9. **widget `a.status==='unsupported'`(未接入) 分支** — 任何版本的 collector 都从未产出过该状态 (~2 行). [agent-usage/widget/index.html:850] ✅确认
10. **Bridge 凭证白名单孤儿键 (部分成立)** — `kimiWebTokens`/`orcaCodexAuth` 两键为历史候选; `claudeOAuth`/`grokOAuth` 有读取方但全仓无发送者. ⚠️原报告把 `providerEnv` 也列入孤儿是误判: LocalIntegrationHarness 真实发送并依赖白名单放行. [rust/...collector-bridge/src/lib.rs:44]

## B. Rust 零调用方代码 — 编译器可验证, 直接删 (~190 行)

1. `UsageAccumulator::record` (~55 行) — 与 domain `UsageContributionBuilder::record` 近似复制, 生产聚合一律走 merge_delta/finalize, 仅自身测试使用. [rust/...collector-aggregate/src/lib.rs:38] ✅两区独立确认
2. collector-runtime 观测访问器: `PermitPool::capacity/available` + `Permit::release` + `BoundedQueue::len/is_empty/capacity` (~33 行). [rust/...collector-runtime/src/lib.rs:192-207,214-219,310-327] ✅确认
3. `plan_codex_retry_only` (~45 行) — 重试编排实际由 Swift CodexQuotaRecovery 完成, Rust 函数与之完全重复; 连同内联测试删除. [rust/...collector-credential/src/lib.rs:550-569] ✅确认
4. `read_json_file`/`read_codex_auth_file`/`read_kimi_web_tokens_file` 三函数集群 (~35 行) — App 模式不读 ~/.codex/auth.json, Kimi web tokens 已弃用; parse_json_bytes 仍被 Claude/Grok reader 使用需保留. [rust/...collector-credential/src/lib.rs:304-332] ✅确认
5. 角色常量 `AGGREGATION_ROLE`/`ADAPTER_ROLE`/`CREDENTIAL_ROLE` (~3 行) — 全仓零引用. [各 crate lib.rs] ✅确认
6. `scan_kimi_tree` 的 `project_from_path=true` 分支与 `project_from_kimi_path` (~16 行) — 全仓唯一调用点硬编码 false, 无测试传 true. [rust/...collector-local/src/sources.rs:124-135,249-285] ✅确认
7. Cargo 卫生: collector-local 对 collector-runtime 的直接依赖残留 (唯一使用者 sqlite.rs 已删); collector-aggregate 的 serde 完全未用、serde_json 仅测试用. [crates/*/Cargo.toml]

## C. Swift 死项与单实现抽象 (~360 行)

迁移残留 (Codex 旧格式 / 平行死副本):

1. `CodexAccountsLibrary` 整个枚举 (~84 行) — CC Switch 同构旧账号库的四个纯函数, 被 v2 取代. [Sources/BruceOnboardingCore/SubscriptionCredentialImport.swift:158] ✅
2. `CodexAuthFileParser` 枚举 (~44 行) — 旧 auth.json token 解析, 被 metadata-only 发现取代. [同文件:116] ✅
3. `verifyCodexAccountsJSON` (~24 行) — 校验旧整体账号库格式. [ProviderConnectionVerifier.swift:138] ✅
4. `SubscriptionCredentialEvaluator.kimiStatus` (~27 行) — 与 Verifier 平行的死副本. [SubscriptionCredentialEvaluator.swift:131] ✅
5. `OnboardingConfiguration` 顶层 `connectionStates`/`lastVerifiedAt` (~14 行) — 自诞生起无 writer/reader. [OnboardingConfiguration.swift:105] ✅

单实现且零测试注入的抽象缝隙 (上一轮发现的同类):

6. `ActivationGateEvaluator` + executionPolicy + CollectorExecutionPolicy + CollectorActivationDecision (~63 行) — 只被 Harness 调用的平行授权抽象, 生产白名单实际硬编码在 OnboardingRunInputProvider. [CollectorActivationGate.swift:80] ✅
7. `UsageLedgerFileSystem` 协议 (~39 行) — 单实现, 测试从未注入 fake. [BruceAppCore/DeepSeekUsageLedger.swift:97] ✅ (99eb750 后仍在)
8. `DeepSeekCredentialVerifier` 协议 (~6 行) — doc 声称可注入 mock 但 mock 不存在. [ProviderConnectionVerifier.swift:42] ✅
9. `CodexMigrationExecuting` 协议 (~6 行) — 缝隙两端均未被测试使用. [BruceAppCore/CollectorRunInput.swift:105] ✅

死状态机与死分支:

10. `ModuleReadinessResult.actions` 无任何读者; `SetupAction.retryConnection`/`reviewAuthorization` 不可达 (~20 行). [OnboardingModels.swift:53] ✅
11. `ModuleRunState.offline` 生产不可达 — ReadinessEvaluator 从不产出对应 readiness (~5 行). [AppModel.swift:404] ✅
12. `SQLiteSchemaProfile.opencode` 定义后从未用于 probe (~11 行). [SQLiteSchemaProbe.swift:52] ✅
13. 杂项: `unknownSchema` case 从未 throw (2 行); `legacyProviderID(for:)` 恒返回 nil (10 行); `resolvedInterfaceStyle` 无消费者 (5 行); `SubscriptionService.jsonObject(from:)` 定义后零调用 (10 行). ✅

## D. Widget 与脚本 (~40 行)

- `.s-bars` 死 CSS 块 + reduced-motion 中 `.h-bar` 引用 (~10 行) [index.html:272] ✅
- 只写不读属性 `data-top`/`data-lg` (~2 行) [:790] ✅
- KimiPixelField `visible` 恒 true (~3 行) [:450] ✅
- 配置键 `mark`/`pointerMode` 从未读取; densityAt 非 directional 回退不可达 (~6 行) [:436] ✅
- `fmtTime`/`fmtReset` 格式化主体重复 (~5 行) [:561] ✅
- mount() 返回对象 `resize` 方法零调用 (~1 行; rebuild 本身保留供 ResizeObserver) [:517] ✅
- CSS token `--fs-title` 零消费 (~1 行) [:19]; `.meter.na .m-label` 死规则 (~1 行) [:256] ✅
- smoke 脚本 `shasum` 依赖声明从未调用 [collector-release-smoke.sh:39]; build-release-app.sh `strings` 声明从未调用 (保留 lipo) [build-release-app.sh:66]; `Bruce_build_rust_collector` debug 分支不可达 (~8 行) [runtime-manifest.zsh:81] ✅

## E. 文档与仓库卫生 (~150 行改写 + 若干清除)

Python collector 时代残留:

- constitution.md 「语言专属编码规范」整块约束已不存在的 Python (~30 行) [:95] ✅
- AGENTS.md 命令表 `node --check -` 死条目 (唯一实现者已随 pytest 套件删除) [:86] ✅
- .gitignore: `__pycache__/`、`*.py[cod]`、`.Bruce-runtime/`、`!.env.example` 只匹配已删产物 ✅
- 仓库根 `.pytest_cache/` 孤儿缓存 (索引指向二十余个已删测试) ✅
- `agent-usage/collector/` 空壳目录 (git 追踪文件数为 0) ✅
- `docs/app-icon.png` (~80KB) HEAD 零引用 ✅

文档事实性漂移 (需改写):

- README.md 版本声称 v0.3.0, 与 VERSION (=0.4)/CHANGELOG/tag 三方矛盾 [:10] ✅
- docs/development/02-ci-cd.md 与现行 ci.yml 的发布边界已同步: 当前仅 Preview 验证、构建和草稿 Release, 不纳入正式签名 job ✅
- docs/development/03-toolchain.md 三处漂移: 最低系统 macOS 26 (实际 v14)、swift-tools-version 6.0 (实际 6.2)、Harness 表少列 6 个 ✅
- docs/development/01-bruce-design.md 多章节描述已拆除架构且无历史横幅 (平台基线/WebKit/App Bundle Widget 副本/§19.6.2 幻影步骤) ✅
- docs/development/04-provider-auth-matrix.md 停留在 CC Switch 时代, README 仍链接它作为授权矩阵 ✅
- bridge/schemas/*.json 无任何加载方, 而 docs 08/14/01 声称会被打包或校验 ✅
- OpenSpec 归档欠账: 四个已完成未归档变更; productize-macos-dock-dashboard 残留 7 个永久无法完成的开放任务 ✅

## F. 对抗性驳回 (4 条, 附反证摘要)

1. 「实施计划引用已删 Python 脚本」— implementation-plan.md 顶部已有历史记录横幅全局落地, 且 c616273 已将 docs/openspec/ 移出版本控制.
2. 「AgentServiceItem.isCurrent 死字段」— widget 是活跃消费方 (徽标+排序), 删字段会破坏契约; 属产品决策非死代码 (已并入 A-6).
3. 「ConnectionStatus 6/7 case 无法构造」— `.connected` 在 DiagnosticsHarness 与 SubscriptionRefreshControlHarness 有真实构造点 (成员语法推断, 按类型名 grep 会漏); 较窄子命题 (.notChecked 等) 仍可议.
4. 「Bridge 白名单 4 孤儿键」— `providerEnv` 被 LocalIntegrationHarness 真实发送并依赖放行; 其余子项成立 (已并入 A-10).

---

## 原始证据

- Workflow 完整输出: `/private/tmp/claude-501/-Users-sivan-code-project-my-project-app-project-Bruce/9900765f-5b2b-4006-869d-8e460bf51067/tasks/w8xmxxjb0.output`
- 各 agent 判定日志: `~/.claude/projects/-Users-sivan-code-project-my-project-app-project-Bruce/9900765f-5b2b-4006-869d-8e460bf51067/subagents/workflows/wf_fb9bc219-88b/journal.jsonl`

## 建议的落地切分

1. **立即修复** (正确性): volcengine 键名错配 (A-1).
2. **机械删除** (B+C+D, 约 550-650 行): 编译器+测试可验证, 可并入现有 `rust-collector-dead-code-cleanup` 思路扩展为第二轮, 或按 Rust/Swift/Widget 三个小变更分拆.
3. **产品决策** (A 组): Antigravity 已选择两端同删; 其余 credentialUpdates、成本链和 quota/isCurrent 仍按各自契约处理. 每项需要两端同步 + 契约测试.
4. **文档刷新** (E 组): 一次 docs PR 集中处理漂移与 Python 残留.
