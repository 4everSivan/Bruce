# `provider_brand` 模块测试计划

> **module**: provider_brand ｜ **type**: module_plan ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 功能点 ↔ 用例 ID ↔ 源码符号 双向追溯矩阵

| 功能点 ID | 用例 ID | 类型 (`u_`/`b_`) | 场景/负载分类 | 目标源码文件与函数签名 | 对应测试代码位置 | 优先级 | 状态 |
|---|---|---|---|---|---|---|---|
| `FP-provider_brand-01` | `UT-provider_brand-001` | `u_` | `normal` | `apps/win/src/provider-brand.js :: window.BRUCE_PROVIDER_GLYPHS` | `tests/unit/u_provider_brand.test.mjs :: test_ut_provider_brand_001_agent_glyph_coverage` | P0 | `active` |
| `FP-provider_brand-02` | `UT-provider_brand-002` | `u_` | `normal` | 同上 :: `agent-brand-parity.models[].glyph` | `tests/unit/u_provider_brand.test.mjs :: test_ut_provider_brand_002_model_glyph_coverage` | P0 | `active` |
| `FP-provider_brand-03` | `UT-provider_brand-003` | `u_` | `boundary` | 同上 :: `{vb, shapes}` 结构 | `tests/unit/u_provider_brand.test.mjs :: test_ut_provider_brand_003_glyph_geometry_integrity` | P1 | `active` |
| `FP-provider_brand-04` | `UT-provider_brand-004` | `u_` | `exception` | 同上 :: `unknownAgents/unknownModels` | `tests/unit/u_provider_brand.test.mjs :: test_ut_provider_brand_004_unknown_identity_absent` | P1 | `active` |
| `FP-provider_brand-01` | `BM-provider_brand-001` | `b_` | `hotspot` | 同上 :: glyph 键查表 | `tests/benchmark/b_provider_brand.bench.mjs :: bench_bm_provider_brand_001_lookup` | P2 | `active` |

## 2. 模块夹具与 Mock 策略

- **数据夹具**：`tests/fixtures/provider_brand_fixtures.json`（`_meta` + 期望 glyph 键集合）
- **共享对拍夹具**：`tests/fixtures/agent-brand-parity/cases.json`（原路径保留）
- **Mock 边界**：使用 `node:vm` 在隔离上下文中执行生成文件，仅提供空 `window`，不加载 DOM 或 Tauri。
