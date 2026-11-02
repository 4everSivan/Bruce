# `quota_policy_contract` 模块单元测试规格 (`u_quota_policy_contract_cases`)

> **module**: quota_policy_contract ｜ **type**: unit_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 单元测试用例总表

| 用例 ID | 用例标题 | 关联功能点 | 场景类型 (`normal`/`boundary`/`exception`) | 目标源码符号 | 绑定测试函数 | 状态 |
|---|---|---|---|---|---|---|
| `UT-quota_policy_contract-001` | 查询门禁用例结构 | `FP-quota_policy_contract-01` | `normal` | `quota-policy-parity.cases[]` | `test_ut_quota_policy_contract_001_quota_cases_structure` | `active` |
| `UT-quota_policy_contract-002` | provider 集合一致性 | `FP-quota_policy_contract-02` | `exception` | `quota-policy-parity :: enabledProviders` | `test_ut_quota_policy_contract_002_provider_set_consistency` | `active` |
| `UT-quota_policy_contract-003` | 回填用例结构 | `FP-quota_policy_contract-03` | `normal` | `quota-carry-over-parity.cases[]` | `test_ut_quota_policy_contract_003_carry_over_structure` | `active` |
| `UT-quota_policy_contract-004` | 刷新边界用例结构 | `FP-quota_policy_contract-04` | `boundary` | `refresh-policy-parity :: boundaryIds/boundaryWake/backoff` | `test_ut_quota_policy_contract_004_refresh_boundary_types` | `active` |

## 2. 用例规格详情

### UT-quota_policy_contract-001: 查询门禁用例结构

- **关联功能点**：`FP-quota_policy_contract-01`（查询门禁用例结构）
- **目标符号**：`tests/fixtures/quota-policy-parity/cases.json :: cases[].expected`
- **场景类型**：`normal`
- **前置条件与夹具**：`quota-policy-parity/cases.json`
- **输入参数（Given / When）**：遍历 `cases`
- **预期结果与断言（Then）**：
  1. `cases.length === 21`
  2. 每条 `name` 非空且全局唯一
  3. `expected` 必含 `includeExternalQuotas`（布尔）、`skipProviders`（数组）、`rateLimitedProviders`（数组）

### UT-quota_policy_contract-002: provider 集合一致性

- **关联功能点**：`FP-quota_policy_contract-02`（门禁 provider 一致性）
- **目标符号**：`quota-policy-parity :: enabledProviders`
- **场景类型**：`exception`
- **前置条件与夹具**：`quota-policy-parity/cases.json`
- **输入参数（Given / When）**：每条用例的 `enabledProviders` 与 `expected`
- **预期结果与断言（Then）**：
  1. `skipProviders` 中每个 provider 都出现在 `enabledProviders`
  2. `rateLimitedProviders` 中每个 provider 都出现在 `enabledProviders`
  3. 断言失败时带出用例名与越界 provider

### UT-quota_policy_contract-003: 回填用例结构

- **关联功能点**：`FP-quota_policy_contract-03`（回填用例结构）
- **目标符号**：`quota-carry-over-parity.cases[]`
- **场景类型**：`normal`
- **前置条件与夹具**：`quota-carry-over-parity/cases.json`
- **输入参数（Given / When）**：遍历 `cases`
- **预期结果与断言（Then）**：
  1. `cases.length === 15`，`name` 唯一
  2. 每条含 `policy`、`previous`、`current`、`expected` 数组
  3. `policy` 含 `includeExternalQuotas`、`skipProviders`、`rateLimitedProviders`

### UT-quota_policy_contract-004: 刷新边界用例结构

- **关联功能点**：`FP-quota_policy_contract-04`（刷新边界用例结构）
- **目标符号**：`refresh-policy-parity :: boundaryIds/boundaryWake/backoff`
- **场景类型**：`boundary`
- **前置条件与夹具**：`refresh-policy-parity/cases.json`
- **输入参数（Given / When）**：三组数组
- **预期结果与断言（Then）**：
  1. `boundaryIds`（3）、`boundaryWake`（10）、`backoff`（12）均非空
  2. `boundaryIds[].expected` 中每个时间戳为有限数字或 `null`
  3. services 内 `resetsAt` 只允许有限数字、`null` 或缺失
