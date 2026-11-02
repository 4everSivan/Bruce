# `quota_policy_contract` 模块测试计划

> **module**: quota_policy_contract ｜ **type**: module_plan ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 功能点 ↔ 用例 ID ↔ 源码符号 双向追溯矩阵

| 功能点 ID | 用例 ID | 类型 (`u_`/`b_`) | 场景/负载分类 | 目标源码文件与函数签名 | 对应测试代码位置 | 优先级 | 状态 |
|---|---|---|---|---|---|---|---|
| `FP-quota_policy_contract-01` | `UT-quota_policy_contract-001` | `u_` | `normal` | `tests/fixtures/quota-policy-parity/cases.json` :: `cases[].expected` | `tests/unit/u_quota_policy_contract.test.mjs :: test_ut_quota_policy_contract_001_quota_cases_structure` | P0 | `active` |
| `FP-quota_policy_contract-02` | `UT-quota_policy_contract-002` | `u_` | `exception` | 同上 :: `enabledProviders` ⊆ 校验 | `tests/unit/u_quota_policy_contract.test.mjs :: test_ut_quota_policy_contract_002_provider_set_consistency` | P0 | `active` |
| `FP-quota_policy_contract-03` | `UT-quota_policy_contract-003` | `u_` | `normal` | `tests/fixtures/quota-carry-over-parity/cases.json` :: `previous/current/expected` | `tests/unit/u_quota_policy_contract.test.mjs :: test_ut_quota_policy_contract_003_carry_over_structure` | P1 | `active` |
| `FP-quota_policy_contract-04` | `UT-quota_policy_contract-004` | `u_` | `boundary` | `tests/fixtures/refresh-policy-parity/cases.json` :: `boundaryIds/boundaryWake/backoff` | `tests/unit/u_quota_policy_contract.test.mjs :: test_ut_quota_policy_contract_004_refresh_boundary_types` | P1 | `active` |
| `FP-quota_policy_contract-01` | `BM-quota_policy_contract-001` | `b_` | `hotspot` | 三份夹具 :: 加载+结构校验 | `tests/benchmark/b_quota_policy_contract.bench.mjs :: bench_bm_quota_policy_contract_001_fixture_validation` | P2 | `active` |

## 2. 模块夹具与 Mock 策略

- **数据夹具**：`tests/fixtures/quota_policy_contract_fixtures.json`（`_meta` + 三份夹具的路径与期望条数）
- **共享对拍夹具**：`tests/fixtures/{quota-policy-parity,quota-carry-over-parity,refresh-policy-parity}/`（原路径保留）
- **Mock 边界**：不调用 Rust/Swift 策略实现；策略语义由原生测试对拍，本模块只校验裁判输入契约。
