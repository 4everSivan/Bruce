# `pricing_catalog` 模块测试计划

> **module**: pricing_catalog ｜ **type**: module_plan ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 功能点 ↔ 用例 ID ↔ 源码符号 双向追溯矩阵

| 功能点 ID | 用例 ID | 类型 (`u_`/`b_`) | 场景/负载分类 | 目标源码文件与函数签名 | 对应测试代码位置 | 优先级 | 状态 |
|---|---|---|---|---|---|---|---|
| `FP-pricing_catalog-01` | `UT-pricing_catalog-001` | `u_` | `normal` | `config/pricing-catalog.json` :: 顶层结构 | `tests/unit/u_pricing_catalog.test.mjs :: test_ut_pricing_catalog_001_schema_contract` | P0 | `active` |
| `FP-pricing_catalog-02` | `UT-pricing_catalog-002` | `u_` | `boundary` | `pricing.rs :: CatalogFile.models` | `tests/unit/u_pricing_catalog.test.mjs :: test_ut_pricing_catalog_002_unique_model_ids` | P0 | `active` |
| `FP-pricing_catalog-03` | `UT-pricing_catalog-003` | `u_` | `exception` | `pricing.rs :: CatalogModel.input/output/cacheRead` | `tests/unit/u_pricing_catalog.test.mjs :: test_ut_pricing_catalog_003_numeric_field_integrity` | P0 | `active` |
| `FP-pricing_catalog-04` | `UT-pricing_catalog-004` | `u_` | `normal` | `pricing.rs :: is_valid_updated_at` | `tests/unit/u_pricing_catalog.test.mjs :: test_ut_pricing_catalog_004_updated_at_format` | P1 | `active` |
| `FP-pricing_catalog-01` | `BM-pricing_catalog-001` | `b_` | `hotspot` | `config/pricing-catalog.json` :: 解析+结构校验 | `tests/benchmark/b_pricing_catalog.bench.mjs :: bench_bm_pricing_catalog_001_parse_validate` | P1 | `active` |

## 2. 模块夹具与 Mock 策略

- **数据夹具**：`tests/fixtures/pricing_catalog_fixtures.json`（`_meta` + 期望的 schemaVersion、模型数、字段清单）
- **Mock 边界**：无外部依赖；直接读取仓库内价格表，不访问 GitHub 远端。
