# `quota_policy_contract` 模块功能点与测试草稿

> **module**: quota_policy_contract ｜ **type**: draft ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 来源与模块边界

- **源文档路径**：`docs/devel/design/08-跨端共享策略核心.md`、`docs/devel/design/02-订阅额度与凭据安全存储.md`
- **目标源码路径**：`core/collector/crates/collector-policy/`、`tests/fixtures/quota-policy-parity/`、`quota-carry-over-parity/`、`refresh-policy-parity/`
- **存量测试备份**：`_test_anything_backup/original_tests/tests/fixtures/`（已回填至新 `tests/fixtures/`）；Rust `quota_parity.rs`/`refresh_parity.rs` 与 Swift Harness 仍在原生位置运行
- **模块职责边界**：三份双端共享裁判用例的结构完整性：额度查询门禁、回填合并、窗口边界与刷新退避。本模块只保证 fixture 自身可作为双端裁判输入；策略算法由 Rust/Swift 测试执行。

## 2. 功能点拆解清单 (Functional Points)

| 功能点 ID | 功能名称 | 触发与输入约束 | 预期行为与输出 | 边界与异常规则 | 来源定位 |
|---|---|---|---|---|---|
| `FP-quota_policy_contract-01` | 查询门禁用例结构 | `quota-policy-parity.cases[]` | 21 条用例，名称唯一；`expected` 必含 `includeExternalQuotas`、`skipProviders`、`rateLimitedProviders` | 缺键或类型不符即不可消费 | `tests/fixtures/quota-policy-parity/cases.json`；design/08 |
| `FP-quota_policy_contract-02` | 门禁 provider 一致性 | 用例 `enabledProviders` 与 `expected` | `skipProviders`、`rateLimitedProviders` 均为 `enabledProviders` 子集 | 越界 provider 视为 fixture 错误 | 同上 |
| `FP-quota_policy_contract-03` | 回填用例结构 | `quota-carry-over-parity.cases[]` | 15 条用例，均含 `policy/previous/current/expected` 数组 | 缺数组或名称重复即失败 | `tests/fixtures/quota-carry-over-parity/cases.json` |
| `FP-quota_policy_contract-04` | 刷新边界用例结构 | `refresh-policy-parity` | `boundaryIds`/`boundaryWake`/`backoff` 均为非空数组；边界 ID 的 `resetsAt` 仅允许有限数字或 `null`/缺失 | 非数字字符串等非法时间戳应暴露 | `tests/fixtures/refresh-policy-parity/cases.json` |

## 3. 候选测试点分流

### 3.1 单元测试候选 (`u_`)

| 候选编号 | 关联功能点 | 场景维度 (`normal`/`boundary`/`exception`) | 候选测试描述 | 来源类型 |
|---|---|---|---|---|
| `CAND-U-01` | `FP-quota_policy_contract-01` | `normal` | 21 条门禁用例名称唯一且 `expected` 三键齐全 | `legacy_tests` |
| `CAND-U-02` | `FP-quota_policy_contract-02` | `exception` | skip/rateLimited 不超出 enabledProviders | `legacy_tests` |
| `CAND-U-03` | `FP-quota_policy_contract-03` | `normal` | 15 条回填用例结构完整且名称唯一 | `legacy_tests` |
| `CAND-U-04` | `FP-quota_policy_contract-04` | `boundary` | 刷新边界与退避数组非空，时间戳类型合法 | `legacy_tests` |

### 3.2 性能基准候选 (`b_`)

| 候选编号 | 关联功能点 | 性能热点原因 | 计划负载规模 | 关注指标 |
|---|---|---|---|---|
| `CAND-B-01` | `FP-quota_policy_contract-01` | 双端测试启动时批量加载并校验三份夹具 | 三份夹具 × 2,000 轮校验 | `ops/sec`, `us/op` |

## 4. 待确认与实现差异 (Gaps)

| 差异编号 | 涉及功能点 | 差异类型 (`unimplemented`/`conflict`/`missing_data`) | 详细说明与处置方式 |
|---|---|---|---|
| `GAP-quota_policy_contract-01` | `FP-quota_policy_contract-01` | `missing_data` | 策略执行结果由 Rust `collector-policy` 与 Swift Harness 对拍；Node 侧只校验 fixture 结构与 provider 集合约束 |
