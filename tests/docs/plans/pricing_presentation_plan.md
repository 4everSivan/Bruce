# `pricing_presentation` 模块测试计划

> **module**: pricing_presentation ｜ **type**: module_plan ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 功能点 ↔ 用例 ID ↔ 源码符号 双向追溯矩阵

| 功能点 ID | 用例 ID | 类型 (`u_`/`b_`) | 场景/负载分类 | 目标源码文件与函数签名 | 对应测试代码位置 | 优先级 | 状态 |
|---|---|---|---|---|---|---|---|
| `FP-pricing_presentation-01` | `UT-pricing_presentation-001` | `u_` | `normal` | `apps/win/src/pricing-presentation.js :: copy` | `tests/unit/u_pricing_presentation.test.mjs :: test_ut_pricing_presentation_001_copy_parity` | P1 | `active` |
| `FP-pricing_presentation-02` | `UT-pricing_presentation-002` | `u_` | `boundary` | `apps/win/src/pricing-presentation.js :: currentCatalogSubtitle(source, modelCount)` | `tests/unit/u_pricing_presentation.test.mjs :: test_ut_pricing_presentation_002_current_catalog_subtitle` | P1 | `active` |
| `FP-pricing_presentation-03` | `UT-pricing_presentation-003` | `u_` | `normal` | `apps/win/src/pricing-presentation.js :: timestamp(iso, now)` | `tests/unit/u_pricing_presentation.test.mjs :: test_ut_pricing_presentation_003_sync_time_format` | P1 | `active` |
| `FP-pricing_presentation-04` | `UT-pricing_presentation-004` | `u_` | `normal` | `apps/win/src/pricing-presentation.js :: stageDisplay(stage)` | `tests/unit/u_pricing_presentation.test.mjs :: test_ut_pricing_presentation_004_stage_display_matrix` | P0 | `active` |
| `FP-pricing_presentation-05` | `UT-pricing_presentation-005` | `u_` | `boundary` | `apps/win/src/pricing-presentation.js :: isSyncButtonEnabled/isRestoreButtonEnabled` | `tests/unit/u_pricing_presentation.test.mjs :: test_ut_pricing_presentation_005_button_enablement` | P1 | `active` |
| `FP-pricing_presentation-04` | `BM-pricing_presentation-001` | `b_` | `hotspot` | `apps/win/src/pricing-presentation.js :: stageDisplay(stage)` | `tests/benchmark/b_pricing_presentation.bench.mjs :: bench_bm_pricing_presentation_001_stage_display` | P1 | `active` |
| `FP-pricing_presentation-03` | `BM-pricing_presentation-002` | `b_` | `hotspot` | `apps/win/src/pricing-presentation.js :: timestamp(iso, now)` | `tests/benchmark/b_pricing_presentation.bench.mjs :: bench_bm_pricing_presentation_002_timestamp` | P2 | `active` |

## 2. 模块夹具与 Mock 策略

- **数据夹具**：`tests/fixtures/pricing_presentation_fixtures.json`（`_meta` + 时间边界与状态机期望）
- **共享对拍夹具**：`tests/fixtures/pricing-sync-parity/cases.json`（与 mac 侧共享）
- **Mock 边界**：纯函数，无 DOM、无网络、无时钟依赖；`now` 由用例显式传入。
