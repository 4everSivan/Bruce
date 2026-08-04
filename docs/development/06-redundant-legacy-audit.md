# mddd 冗余流程与旧版流程审计

> 日期: 2026-08-03
> 方法: 三个并行探索代理 (Swift 侧, Python/Bridge 侧, 展示层/文档侧) 全仓扫描 + 以 grep/源码复核交叉验证; 行号以审计当日工作树为准.
> 结论形式: 按区域列出确认项与待决策项; 每项标注 类别, 现状证据, 建议. 已消除项单独列出, 不再处理.
> 范围: 仅审计与整理, 不含任何代码修改, 测试运行或构建产物变更.

---

## 1. Swift 侧 (macos/MdddApp)

### 1.1 已消除项 (任务 8 清理已完成, 当前工作树无残留)

上一轮会话的任务 8 已在当前工作树中完成以下清理, 复核确认均不存在:

| 清理项 | 复核证据 |
|--------|----------|
| 两源 merger 入口 `merge(first:retry:)` + `mergeService` helper | `CodexQuotaSnapshotMerger.swift` 仅剩四源入口 `merge(previous:first:retry:decisions:)` (:79), 私有 `mergeAccount` (:202); 全仓无 `merge(first:` 调用, 唯一测试 `codexMergerMultiAccountAndNewEntries` 已不存在 |
| 未使用的 `RefreshScheduler.codexCredentialStore` 属性 | Sources 与 Tests 全仓零匹配 |
| 未使用的 `CodexTokenManager.validAccessTokens(for:now:)` | 全仓仅剩单账号 `validAccessToken(for:now:)` (CodexTokenManager.swift:266) |
| `handleCodexChallenges` 未使用的 `firstContext` 参数 | 当前签名 (RefreshScheduler.swift:540-544) 仅 `module/firstOutput/firstCredentials`, 无 firstContext; 调用处 (:451) 同步 |
| 无效可选表达式 `try? codexStore.loadIndex() ?? ...` | CollectorRunInput.swift 无该表达式; 现有 `try? codexStore?.loadRecord(...)` (:201, :373) 是合法可选链 (store 本身可空), 非冗余 |
| 两源入口 `merge` 的 `retryObject` never-mutated warning | 当前四源入口 `retryObject` 正常读取值 (:96-97, :167-168) |

### 1.2 待决策项 (Swift)

| # | 文件:行号 | 类别 | 现状证据 | 建议 |
|---|-----------|------|----------|------|
| S1 | `CollectorRunInput.swift:32-33` | 编译警告 (deprecated) | `case .success(accessToken: let accessToken, expiresAt: let expiresAt):` 仍是带标签 enum tuple 匹配, 触发 Swift 6 deprecated warning | 改为 `case .success(let accessToken, let expiresAt)` 或 `.success(let accessToken, _)`; 一行改动, 属于任务 8 item 6 未收尾项 |
| S2 | `CodexQuotaSnapshotMerger.swift:25-26` | 冗余注释 | 文档注释仍写「兼容: `merge(first:retry:)` 两源入口保留给既有合并契约测试」, 两源入口已删除 | 删除这两行注释 |
| S3 | `CollectorRunInput.swift:44-48` | 冗余分支 | `case .refreshFailed(_, let reason): if reason == "暂缓重试" { return .temporarilyUnavailable(retryAt: nil) }` 两个分支返回完全相同值 | 收敛为 `case .refreshFailed: return .temporarilyUnavailable(retryAt: nil)`; 行为不变 (需在测试中确认无分支断言差异) |

### 1.3 确认无需处理 (Swift)

- **迁移提示逻辑** (`SettingsView.swift:668-677`, `AppModel.swift` `CodexMigrationDisplayStatus`): 当前实现, 由 `ApplicationBootstrap.swift:81-85` 从 `executeCodexMigration()` 结果驱动, 无旧分支残留.
- **`codexAccountStatusesList`** (`SettingsView.swift:692-714`): 当前实现, 由 `CodexTokenManager.statusSnapshot()` 每周期刷新, 区分 connected/needsReauthorization/revoked/storageBlocked, 无旧渲染路径.
- **`MenuBarViews.swift:36-43`** 菜单栏警示逻辑: 与设计文档 §4.1 一致, 无遗留.
- **`try? codexStore?.loadRecord(...)`** (CollectorRunInput.swift:201, :373): 合法可选链 (store 可空), 非无效表达式, 保留.

---

## 2. Python/Bridge 侧 (agent-usage/collector + bridge)

### 2.1 架构总览 (双模式现状)

- **CLI 模式**: `collect()` (collect_usage.py:1865) 全本地扫描 + `collect_services()` (:1733, 读 CC Switch providers 行) + `service_antigravity()` (:1508, 文件→Keychain) + `service_codex_accounts()` (:1282, legacy 分支). 入口 `main()`/`run()` (:2019/:2041).
- **App 模式**: `run_app()` (:2023) 设 `app_mode=True`, 走 `_collect_app_services()` (:1694, 纯注入, 不读 CC 库) + `service_codex_accounts()` 注入分支 (:1293-1334, 只读 access_token) + `service_antigravity()` 注入分支 (:1515-1518) + `collect_codex_quota_retry_only()` (:1849, 重试专用).

### 2.2 已消除项 (确认)

- App 模式不读 `~/.codex/auth.json` (:1360 `elif not _APP_MODE` 守卫), 不读 CC Switch providers 行 (`collect_services` :1734 顶部 `if _APP_MODE: return _collect_app_services()`), 不读 `~/.cc-switch/codex_oauth_auth.json` (App 未注入时 :1340 直接 `return []`), 不读 Orca auth.json (:1887 `elif _APP_MODE: return None`).
- `CODEX_AUTH`/`CODEX_OAUTH_AUTH` 的写回 (:1442-1463) 全部带 `not _APP_MODE` 守卫.
- **refresh_token 注入被硬拒**: security.py 白名单只放行 `display_name`/`access_token` (:63-66), `_validate_codex_quota_accounts` (:346-351) 拒绝一切多余字段 (含 refresh/id token); 无旧格式兼容分支.

### 2.3 待决策项 (Python/Bridge)

| # | 文件:行号 | 类别 | 现状证据 | 建议 |
|---|-----------|------|----------|------|
| P1 | `collect_usage.py:1336-1348` (`service_codex_accounts` 旧注入兼容分支) | 旧版/死代码 | `codex_oauth_auth` 注入 → 走完整 refresh/rotation/writeback 管道; Swift 只注入 `codex_quota_accounts`, `codex_oauth_auth`/`codex_auth`/`orcaCodexAuth` 均不在 security.py 白名单, Bridge 不可能放行; 仅测试直调 | 删除 (或标注仅测试) |
| P2 | `collect_usage.py:244` (`_record_credential_update` 白名单含 `codex`) | 冗余 | security.py:101 `UPDATE_PROVIDERS = {"kimi", "antigravity"}`; :1401 对 codex 的更新只在 legacy 分支可达, App 模式永不产生, 即便产生也会被 :206-211 `validate_credential_updates` 拒绝 | 从 :244 集合移除 codex, 与 security.py 对齐 |
| P3 | `collect_usage.py:1141-1155, 1387-1408` (`_codex_refresh` / refresh_token 轮换管道) | 旧版 | 只服务 legacy 分支; 新契约下 refresh_token 不离开 Keychain | 与 legacy 分支一起删除 |
| P4 | `collect_usage.py:1442-1463` (CLI legacy 写回三件套) | 旧版 | CC OAuth + CLI auth 的 `.bak-kimi` + chmod 600 写回; 带 `not _APP_MODE` 守卫 | 随 legacy 分支删除 |
| P5 | `collect_usage.py:1484-1505` (`_load_agy_oauth` 文件→Keychain 回退) | 旧版 (仅 CLI) | 顺序: 文件优先 (:1490) → `/usr/bin/security` CLI 包装 go-keyring (:1472-1481) → `go-keyring-base64:` 前缀解码 (:1497-1500); App 模式不经过 (:1520 提前 return); Keychain 写回被禁止 (:1567) 正确 | 保留 (CLI 兼容, 只读不回写), 不动 |
| P6 | `collect_usage.py:59-60, 1547-1548` (`AGY_CLIENT_ID`/`AGY_CLIENT_SECRET` 环境变量) | 死代码 | Swift bridge 子进程环境白名单化 (CollectorRunner.swift:253-258), 无任何 AGY 变量; 生产 App 模式永远拿到空串; 注释称「运行环境注入」实际无注入方; 仅测试 monkeypatch | 改为注入凭证结构携带 client_id/secret, 删除 env 读取 (设计决策, 需评估) |
| P7 | `collect_usage.py:1888-1895` (`orca_account_label` 磁盘回退) | 冗余 | 有 `_APP_MODE` 守卫正确; 注入键 `orca_codex_auth` 无 Swift 注入方; 仅测试两处 | 与 security.py 白名单 `orcaCodexAuth` (:43) 一起评估: 删除或补真实注入方 |
| P8 | `collect_usage.py:1793-1796` (`collect_services` 内 provider_env/provider_meta merge) | 冗余 (CLI) | CLI 直跑无注入, 恒为空 dict; App 模式不经过此函数 | 保留 (无成本) 或随函数删除 |
| P9 | `collect_usage.py:1302-1303` (`_runtime_credential("codex_quota_account_order")` 回退) | 死代码 | App 模式 order 走 context 永不触发; CLI 模式无 order 来源 → :1322-1323 回退 dict 插入序, order 键无作用; 仅测试从 credentials 注入 order | 删除两行回退; 测试改用 context 注入或删除用例 |
| P10 | `collect_usage.py:347` (`cost_of`) | 死代码 | 定义后从未调用, finalize 内 :356 直接内联实现 | 删除 |
| P11 | `security.py:24` (`username` context 白名单) | 死分支 | CONTEXT_FIELDS 白名单含 username; Swift 从不发送, collector 从不读取 | 从白名单移除 |
| P12 | `security.py:25, 58` (`caFile` → `ca_file`) | 死分支 | 白名单与映射存在, collector 无任何 `_runtime_context("ca_file")` 读取; Swift 从不发送 | 移除白名单条目 (需确认无外部注入方) |
| P13 | `security.py` (request schema `baseUrl`) | 死分支 | 仅 request schema 有, 不在 CONTEXT_FIELDS, 无任何消费 | 从 schema 移除 (或确认保留为未来用途) |
| P14 | `security.py:416` (`request_timeout`) | 死分支 | `build_collector_context` 生成, collector 无读取 (只读 `http_timeout` :415) | 删除或对齐 |
| P15 | `security.py:43` (`orcaCodexAuth` 白名单) | 冗余 | Swift 无注入方, 仅测试 (test_bridge_contract.py:1125) | 与 P7 一起评估 |
| P16 | `response-v1.schema.json` 顶层 `credentialUpdates` | 冗余 (协议字段) | Swift 侧 CollectorRunner/RefreshScheduler 只读 challenges (:557-562) 与 diagnostics/artifact, 无 credentialUpdates 消费点; 但 kimi/antigravity 轮换凭证确实由 collector 产生 (App 模式 `_record_credential_update`), Swift 不消费则更新丢失 | **需 Swift 侧确认意图**, 非纯冗余; 若确认弃用, 同步 schema 与 collector |

### 2.4 双实现并存 (轻度, 建议保留或统一)

| # | 位置 | 类别 | 说明 |
|---|------|------|------|
| D1 | `collect_services()` (:1733-1814, CC 驱动) vs `_collect_app_services()` (:1694-1730, 注入驱动) | 双实现 | 共享同一批 handler, 但状态语义 (empty/error/note) 在 :1801-1812 与 :1678-1691 各写一份 (近似重复) | 建议: 统一 `_quota_service_entry`+`_finalize_quota_service`, 或 CLI 彻底弃用 CC 驱动后删一个 |
| D2 | security.py `_validate_codex_quota_accounts` (:310-399) vs collector `service_codex_accounts` (:1308-1315) | 冗余 (深度防御) | Bridge 已保证 order↔map 一致, collector 内重复校验不可达 | 保留 (fail-closed 深度防御, 有注释) |
| D3 | `_volc_parse` window_from 闭包 (:1081-1104) vs `_codex_query_single_account` windows (:1217-1231) vs `service_antigravity` merged 聚合 (:1591-1616) | 双实现 (轻度) | 结构同构但各来源响应形态差异大 | 保留, 抽象收益低 |

### 2.5 确认无需处理 (Python)

- `run_bridge.py` 无与 security.py 重复的校验: 全部委托 security.py (:151, :198-211), 自身只做 stdout/stderr 污染检查 (:169-175), artifact 元数据检查 (:187-195), 敏感字段检查 (:198-205) — 均属 bridge 层职责.
- `_configure_runtime` 13 个路径常量都支持 `paths`/`HOME` override, Swift 从不发送 `paths` 键 — 该 override 链仅测试使用, 保留 (测试注入设施).
- `query_account` (:1369) / `run_app` (:2023) 被 AST 误报为死代码, 实为闭包/动态加载调用, 非死代码.
- `AGY_SUMMARIES_DB` (:1620-1631) App 模式仍读 — 仅会话统计, 非凭证, 保留.

---

## 3. 展示层与文档

### 3.1 过时文档 (优先处理)

| # | 位置 | 类别 | 现状证据 | 建议 |
|---|------|------|----------|------|
| W1 | `01-mddd-design.md:452, 826` 与 §12 全章 (WidgetHost) | 过时文档 | 文档声称存在 `WidgetHost.swift` (App target, Widget 资源加载/导航隔离/Artifact 注入) 与 `window.__mdddUpdate(artifact, state)` 注入协议; 仓库中该文件不存在 (grep 零命中), `tests/visual/README.md` 明确记录「原 App Bundle 内嵌资源已随 WKWebView 链路拆除」; `MdddApp.swift`/`ApplicationBootstrap.swift` 无任何 WebView 装配; §12.2 的 8 条 WKWebView 安全约束与 §12.3 的 Bundle 一致性校验均无对应实现 | 重写 §12 为「Widget 仅由 Daimon host 加载, 本仓库不再提供宿主」, 删除 WidgetHost.swift 行与 __mdddUpdate 协议描述 |
| W2 | `01-mddd-design.md:281` 状态胶囊 (role="status"/aria-live) | 过时文档 | 文档承诺 Widget 右下角状态胶囊; 单文件 Widget 本体无 (只有 `renderStatus` :910-914 切换「刷新中/LIVE」), 该功能只存在于测试 harness `tests/visual/host-bootstrap.js:35-67` (注释自称「迁移自已拆除的 App 内嵌 WKWebView 资源」) | 更新文档说明状态层由 Daimon 宿主注入 |
| W3 | `03-toolchain.md:59-69` + `README.md:166` Harness/Python 用例数 | 过时数字 | 文档: Onboarding 98/面板 23/CollectorRunner 16/RefreshScheduler 10/Diagnostics 5/LocalIntegration 1, Python 59 项; 实际: Onboarding 141/面板 29/Python 115 项 (另有 DeepSeek 17 项, 文档未列) | 与 AGENTS.md 对齐 (或注明以 AGENTS.md 为准) |
| W4 | `04-provider-auth-matrix.md:14, 16, 25-26` Codex 登录方式 | 过时文档 | 矩阵称「Codex 首版复用官方 codex login; mddd 不直接刷新或覆盖 ~/.codex/auth.json」「不复用仓库内硬编码 OAuth client」; 当前实现是 mddd 自带 `CodexOAuthClient` 设备码登录 (`DeviceAuthLogin.swift:198` 硬编码 `clientID = "app_EMoamEEZ73f0CkXaXp7hrann"`), 且 `CodexTokenManager` 直接刷新 token 并写 Keychain (v2 迁移) | 更新矩阵 Codex 行, 补充 v2 自管理 OAuth 说明 |
| W5 | `01-mddd-design.md:436-439, 461-465` 架构图与 Core 职责 | 过时文档 | mermaid 图无 `CodexTokenManager`/`CodexCredentialStore`/`OnboardingRunInputProvider` 节点; §9.2 未列 CodexTokenBatchResolver/CodexQuotaSnapshotMerger/DeepSeekUsageLedger; 图内 `WIDGET --> AGENT` (:439) 与 §9.3「Widget 不直接调用 Collector」(:475) 自相矛盾 | 更新架构图与职责清单 |
| W6 | `01-mddd-design.md:162` CC Switch 角色 | 过时文档 | 「model_pricing 用于本地成本估算」; 实现已改为内置价目优先 (collect_usage.py:385-387, 565-587), CC 仅补充内置表没有的新模型 | 更新该句 |
| W7 | `01-mddd-design.md:285-307` 卡片组件说明 | 过时文档 | §7.3 描述「用量卡四格细分: input/output/cache read/cache creation」— 原生 `UsageHeroCard` 实际三格 (Widget :385-389 也只三格); 逐小时卡文案与 `HourlyLineCard.swift` 实际布局不符 | 更新或注明视觉基线来源 |
| W8 | `02-ci-cd.md:21-23, 40` 运行器工具链 | 过时文档 | 文档称「macos-26 镜像默认 python3 为 3.14 且不含 pytest … 先 brew install ripgrep」; 实际 ci.yml verify job 用 setup-python 3.12, `build-test-app.sh` 中无任何 rg 调用; §4 表格「9 个 Harness」未列 DeepSeekUsageLedgerHarness | 删除 ripgrep 依赖说明, 修正 Harness 清单 |
| W9 | `01-mddd-design.md:833-1093` §19「收尾」历史计划 | 过时文档 | 一次已完成的收尾计划 (target 拆分/诊断/可访问性) 以「设计」形态保留在正式设计文档, 含 §19.2 Target 结构/§19.6.2 13 步验证清单/§19.7 OpenSpec 勾选记录 | 迁出至 docs/superpowers/ 或归档, 从正式设计文档删除 |
| W10 | `03-toolchain.md:33` Python 基础 API 表述 | 过时 (轻微) | 「当前使用的最晚基础 API 是 Python 3.7 已提供的 datetime.fromisoformat」— 实际 collector 使用 `ThreadPoolExecutor`/`os.replace`/dict 合并等, 不具代表性 | 更新或删除该句 |
| W11 | `01-mddd-design.md:9` 「不复制第三方 OAuth client secret」 | 过时 (轻微) | 与现状 (mddd 自注册 Codex OAuth client) 不完全一致 | 更新表述 |

### 3.2 双渲染契约 (Widget vs App)

| # | 位置 | 类别 | 现状证据 | 建议 |
|---|------|------|----------|------|
| C1 | `agent-usage/widget/index.html:696-705, 832-838` | 双渲染 / 死分支 (Widget 侧) | Widget 渲染 `s.isCurrent`/`kind`/`balance`/`currency`/`extra` 与 `a.todayModels[].{model,total,costUsd}`/`a.projects`; 这些字段 App 侧模型声明存在 (ArtifactModels.swift) 但**原生 SwiftUI 卡片不消费** (PanelViewModel service 分组不读 `isCurrent`, HourlyLineCard 明细不读 `todayCostUsd`) | 保留 (设计文档 §11.2/§6.1.3 承诺契约); 若收紧契约应同步 schema/Swift 模型/Widget 三处 |
| C2 | `agent-usage/widget/index.html:394, 906` 文案提 CC Switch | 过时文案 | 「云端服务经 CC Switch 查询」「额度经 CC Switch 配置查询 · 成本按 CC Switch 定价表估算」; 当前实现 CC Switch 只是注入路径之一 (collector 1695-1710 注释「完全不读取 CC Switch 数据库」), Widget 本身禁止联网 | 更新为「经已授权 Provider 查询」中性表述 |
| C3 | Widget 无 CI/脚本验证 | 流程缺口 | `scripts/verify-local.sh` 全文无 widget 步骤 (对照 01:1031-1047 的 13 步承诺, 第 4/5 步缺失); `.github/workflows/ci.yml` 无 widget 引用; `test_widget_security.py` 只做 node --check 与 CSP 断言 | 保留现状 (单文件 Widget 无 Bundle 副本需要一致性校验), 删除 01:1047 的步骤 4/5 承诺; 或为 widget 增加独立 node --check 步骤 |

### 3.3 旧流程残留

| # | 位置 | 类别 | 现状证据 | 建议 |
|---|------|------|----------|------|
| L1 | `data/*.json` 落盘流程 | 旧流程 (CLI 遗留) | 写入方仅 CLI 入口 `main()` (`--out` 参数, :2041-2058, 原子写); 读取方为零 (全仓 grep 仅 AGENTS.md:84 一处文档引用); App 模式永不写文件; `data/` 已在 .gitignore | 保留 (开发/调试价值); AGENTS.md:84 「可能刷新并写回 OAuth」表述应弱化 |
| L2 | `collect_usage.py:1290-1310, 1378-1410` Collector CLI legacy 路径 | 旧流程 (死分支风险) | `service_codex_accounts()` 未注入凭证时回退读 `~/.codex/auth.json`、`~/.cc-switch/codex_oauth_auth.json` 并执行 `_codex_refresh` (:1378 注释「Codex CLI 与 CC Switch 各存一份」); App 模式注入后不触发; 该路径仍是 `run()` (CLI 默认) 的执行路径 | 保留 (CLI 兼容); 文档注明「CLI 直跑会读第三方认证文件, App 模式不读」 |
| L3 | `AGENTS.md:88` Python 测试数 | 过时数字 | 写「87 项」, 实际 115 项 | 更新 |

### 3.4 确认无需处理 (展示层)

- **设置页迁移提示 / codexAccountStatusesList / 菜单栏警示**: 均当前实现, 无旧分支 (见 1.3).
- **`02-ci-cd.md:42`** `build-release-app` 上传 `dist/`: 与 gitignore 一致, 无需改.
- **`05-release-acceptance.md:70`** 「回滚到上一兼容 Bridge v1 / Artifact v1 构建」: 仍准确, 保留.
- **§5.3 授权撤销 / §6.2 调度参数 / §6.3 缓存发布 / §7.1 面板 440pt / §10 Bridge v1 / §14 诊断**: 均与实现一致, 无遗留.

### 3.5 文档承诺 vs 实现状态 (E 类)

| 项 | 状态 | 说明 |
|----|------|------|
| Codex v2 凭证 (Keychain `codex:account-index:v2`) | 已实现, 文档未反映 | 01 §7.4/§6.3/§13.2 缺「Codex v2 与 DeepSeek 账本」节 |
| Codex 账号状态列表与重新授权 | 已实现, 文档未反映 | 见 D2 |
| DeepSeek 月度账本 (`MdddApp.swift:63`, `SubscriptionCard.swift:82`) | 已实现, 文档未反映 | 同上 |
| 系统通知 (`SettingsView.swift:113-131`, `QuotaAlertNotifier`, 5h 80% 阈值) | 已实现, 文档未反映 | 同上 |
| Codex quota 401 定向重试自愈 (`MdddApp.swift:54-56`) | 已实现, 文档未反映 | 同上 |
| WidgetHost + `__mdddUpdate` + WKWebView 安全约束 | 承诺但已移除 | 见 W1 |
| Widget `role="status"` 胶囊 | 承诺但已移除 | 见 W2 |
| verify-local.sh 13 步中 Widget Bundle 一致性 + node --check | 承诺但未实现 | 见 C3 |

---

## 4. 汇总与建议优先级

### 4.1 按类别统计

| 类别 | 数量 | 条目 |
|------|------|------|
| Swift 编译警告 (deprecated) | 1 | S1 |
| Swift 冗余 | 2 | S2, S3 |
| Python/Bridge 旧版 (CLI legacy) | 4 | P1, P3, P4, P5 |
| Python/Bridge 死代码 | 5 | P6, P9, P10, P11, P12 |
| Python/Bridge 冗余 | 4 | P2, P7, P8, P15 |
| Python/Bridge 协议死分支 | 3 | P13, P14, P16 |
| Python/Bridge 双实现 | 3 | D1, D2, D3 |
| 过时文档 | 11 | W1-W11 |
| 双渲染契约 | 3 | C1, C2, C3 |
| 旧流程残留 | 3 | L1, L2, L3 |
| 已消除 (无需处理) | 6+ | S 侧 6 项, Python 5 项, 展示层 6 项 |

### 4.2 建议处理优先级

**P0 — 立即处理 (小改动, 属于第二轮任务 8 未收尾项):**

- S1: `CollectorRunInput.swift:33` deprecated tuple 匹配 — 本轮已修改文件中的遗留 warning, Release 构建应无 warning.
- S2: 删除 CodexQuotaSnapshotMerger.swift:25-26 过时注释 (两源入口已删除).

**P1 — 代码清理 (改动有明确收益, 需评估影响面):**

- P10: 删除 `cost_of` 死代码 (collect_usage.py:347).
- P2: `_record_credential_update` 白名单移除 codex (与 security.py 对齐).
- P9: 删除 `_runtime_credential("codex_quota_account_order")` 回退 (collect_usage.py:1302-1303), 同步测试.
- P3/P4: CLI legacy 分支 (refresh 管道 + 写回三件套) 若确认不再需要, 随 P1 删除.
- S3: 收敛 `refreshFailed` 同值双分支.

**P2 — 结构性决策 (需用户/设计确认):**

- P6: `AGY_CLIENT_ID`/`AGY_CLIENT_SECRET` — 改为注入凭证结构 or 保留 env (需确认).
- P7/P15: `orca_codex_auth` / `orcaCodexAuth` — 删除 or 补真实注入方.
- P16: `credentialUpdates` — Swift 侧确认是否消费 kimi/antigravity 轮换更新.
- D1: `collect_services` vs `_collect_app_services` 双份状态语义 — 统一 or 删一个.

**P3 — 文档更新 (无风险, 建议尽快):**

- W1-W11 全部过时文档更新, 优先 W1 (WidgetHost 全章) + W3/L3 (数字对齐) + W9 (§19 历史计划迁出).
- C2: Widget 文案去 CC Switch 化.
- L1: AGENTS.md 「可能刷新并写回 OAuth」弱化.

---

## 5. 审计依据

- 本轮三个并行探索代理输出 (Swift/Python/展示层) + grep/源码复核.
- 第二轮修复计划 `docs/superpowers/plans/2026-08-03-codex-quota-refresh-second-remediation-implementation-plan.md` 任务 8 清理项核对.
- Release 构建警告清单 (构建完成后核对, 若存在 S1 之外的 warning 会补充).
- 测试现状: `python3 -m pytest tests/ -q` → 115 passed; 上述 dead/legacy 代码均有测试覆盖, 删除时需同步清理对应用例.

---

## 6. 不处理清单 (确认项)

- 两源 merger / validAccessTokens / firstContext / codexCredentialStore / 无效可选表达式 — 已删除, 不再处理.
- App 模式不读 CC Switch 库 / ~/.codex/auth.json / ~/.cc-switch/codex_oauth_auth.json / Orca auth.json — 已正确隔离.
- refresh_token 注入被 security.py 白名单硬拒 — 已消除.
- 设置页迁移提示 / codexAccountStatusesList / 菜单栏警示 — 当前实现, 非遗留.
- `try? codexStore?.loadRecord` — 合法可选链, 非无效表达式.
