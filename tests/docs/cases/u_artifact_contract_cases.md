# `artifact_contract` 模块单元测试规格 (`u_artifact_contract_cases`)

> **module**: artifact_contract ｜ **type**: unit_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 单元测试用例总表

| 用例 ID | 用例标题 | 关联功能点 | 场景类型 (`normal`/`boundary`/`exception`) | 目标源码符号 | 绑定测试函数 | 状态 |
|---|---|---|---|---|---|---|
| `UT-artifact_contract-001` | Agent bucket 总量一致 | `FP-artifact_contract-01` | `normal` | `collector-bridge :: agents[].today` | `test_ut_artifact_contract_001_bucket_totals` | `active` |
| `UT-artifact_contract-002` | 模型分项汇总一致 | `FP-artifact_contract-02` | `normal` | `collector-bridge :: agents[].todayModels` | `test_ut_artifact_contract_002_model_breakdown_totals` | `active` |
| `UT-artifact_contract-003` | 空态 artifact | `FP-artifact_contract-03` | `boundary` | `collector-bridge :: collectionStatus=empty` | `test_ut_artifact_contract_003_empty_artifact` | `active` |
| `UT-artifact_contract-004` | 部分失败状态 | `FP-artifact_contract-04` | `exception` | `collector-bridge :: agents[].status` | `test_ut_artifact_contract_004_partial_statuses` | `active` |
| `UT-artifact_contract-005` | Bridge 响应状态契约 | `FP-artifact_contract-05` | `exception` | `collector-bridge :: status/artifact/diagnostics` | `test_ut_artifact_contract_005_bridge_response_contract` | `active` |

## 2. 用例规格详情

### UT-artifact_contract-001: Agent bucket 总量一致

- **关联功能点**：`FP-artifact_contract-01`（Agent bucket 总量一致）
- **目标符号**：`collector-bridge :: agents[].today`
- **场景类型**：`normal`
- **前置条件与夹具**：`tests/fixtures/artifacts/agent-usage/valid.json`
- **输入参数（Given / When）**：遍历 `artifact.agents`
- **预期结果与断言（Then）**：
  1. 每个 agent 的 `today.total` 等于 `input + output + cacheRead + cacheCreation`
  2. 所有分项均为有限非负数
  3. 至少验证 1 个 agent（示例为 124000）

### UT-artifact_contract-002: 模型分项汇总一致

- **关联功能点**：`FP-artifact_contract-02`（模型分项汇总一致）
- **目标符号**：`collector-bridge :: agents[].todayModels`
- **场景类型**：`normal`
- **前置条件与夹具**：`valid.json`
- **输入参数（Given / When）**：每个 agent 的 `todayModels`
- **预期结果与断言（Then）**：
  1. `todayModels[].total` 之和等于 `today.total`
  2. `todayModels` 为空时 `today.total === 0`

### UT-artifact_contract-003: 空态 artifact

- **关联功能点**：`FP-artifact_contract-03`（空态 artifact）
- **目标符号**：`collector-bridge :: collectionStatus=empty`
- **场景类型**：`boundary`
- **前置条件与夹具**：`tests/fixtures/artifacts/agent-usage/empty.json`
- **输入参数（Given / When）**：读取 `artifact`
- **预期结果与断言（Then）**：
  1. `collectionStatus === "empty"`
  2. `agents` 与 `services` 均为空数组
  3. `totalCostUsd === null`

### UT-artifact_contract-004: 部分失败状态

- **关联功能点**：`FP-artifact_contract-04`（部分失败状态）
- **目标符号**：`collector-bridge :: agents[].status`
- **场景类型**：`exception`
- **前置条件与夹具**：`tests/fixtures/artifacts/agent-usage/partial.json`
- **输入参数（Given / When）**：遍历 `agents`
- **预期结果与断言（Then）**：
  1. 状态均落在 `ok`/`not_found`/`error` 集合内
  2. 样本中至少出现 `ok` 与 `not_found`；`error` 若出现也合法
  3. 每个 agent 仍含 `today` 对象

### UT-artifact_contract-005: Bridge 响应状态契约

- **关联功能点**：`FP-artifact_contract-05`（Bridge 响应状态契约）
- **目标符号**：`collector-bridge :: status/artifact/diagnostics`
- **场景类型**：`exception`
- **前置条件与夹具**：`tests/fixtures/bridge/agent-usage/response-*.json`
- **输入参数（Given / When）**：逐个读取响应
- **预期结果与断言（Then）**：
  1. `success`/`partial` 的 `artifact` 非 `null`
  2. `error` 的 `artifact === null`
  3. `diagnostics[]` 每项含非空 `code`/`category`/`stage`/`message`
  4. 顶层 `schemaVersion === 1`
