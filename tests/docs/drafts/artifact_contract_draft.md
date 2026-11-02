# `artifact_contract` 模块功能点与测试草稿

> **module**: artifact_contract ｜ **type**: draft ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 来源与模块边界

- **源文档路径**：`docs/devel/design/01-数据采集与多模型计费引擎.md`、`docs/official/采集引擎与本地用量设计.md`、`README.md`
- **目标源码路径**：`core/collector/crates/collector-bridge/`、`apps/macos/Sources/BruceAppCore`（artifact 消费方）；契约样本位于 `tests/fixtures/artifacts/agent-usage/` 与 `tests/fixtures/bridge/agent-usage/`
- **存量测试备份**：`_test_anything_backup/original_tests/tests/fixtures/{artifacts,bridge}/`（已回填至新 `tests/fixtures/`）
- **模块职责边界**：Collector → Bridge → App 的 JSON artifact/响应契约。覆盖 bucket 计数一致性、状态语义、错误诊断字段；不覆盖 Rust 采集器内部扫描逻辑与 Swift 视图模型。

## 2. 功能点拆解清单 (Functional Points)

| 功能点 ID | 功能名称 | 触发与输入约束 | 预期行为与输出 | 边界与异常规则 | 来源定位 |
|---|---|---|---|---|---|
| `FP-artifact_contract-01` | Agent bucket 总量一致 | 读取 artifact `agents[]` | `today.total` = `input + output + cacheRead + cacheCreation` | 任一字段缺失视为契约破损 | design/01 §4；`tests/fixtures/artifacts/agent-usage/valid.json` |
| `FP-artifact_contract-02` | 模型分项汇总一致 | `agents[].todayModels[]` | 各 `total` 之和等于 `today.total` | 空数组时仅要求 `today.total` 为 0 | design/01 §4 |
| `FP-artifact_contract-03` | 空态 artifact | `collectionStatus === "empty"` | `agents`/`services` 为空数组，`totalCostUsd` 为 `null` | 不得伪造 0 成本 | `tests/fixtures/artifacts/agent-usage/empty.json` |
| `FP-artifact_contract-04` | 部分失败状态 | 单 agent `status` | 允许 `ok`/`not_found`/`error`，每个 agent 仍保留 `today` 对象 | 未知状态不应出现 | `tests/fixtures/artifacts/agent-usage/partial.json` |
| `FP-artifact_contract-05` | Bridge 响应状态契约 | Bridge 输出 `status` | `success`/`partial` 携带 artifact；`error` 的 artifact 为 `null` 且 `diagnostics[].code/category/stage/message` 非空 | 错误响应不得夹带半成品 artifact | `tests/fixtures/bridge/agent-usage/response-*.json` |

## 3. 候选测试点分流

### 3.1 单元测试候选 (`u_`)

| 候选编号 | 关联功能点 | 场景维度 (`normal`/`boundary`/`exception`) | 候选测试描述 | 来源类型 |
|---|---|---|---|---|
| `CAND-U-01` | `FP-artifact_contract-01` | `normal` | valid artifact 的 bucket 总量与 `today.total` 相等 | `both` |
| `CAND-U-02` | `FP-artifact_contract-02` | `normal` | `todayModels` 分项之和等于 `today.total` | `both` |
| `CAND-U-03` | `FP-artifact_contract-03` | `boundary` | empty artifact 的数组为空且 `totalCostUsd === null` | `both` |
| `CAND-U-04` | `FP-artifact_contract-04` | `exception` | partial artifact 含 `ok`/`not_found`/`error` 三种状态且均有 `today` | `both` |
| `CAND-U-05` | `FP-artifact_contract-05` | `exception` | error 响应 artifact 为 `null` 且诊断字段完整；success/partial 非空 | `both` |

### 3.2 性能基准候选 (`b_`)

| 候选编号 | 关联功能点 | 性能热点原因 | 计划负载规模 | 关注指标 |
|---|---|---|---|---|
| `CAND-B-01` | `FP-artifact_contract-01` | 每次刷新都要解析 artifact 并做一致性校验 | 5,000 次解析+校验 | `ops/sec`, `us/op` |

## 4. 待确认与实现差异 (Gaps)

| 差异编号 | 涉及功能点 | 差异类型 (`unimplemented`/`conflict`/`missing_data`) | 详细说明与处置方式 |
|---|---|---|---|
| `GAP-artifact_contract-01` | `FP-artifact_contract-01` | `missing_data` | Rust 侧 schema 校验由 collector 单测覆盖；本模块以共享 fixture 校验契约样本，不替代真实采集运行态 |
