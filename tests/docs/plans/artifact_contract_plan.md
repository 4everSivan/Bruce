# `artifact_contract` 模块测试计划

> **module**: artifact_contract ｜ **type**: module_plan ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 功能点 ↔ 用例 ID ↔ 源码符号 双向追溯矩阵

| 功能点 ID | 用例 ID | 类型 (`u_`/`b_`) | 场景/负载分类 | 目标源码文件与函数签名 | 对应测试代码位置 | 优先级 | 状态 |
|---|---|---|---|---|---|---|---|
| `FP-artifact_contract-01` | `UT-artifact_contract-001` | `u_` | `normal` | `collector-bridge` :: artifact `agents[].today` | `tests/unit/u_artifact_contract.test.mjs :: test_ut_artifact_contract_001_bucket_totals` | P0 | `active` |
| `FP-artifact_contract-02` | `UT-artifact_contract-002` | `u_` | `normal` | `collector-bridge` :: `agents[].todayModels` | `tests/unit/u_artifact_contract.test.mjs :: test_ut_artifact_contract_002_model_breakdown_totals` | P0 | `active` |
| `FP-artifact_contract-03` | `UT-artifact_contract-003` | `u_` | `boundary` | `collector-bridge` :: `collectionStatus=empty` | `tests/unit/u_artifact_contract.test.mjs :: test_ut_artifact_contract_003_empty_artifact` | P1 | `active` |
| `FP-artifact_contract-04` | `UT-artifact_contract-004` | `u_` | `exception` | `collector-bridge` :: `agents[].status` | `tests/unit/u_artifact_contract.test.mjs :: test_ut_artifact_contract_004_partial_statuses` | P1 | `active` |
| `FP-artifact_contract-05` | `UT-artifact_contract-005` | `u_` | `exception` | `collector-bridge` :: 响应 `status`/`artifact`/`diagnostics` | `tests/unit/u_artifact_contract.test.mjs :: test_ut_artifact_contract_005_bridge_response_contract` | P0 | `active` |
| `FP-artifact_contract-01` | `BM-artifact_contract-001` | `b_` | `hotspot` | `collector-bridge` :: artifact 解析+一致性校验 | `tests/benchmark/b_artifact_contract.bench.mjs :: bench_bm_artifact_contract_001_parse_validate` | P1 | `active` |

## 2. 模块夹具与 Mock 策略

- **数据夹具**：`tests/fixtures/artifact_contract_fixtures.json`（`_meta` + 样本路径与期望状态）
- **共享对拍夹具**：`tests/fixtures/{artifacts,bridge}/agent-usage/`（原路径保留）
- **Mock 边界**：只读 JSON 样本，不启动 Collector 子进程，不访问本机会话目录。
