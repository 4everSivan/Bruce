# Rust Collector 后续架构迁移 implementation plan

对应设计: [next-architecture-design.md](./next-architecture-design.md)

状态: Rust cutover 已完成, Slice 0/A/B/C 已完成, 多源 Agent 空数据与 Codex 额度链路修复已完成, 最终发布环境门禁待执行.

> 历史记录说明: 本文保留迁移过程中的旧方案、基线命令和差分证据, 其中出现的 Python、pytest、旧 Bridge 脚本路径均只用于描述迁移前状态, 不再是当前项目的可执行入口. 当前验证以 `scripts/verify-local.sh`、`scripts/check-collector-fixtures.sh`、Rust workspace 测试、Swift Harness 和 `scripts/build-test-app.sh` 为准.

## 1. 执行约束

- 保持 `Bridge v1`、`artifact v1`、Swift Runner contract 和 Release Rust-only 不变.
- 每个 slice 先增加 fixture/contract 测试, 再迁移 implementation.
- 不运行真实凭证采集; Provider、credential、Keychain、SQLite 和 HTTP 全部使用隔离 fixture 或可注入 adapter.
- 不修改第三方 CC Switch/Antigravity 数据库; SQLite 始终使用 read-only 连接.
- Rust 不直接写 Swift App Keychain, 只输出经过验证的 `credentialUpdates`/`credentialChallenges`.
- 不把 raw session、OAuth response、access token 或 refresh token 写入仓库、fixture、cache 或日志.
- 每个 slice 完成后运行 Rust workspace、Swift Harness 和安全扫描, 再进入下一个 slice.
- 现有 `tasks.md` 的 7.1、7.3、7.5 仍是 Release cutover 的外部环境门禁, 不因本计划完成而自动标记通过.

## 2. 目标依赖图

```text
collector-bridge
        │ protocol / envelope only
        ▼
collector-application
        ├── collector-domain
        ├── collector-local
        ├── collector-aggregate
        ├── collector-provider
        ├── collector-credential
        └── collector-runtime

collector-local ───────> collector-domain
collector-aggregate ───> collector-domain
collector-provider ────> collector-domain + collector-runtime
collector-credential ──> collector-domain + collector-runtime
collector-runtime ─────> generic cancellation / budget / queue only
```

实施后必须满足:

- `collector-bridge` 不再直接依赖 `collector-local`、`collector-provider` 或 `collector-credential` implementation.
- `collector-local` 不再依赖 `collector-aggregate`.
- `collector-aggregate` 不读取文件、SQLite、HTTP 或 Keychain.
- binary target 只读取 stdin、调用 bridge、序列化 stdout.

## 3. Slice 0: 基线与迁移护栏

### 0.1 冻结现有契约

涉及文件:

- `docs/openspec/changes/rust-collector-performance/specs/collector-parity-validation/spec.md`
- `docs/openspec/changes/rust-collector-performance/specs/rust-collector-runtime/spec.md`
- `tests/fixtures/bridge/`
- `scripts/differential-collector.py`

工作:

- 盘点 Bridge request/response、artifact、diagnostic、credential update/challenge 的字段和稳定排序.
- 记录允许变化的运行时字段; 其他字段使用 canonical JSON 严格比较.
- 补齐 local-only、quota-disabled、partial、timeout、cancel 和 previous-artifact fixture.
- 为 `UsageContribution`/`SourceDeltaChange` 预留脱敏 fixture 格式, 不复制 raw session.

验证:

```bash
python3 -m pytest tests/
python3 scripts/differential-collector.py \
  --request tests/fixtures/bridge/agent-usage/request-valid.json \
  --rust rust/Bruce-collector/target/debug/Bruce-collector
python3 scripts/check-collector-fixtures.py
```

完成条件:

- 迁移前 baseline 可重复.
- fixture secret scan 为 `secretFindings=[]`.
- fixture 不含真实 home、真实 token 或真实数据库路径.

## 4. Slice A: `collector-application` orchestration

### A1. 创建 application crate 和依赖方向

新增/修改:

- `rust/Bruce-collector/Cargo.toml`
- `rust/Bruce-collector/crates/collector-application/Cargo.toml`
- `rust/Bruce-collector/crates/collector-application/src/lib.rs`
- `rust/Bruce-collector/crates/collector-application/src/context.rs`
- `rust/Bruce-collector/crates/collector-application/src/result.rs`

工作:

- 将 `collector-application` 加入 workspace.
- 定义 application 输入、单次 `RunContext`、collection output 和诊断收集位置.
- 将 limits、window、capabilities、paths、credential view 和 run metadata 在 application 内归一化.
- 统一生成 deterministic result, 不让并发任务直接修改最终 artifact.
- application 只依赖既有 crate contract, 不读取 Swift 或 Python 文件.

验证:

- 纯 fixture 测试, 不触碰网络、Keychain 或真实文件.
- `cargo test -p collector-application`.
- `cargo tree` 检查无循环依赖.

### A2. 把 Bridge 业务编排迁入 application

修改:

- `rust/Bruce-collector/crates/collector-bridge/src/lib.rs`
- `rust/Bruce-collector/bin/Bruce-collector/src/main.rs`
- `rust/Bruce-collector/crates/collector-bridge/Cargo.toml`

工作:

- 保留 Bridge request schema、大小限制、UUID 校验、capability/credential 白名单和 timeout 上限.
- 将 `collect_agent_usage` 的业务编排移动到 application.
- Bridge 将已验证 request 转成 application input, 接收 application output, 再完成 credential output validation 和 envelope.
- 删除 Bridge 对 local/provider/credential implementation 的直接依赖.
- binary 保持单 stdout JSON envelope、stderr 分离和退出码语义.

验证:

- 现有 Bridge tests 全部通过.
- `bin/Bruce-collector/tests/bridge_process.rs` 覆盖 stdout pollution、malformed JSON、oversized input、runId 和非零退出.
- Python/Rust 对 valid、invalid、capability denied、local missing fixture 做 canonical diff.

### A3. 接入现有 local + aggregate 路径

修改:

- `collector-application/src/`
- `collector-local/src/lib.rs`
- `collector-aggregate/src/lib.rs`

工作:

- 第一阶段不改变 local cache 内部表示, 先通过 application adapter 调用当前 local path.
- 将 Kimi CLI、本地 Agent placeholder、quota-disabled service 的现有 artifact 语义迁入 application finalizer.
- application 统一处理 `found`、`not_found`、`unavailable` 和 local partial diagnostic.
- previous artifact 保留继续放在 Swift `ArtifactStore`/pipeline 语义中, Rust 不伪造历史数据.

验证:

- local-only artifact 与 Python differential parity.
- Panel/RefreshScheduler/CollectorRunner Harness 不出现行为回归.
- `swift run --package-path macos/BruceApp CollectorRunnerHarness`.

### A4. Application finalizer 和确定性排序

修改:

- `collector-application/src/result.rs`
- `collector-domain/src/lib.rs` 或对应新 domain module

工作:

- 将 agent、service、model、project 和 diagnostic 的排序集中到 finalizer.
- 将 success/partial/error/empty/not_found 的转换集中在一处.
- 保证并发完成顺序不影响 artifact、diagnostic、credential update/challenge 顺序.
- 对不可安全分类的错误保留诊断, 不静默转换为空数据.

验证:

- 输入顺序随机化后输出 JSON 相同.
- 多个 partial diagnostic 的顺序稳定.
- artifact 空值、空数组、null 和缺省字段与 Python 一致.

### A5. Slice A 门禁

必须通过:

```bash
cargo fmt --check --manifest-path rust/Bruce-collector/Cargo.toml
cargo test --workspace --manifest-path rust/Bruce-collector/Cargo.toml
cargo clippy --workspace --all-targets --manifest-path rust/Bruce-collector/Cargo.toml -- -D warnings
python3 scripts/differential-collector.py \
  --request tests/fixtures/bridge/agent-usage/request-valid.json \
  --rust rust/Bruce-collector/target/debug/Bruce-collector
CI=true zsh scripts/verify-local.sh
```

Slice A 不要求新增 Provider 网络请求, 但必须证明 application 已成为唯一编排入口.

## 5. Slice B: Provider / credential / runtime execution seam

### B1. 扩展 RunContext 和 RuntimeBudgets

修改:

- `rust/Bruce-collector/crates/collector-runtime/src/lib.rs`
- `rust/Bruce-collector/crates/collector-application/src/context.rs`
- `rust/Bruce-collector/crates/collector-application/src/execution.rs`

工作:

- 将 `RuntimeLimits`、deadline、cancellation、local/network/SQLite permits、queue capacity 绑定到单次 run.
- 将 account single-flight 的 key 固定为 `provider + accountId`.
- 让 quota、credential refresh、local scan 和 aggregate queue 都通过统一 runtime context 获取限制.
- 保持 bounded queue、permit drop、cancel wake-up 和 deadline error 的现有语义.
- 不让 provider adapter 自己创建无界线程/task.

验证:

- runtime tests 覆盖 queue backpressure、permit release、deadline、cancel、single-flight.
- application integration test 验证同一账号只发生一次 refresh/quota execution.
- 资源达到上限时任务等待而不是无限增长.

### B2. 将 Provider module 变成 registry + adapters

修改:

- `rust/Bruce-collector/crates/collector-provider/src/lib.rs`
- 计划拆出的 `collector-provider/src/catalog.rs`
- 计划拆出的 `collector-provider/src/transport.rs`
- 计划拆出的 `collector-provider/src/adapters/`
- 计划拆出的 `collector-provider/src/parsers/`

工作:

- 保留现有 Provider public behavior, 将 catalog、transport、parser 和 adapter implementation 分离.
- 建立 registry, 按 stable app/provider ID 找到 quota adapter.
- 将 HTTP body size、status、timeout、retryable error 和 malformed response 的处理集中到 transport/result finalizer.
- 使用可注入 `HttpClient` fixture seam; production concrete HTTP transport 的 TLS、proxy、timeout 和 body limit 选择必须在实现前锁定并加入 Cargo lock.
- 不在 Provider adapter 内读取 Keychain 或写 artifact.
- 先迁移现有 Kimi、DeepSeek、Zhipu、Volcengine、Claude、OpenCode Go、Grok adapter, 再接入 application.

验证:

- 每个 parser 保留现有 fixture tests.
- Fixture HTTP client 检查 request method、URL、headers、body、timeout 和请求次数.
- success、empty、4xx、5xx、invalid JSON、oversized body、retryable error 全部有诊断.
- Provider catalog 的 stable order、duplicate account rejection、target filtering parity.

### B3. 将 credential module 变成 source/expiry/refresh/update layers

修改:

- `rust/Bruce-collector/crates/collector-credential/src/lib.rs`
- 计划拆出的 `collector-credential/src/sources.rs`
- 计划拆出的 `collector-credential/src/expiry.rs`
- 计划拆出的 `collector-credential/src/refresh.rs`
- 计划拆出的 `collector-credential/src/validation.rs`
- `collector-application/src/account.rs`

工作:

- App injected credentials、file reader、Keychain reader 统一成 read-only credential source.
- 统一 expiry 判定、时间单位转换和 refresh decision.
- refresh 通过 account single-flight, 失败输出 challenge/diagnostic.
- update validator 只允许结构化、脱敏、字段受限的 output.
- Codex retry-only 和 token manager 独占不迁移为一般 Provider refresh.
- App Keychain 写回继续由 Swift `CredentialUpdateCoordinator` 完成.

验证:

- source fixture 覆盖有效、缺失、损坏、过期、Keychain fallback 和敏感字段.
- refresh fixture 验证同账号并发只执行一次.
- update/challenge 经过 Bridge validation 后不泄露 secret.
- Rust 不产生 Keychain write 或第三方数据库 write.

### B4. 接入 application account execution

修改:

- `collector-application/src/account.rs`
- `collector-application/src/execution.rs`
- `collector-provider/src/`
- `collector-credential/src/`

工作:

- application 从 catalog 生成确定性 account plan.
- 每个账号先 resolve credential, 再调用对应 Provider adapter.
- local scan 和 account tasks 并行, quota result 进入 finalizer.
- Provider/credential 失败隔离到账号或 Provider, 不阻塞其他账号.
- 将 HTTP request count、retry count、refresh count 纳入诊断/benchmark metrics.

验证:

- 多账号 fixture 验证 stable result order、dedupe、single-flight 和 partial isolation.
- `externalQuotas` disabled 时不发 HTTP、不读网络 credential, artifact 仍与 Python 一致.
- App injected credential 与 CLI source 两种模式分别测试.

### B5. Slice B 性能门禁

必须补齐受控 HTTP fixture 后运行:

```bash
python3 scripts/benchmark-collector.py \
  --scenario account-scale \
  --runs 5 \
  --rust-account-fixture rust/Bruce-collector/target/debug/account-scale-fixture \
  --output /tmp/bruce-account-scale.json
```

验收重点:

- 并行后 wall time 下降, 但 HTTP request/retry/refresh 次数不增加.
- `network_workers`、`account_tasks` 和 response body limit 生效.
- 取消或 deadline 时不遗留活跃任务、permit 或 queue item.
- 账号规模增长时 RSS 和 queue backlog 有界.

### 5.6 当前实施记录 (2026-08-21)

已落地:

- `collector-application` 已成为唯一 Rust 采集编排入口. `collector-bridge` 只保留协议校验、大小限制、请求白名单、envelope 和输出校验调用, 不再直接依赖 `collector-local`、`collector-provider` 或 `collector-credential`.
- `RunContext` 已统一承载 window、deadline、cancellation、local/network/account permits、只读 credential source、HTTP adapter 和运行计数器. local scan 与 quota account worker 在同一 run 内并行, worker 数量受 `RuntimeLimits` 限制.
- Provider 已提供 stable registry 和 `UreqHttpClient` production transport. 传输层强制 HTTPS、使用 request timeout、读取 `max_response_body_bytes + 1` 后由统一 bounded result 校验; fixture 仍通过 `HttpClient` 注入.
- App `*QuotaAccounts` 注入已转换为稳定排序的 account plan. Claude/Grok 无注入账号时回退到只读 Keychain/file source; credential、provider 和 account 错误按账号隔离, 不把原始凭证写进 diagnostic、artifact 或 metrics.
- account execution 使用 `provider + service/account ID` single-flight, network/account permits 和确定性 result order. `externalQuotas` 未授权时不会读取网络 credential 或发送 HTTP.
- metrics 已记录实际 HTTP request count; credential refresh count 在当前阶段保持为 0, 因为 Rust 仍不直接执行 Swift Keychain 写回.
- 为 Rust 1.83/Cargo 1.83 锁定 `ureq 2.12.1`, `url 2.5.4`, `idna 1.0.3`, `idna_adapter 1.1.0` 和 `zeroize 1.8.1`, 避免最新间接依赖要求 edition 2024.

已验证:

- Rust workspace tests: 52 个单元/进程测试通过, 另有全部 doctest 通过.
- `cargo clippy --workspace --all-targets -- -D warnings` 通过.
- 注入 Kimi quota account 的 application fixture 验证 service 结果、HTTP request count 和 parser 输出.
- `externalQuotas` denied fixture 验证 0 次 HTTP、0 次 credential source 使用和既有占位服务语义.
- Python pytest: 261 passed; fixture secret scan: `secretFindings=[]`; valid Bridge differential: `PARITY OK`.

受控性能门禁:

- 新增 `account-scale-fixture` benchmark-only binary, 通过注入的 deterministic HTTP client 和 empty credential source 测试 4/16/32 账号规模. 该 target 不进入 Release bundle, 不读取 Keychain, 不访问网络.
- 执行命令: `python3 scripts/benchmark-collector.py --scenario account-scale --runs 5 --rust-account-fixture rust/Bruce-collector/target/debug/account-scale-fixture --output <temporary-json>`.
- 2026-08-21 结果: 15 samples, `http_request_count` 与账号数逐项一致 (4/16/32), `credential_refresh_count=0`, P50 wall `128.170 ms`, P95 wall `253.152 ms`, peak RSS P95 `9,322,496 bytes`. 结果文件留在临时目录, 不进入仓库.

仍留在后续迁移门:

- Codex retry-only 和 Antigravity 专用额度保持现有专属 owner, 不被一般 Provider refresh 接管.

### 5.7 Slice C 当前实施记录 (2026-08-21)

已落地:

- `UsageContribution`、`ModelDelta`、`ProjectDelta`、`UsageSample` 和 `SourceDeltaChange` 已下沉到 `collector-domain`. Contribution builder 只处理 window 内的派生 token 数据, 不包含 raw session、路径、凭证或 Provider response.
- `collector-local` 已移除 `collector-aggregate` 依赖. Cache hit、append、rewrite/rebuild、delete 都通过 `scan_tree_cached_with_sink` 发出 source-level replacement, wrapper 仅为旧测试 seam 收集 changes; production application path 不积累 raw records.
- application 已创建 `BoundedQueue<SourceDeltaChange>` 和 aggregate consumer. consumer 按 source identity 做 remove-old/add-new/re-add 去重, 在 sorted source ID 上 fold, 因而 queue capacity 和 producer 完成顺序不影响最终 artifact. queue cancel/deadline 时保留已消费 contribution 并输出 partial diagnostic.
- 增加 domain contribution serialization/window boundary 测试, aggregation remove/replace/re-add 测试, queue capacity invariance 测试, 并保留 local cache append/rewrite/delete/corrupt 覆盖.

已验证:

- `cargo test --workspace`: 52 个单元/进程测试通过, doctest 全部通过.
- `cargo clippy --workspace --all-targets -- -D warnings`: 通过.
- `cargo tree -p collector-local --depth 1`: 依赖只包含 `collector-domain`、`collector-runtime`、SQLite、serde 和哈希库, 不包含 `collector-aggregate`.
- `python3 -m pytest tests/`: 261 passed; `python3 scripts/check-collector-fixtures.py`: 15 个 fixture, `secretFindings=[]`; valid Bridge differential: `PARITY OK`.
- `python3 scripts/benchmark-collector.py --scenario all --runs 3 --rust rust/Bruce-collector/target/debug/Bruce-collector`: small/medium/large Rust warm P50 wall 分别为 `7.901/8.131/14.315 ms`, peak RSS P50 分别为 `10,616,832/10,797,056/10,944,512 bytes`; 三组 artifact hash 与 Python 对齐.

仍留在最终门禁:

- `zsh scripts/verify-local.sh`: Python 261 项、Rust workspace 52 项及 doctest、Clippy、Swift build 和全部 Harness 通过.
- `zsh scripts/build-test-app.sh`: 生成并校验 `dist/Bruce.app` 与 `dist/Bruce.zip` 通过. 为满足 bundle 源码路径拒绝规则, `runtime-manifest.zsh` 的 Rust 构建加入仓库路径 `--remap-path-prefix`; Release binary 与最终 bundle 均不含仓库绝对路径, codesign strict verify 通过.
- Release Developer ID、notarization/staple、spctl 和 signed artifact 安装/升级/回滚仍属于外部环境门禁; universal x86_64/arm64 Rust binary 已在本机生成并通过 smoke.

### 5.8 完整性能矩阵与冷启动优化记录 (2026-08-21)

已补齐并执行 `benchmark-collector-matrix.py`:

- 覆盖 `small/medium/large`、`14/182` 天、cold/warm/append/rewrite-truncate、`1/10/64` 账号、Provider success/failure 和 credential expiry.
- Python/Rust artifact parity 与 fixture invariant 均为 0 failure.
- 跨窗口/规模 aggregate target: cold wall P50 `0.5636x`, cold wall P95 `0.5692x`, warm unchanged wall P50 `0.0876x`, cold CPU P50 `0.2667x`, cold RSS P50 `0.3757x`, warm logical source bytes P50 `0.0000x`, 均达到开发文档 014 的目标.
- 为解决 182 天 cold rebuild 的主要开销, `collector-local` 使用紧凑 cache-only contribution (日桶使用索引数组), 不在每个 cache entry 重复存储完整 day list, 派生 cache entry 通过单 bounded writer 在扫描期间异步处理并以 atomic rename 提交; `UsageContributionBuilder` 的热路径使用整数 day index.
- 182 天 large cold 仍是单 case outlier, Rust P50 `470.714 ms` 高于 Python `283.545 ms`; 该限制已在验收证据中显式记录, 不用 aggregate target 掩盖.
- cache entry 的 parser version 已升到 `2`, 旧格式会在 `collector-cache-v1` 下安全重建.

完整明细见 [benchmark-evidence.md](./benchmark-evidence.md). `disk_read_bytes` 使用跨 Python/Rust 可复现的 `logical_source_bytes` 口径; 两端另输出 macOS `proc_pid_rusage` 的 `physical_disk_read_bytes` 可选计数, 不把物理计数缺失误报为零.

### 5.9 多源 Agent 空数据修复记录 (2026-08-21)

现象:

- 新版 App 使用 Rust Collector 时, token 用量和 Agent 用量全部显示为空.
- Rust 进程未收到用户 `home`、`now` 和 `timezone`, 因而无法解析默认本机会话路径和时间窗口.
- Rust application 当时只有 Kimi Code cache-backed source, 其他 Agent 仍使用占位结果.

已修复:

- `CollectorRunInput.agentUsageInput()` 注入绝对 `home`、ISO8601 `now`、IANA `timezone` 和 `days=182`; Rust 不再猜测用户目录或当前时间.
- `collector-local` 增加只读来源适配: Kimi Work、Claude Code、Codex/Orca、Grok (含 archived sessions)、OpenCode SQLite、Pi 和 ZCode SQLite.
- `collector-application` 按固定 Agent 顺序合并来源贡献, 保留 `not_found`、`unavailable`、`error` 语义, 并对齐 OpenCode/ZCode 缺失提示.
- Rust Harness 使用隔离 `home` fixture, 防止新增的输入契约被测试绕过.

验证:

- Release Rust Collector 使用本机真实数据运行约 7 秒; Kimi Code、Claude、Codex、Grok、OpenCode、Pi 和 ZCode 均返回可用状态, Kimi Work 按实际情况返回 `not_found`; 未再出现所有 Agent 占位为空.

### 5.10 Rust Codex 额度链路补齐记录 (2026-08-21)

现场问题:

- Swift 已注入 `codexQuotaAccounts` 和 `codexQuotaAccountOrder`, 但 Rust account planner 未注册该字段, 所以两个 Codex 账号没有 service 返回.
- `CodexQuotaSnapshotMerger` 因首轮/retry 均缺少账号 service, 记录 `CODEX_ACCOUNT_RESULT_MISSING`, 并把历史结果降为 stale.

已落地:

- `collector-provider` 新增 Codex quota adapter、`wham/usage` parser、SHA-256 service ID、请求头和窗口/credits 映射.
- `collector-application` 按 `codexQuotaAccountOrder` 建立稳定账号计划, 保存原始 account ID, 输出账号级 service; 401 只返回白名单 `accessRejected` challenge, 403/429/5xx/异常响应按账号隔离.
- `codexQuotaRetryOnly` 进入 Rust 时跳过本地 Agent 扫描, 只输出 Codex services, 继续由 Swift `CodexQuotaRecovery` 执行令牌刷新和一次 retry.
- `collector-bridge` 对 Codex 注入账号、order、字段白名单、数量和长度执行 fail-closed 校验.
- 不新增 Rust Keychain 写回; token 不进入 artifact、diagnostic、metrics 或 challenge.

验证证据:

- Rust workspace tests: 全部通过; Codex application/provider/bridge targeted tests 覆盖多账号顺序、成功、401 challenge、retry-only、响应解析和 secret redaction.
- `cargo clippy --workspace --all-targets -- -D warnings`: 通过.
- Python pytest: `261 passed`; fixture scan: `files=15`, `secretFindings=[]`; valid differential: `PARITY OK`.
- Swift `CollectorRunnerHarness`: 28 项通过; `RefreshSchedulerHarness`: 81 项通过; `swift build`: 通过.
- `zsh scripts/build-test-app.sh`: 重新生成 `dist/Bruce.app` 和 `dist/Bruce.zip`, bundled Rust collector smoke 的 initial/old-cache-rebuild/install/upgrade/rollback 通过.
- bundled Rust collector 使用脱敏 Codex 请求验证: 即使 fake token 被真实 endpoint 拒绝, artifact 仍返回 `codex_<sha256-prefix>` service 和 `accessRejected` challenge, 不再是空 service 列表.

边界:

- 当前默认验证不使用真实 Codex 账号成功响应, 以避免无额外授权的真实凭证请求;成功窗口由 Rust fixture parser/application tests 覆盖.
- `BruceOnboardingCoreHarness` 在当前 macOS Keychain `SecItemCopyMatching` 处被 SecurityServer 阻塞, 已停止该孤立进程;该环境阻塞不涉及 Codex provider 代码.
- OpenSpec 7.3 的签名/notarization/install/upgrade/rollback 发布门禁按用户决定继续不处理; 8.5 保持待执行.
- `python3 scripts/differential-collector.py`: `PARITY OK`.
- `python3 scripts/check-collector-fixtures.py`: 15 个 fixture, `secretFindings=[]`.
- `zsh scripts/verify-local.sh`: Python 261 passed, Rust workspace tests/Clippy、Swift build、全部 Harness 通过; `CollectorRunner tests passed: 28`.
- `zsh scripts/build-test-app.sh`: `dist/Bruce.app` 和 `dist/Bruce.zip` 已用同一 Rust binary 重建, Preview install/upgrade/rollback/cache smoke 通过.

边界:

- 7.3 的 Developer ID、公证、staple、spctl 和真实安装升级门禁仍按用户确认不处理.
- 多源非 Kimi 来源当前以有界 JSONL/SQLite 只读扫描为主; 本机当前 182 天窗口的 Release 采集约 7 秒, 后续可继续为这些来源增加派生 cache, 但不阻塞本次空数据修复.

## 6. Slice C: Local/cache/aggregate isolation

### C1. 把 contribution/change 类型下沉到 domain

修改:

- `rust/Bruce-collector/crates/collector-domain/src/lib.rs`
- `rust/Bruce-collector/crates/collector-aggregate/src/lib.rs`
- `rust/Bruce-collector/crates/collector-local/Cargo.toml`

工作:

- 定义无 IO 的 `UsageContribution`、`SourceDeltaChange` 和必要的 source identity/value objects.
- 将 cache 需要的派生 delta 表达从 aggregate implementation 中抽出到 domain contract.
- aggregate 提供消费 change 的 fold/merge/remove 逻辑, 不暴露给 local 文件 reader.
- 保持 pricing、time window、rounding、dedupe 和 previous aggregate semantics.

验证:

- contribution add/remove/re-add、同 source dedupe、window boundary 和 pricing version tests.
- 同一 change stream 在不同消费批次大小下输出相同 artifact.
- 空 source、损坏 source 和 partial source 保持既有状态.

### C2. 重构 local 为 source adapter + cache implementation

修改:

- `rust/Bruce-collector/crates/collector-local/Cargo.toml`
- `rust/Bruce-collector/crates/collector-local/src/lib.rs`
- `rust/Bruce-collector/crates/collector-local/src/sqlite.rs`
- 计划拆出的 `collector-local/src/cache.rs`
- 计划拆出的 `collector-local/src/jsonl.rs`
- 计划拆出的 `collector-local/src/source.rs`

工作:

- 移除 `collector-local -> collector-aggregate` 依赖.
- JSONL reader、SQLite reader、directory traversal 和 cache store 都转为 local 内部 implementation.
- 对外只输出 bounded `SourceDeltaChange`.
- unchanged/append/rewrite/truncate/delete/corrupt/version invalidation 分别产生正确 change.
- cache 使用 temp file + atomic rename, corruption 不覆盖 last known good.
- SQLite 使用 read-only URI、capability/schema check、参数化查询和 bounded rows.

验证:

- local integration tests 覆盖 182 天窗口、timezone/day boundary、append、rewrite、truncate、delete、cache corruption.
- 读取第三方 SQLite 的测试确认无 DDL、migration、repair 或 write.
- source change 顺序稳定, 不重复计数.
- `collector-local` 通过编译检查证明不再依赖 aggregate crate.

### C3. Application 接入 bounded change stream

修改:

- `collector-application/src/execution.rs`
- `collector-application/src/aggregation.rs`
- `collector-aggregate/src/lib.rs`

工作:

- application 创建 bounded queue 和 aggregate consumer.
- local producer 在读取 source 时流式推送 change, 不积累全量历史 record.
- aggregate consumer 处理 remove-old/add-new, 再交给 finalizer.
- local scan 失败时关闭 queue 并保留已经消费的可用结果, 输出 partial diagnostic.
- cancel/deadline 时 producer、consumer 和 cache writer 一起停止.

验证:

- queue capacity 不变时改变 worker 数量, artifact 保持相同.
- producer/consumer 取消不会死锁或丢失 permit.
- 大 fixture 的 peak RSS 不随 raw line 数线性增长.

### C4. Slice C 性能和安全门禁

运行:

```bash
python3 scripts/benchmark-collector.py \
  --scenario all \
  --runs 5 \
  --rust rust/Bruce-collector/target/debug/Bruce-collector \
  --output data/benchmarks/rust-final-local.json
python3 scripts/check-collector-fixtures.py
```

验收重点:

- unchanged warm refresh 的 disk read、wall、CPU 和 RSS 达到设计门禁.
- append 只读取安全 offset 后的数据.
- rewrite/delete 不产生重复 aggregate record.
- cache、fixture、诊断和日志无 raw session 或 credential secret.

## 7. Final hardening 和 Release cutover

### 7.1 全量验证

```bash
python3 -m pytest tests/
zsh scripts/verify-local.sh
```

并单独运行:

```bash
cargo fmt --check --manifest-path rust/Bruce-collector/Cargo.toml
cargo test --workspace --manifest-path rust/Bruce-collector/Cargo.toml
cargo clippy --workspace --all-targets --manifest-path rust/Bruce-collector/Cargo.toml -- -D warnings
swift build --package-path macos/BruceApp
zsh scripts/build-test-app.sh
```

必须保存的证据:

- Python pytest 数量和 Rust workspace 测试结果.
- Swift build/Harness 结果.
- 全部 differential fixture 结果.
- fixture security scan.
- cold/warm/account-scale benchmark JSON.
- Preview package 和 Release bundle validation 日志.

### 7.2 Release bundle

修改范围:

- `scripts/runtime-manifest.zsh`
- `scripts/build-release-app.sh`
- `scripts/build-test-app.sh`
- `scripts/verify-local.sh`
- Swift Release runtime readiness tests.

工作:

- Release 只复制 Rust universal binary.
- Preview 继续复制 Rust binary, Python 仅在 Debug/Preview 代码路径中可见.
- bundle validation 拒绝 Python source/runtime、data、fixture、secret、错误架构和不可执行 binary.
- Release binary 字符串扫描不出现 Python fallback marker.
- `scripts/collector-release-smoke.sh` 在 Preview 模式验证 Bridge 单 envelope、artifact schema、旧 cache rebuild、隔离 install/upgrade/rollback; 在 Release 模式追加 Developer ID、staple、spctl 和 universal arch 门禁.
- 签名、公证、staple、spctl、安装升级、旧 cache rebuild 和 rollback 使用真实发布环境验证.

### 7.3 Cutover decision

只有以下条件全部满足才标记 ready:

- Slice A/B/C 全部完成并通过 differential parity.
- local correctness、Provider/credential fixture、account-scale、resource benchmark 全部通过.
- Python/Rust/Swift/fixture/security 验证全部通过.
- universal binary 和 Release bundle validation 通过.
- Developer ID、notarization、staple、spctl 证据齐全.
- 安装、升级、旧 cache rebuild 和 rollback 演练完成.

否则保持 Rust Release 路径的 fail-closed 诊断, 使用上一版 Bruce App 回滚, 不通过运行时 flag 恢复 Python fallback.

## 8. 实现顺序摘要

```text
Slice 0  contract freeze / fixtures / baseline
   ↓
Slice A  application crate / thin bridge / current local path
   ↓
Slice B  runtime budget / provider registry / credential execution
   ↓
Slice C  domain contribution / local cache seam / bounded aggregation
   ↓
Hardening  parity / benchmark / security / Swift integration
   ↓
Release   universal signed Rust / install-upgrade-rollback / cutover
```

每个箭头都是一个验证门. 任一门失败时, 停留在上一 slice, 不把未验证的 Provider、credential 或 cache 变更继续传入 Release.
