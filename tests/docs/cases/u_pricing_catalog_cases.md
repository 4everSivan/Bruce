# `pricing_catalog` 模块单元测试规格 (`u_pricing_catalog_cases`)

> **module**: pricing_catalog ｜ **type**: unit_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 单元测试用例总表

| 用例 ID | 用例标题 | 关联功能点 | 场景类型 (`normal`/`boundary`/`exception`) | 目标源码符号 | 绑定测试函数 | 状态 |
|---|---|---|---|---|---|---|
| `UT-pricing_catalog-001` | 目录顶层结构与 schemaVersion | `FP-pricing_catalog-01` | `normal` | `config/pricing-catalog.json :: 顶层结构` | `test_ut_pricing_catalog_001_schema_contract` | `active` |
| `UT-pricing_catalog-002` | 模型 ID 全局唯一 | `FP-pricing_catalog-02` | `boundary` | `pricing.rs :: CatalogFile.models` | `test_ut_pricing_catalog_002_unique_model_ids` | `active` |
| `UT-pricing_catalog-003` | 计费字段合法 | `FP-pricing_catalog-03` | `exception` | `pricing.rs :: CatalogModel.input/output/cacheRead` | `test_ut_pricing_catalog_003_numeric_field_integrity` | `active` |
| `UT-pricing_catalog-004` | updatedAt 版本戳格式 | `FP-pricing_catalog-04` | `normal` | `pricing.rs :: is_valid_updated_at` | `test_ut_pricing_catalog_004_updated_at_format` | `active` |

## 2. 用例规格详情

### UT-pricing_catalog-001: 目录顶层结构与 schemaVersion

- **关联功能点**：`FP-pricing_catalog-01`（目录文件结构契约）
- **目标符号**：`config/pricing-catalog.json :: schemaVersion / updatedAt / models`
- **场景类型**：`normal`
- **前置条件与夹具**：读取 `config/pricing-catalog.json`；期望值来自 `tests/fixtures/pricing_catalog_fixtures.json`
- **输入参数（Given / When）**：解析后的目录对象
- **预期结果与断言（Then）**：
  1. `schemaVersion === 1`
  2. `updatedAt` 为非空字符串
  3. `models` 为数组且长度等于夹具期望数（95）

### UT-pricing_catalog-002: 模型 ID 全局唯一

- **关联功能点**：`FP-pricing_catalog-02`（模型身份唯一）
- **目标符号**：`pricing.rs :: CatalogFile.models`
- **场景类型**：`boundary`
- **前置条件与夹具**：`config/pricing-catalog.json`
- **输入参数（Given / When）**：`models.map(m => m.model)`
- **预期结果与断言（Then）**：
  1. 每个 `model` 为非空字符串
  2. `new Set(ids).size === ids.length`
  3. 唯一 ID 数量等于夹具期望数

### UT-pricing_catalog-003: 计费字段合法

- **关联功能点**：`FP-pricing_catalog-03`（计费字段合法性）
- **目标符号**：`pricing.rs :: CatalogModel.input/output/cacheRead`
- **场景类型**：`exception`
- **前置条件与夹具**：`config/pricing-catalog.json`
- **输入参数（Given / When）**：逐条读取目录项
- **预期结果与断言（Then）**：
  1. `displayName`、`vendor`、`note` 均为非空字符串
  2. `input`、`output` 为有限数字且 `>= 0`
  3. `cacheRead` 允许为 `null`（源码 `Option<f64>` 缺省），非 `null` 时必须是有限非负数
  4. 任一字段不满足时断言失败并带出 `model` 值

### UT-pricing_catalog-004: updatedAt 版本戳格式

- **关联功能点**：`FP-pricing_catalog-04`（版本戳格式与比较）
- **目标符号**：`pricing.rs :: is_valid_updated_at`
- **场景类型**：`normal`
- **前置条件与夹具**：`config/pricing-catalog.json`
- **输入参数（Given / When）**：`updatedAt` 字符串
- **预期结果与断言（Then）**：
  1. 匹配 `^\d{4}-\d{2}-\d{2}\.\d+$`
  2. `Date.parse` 可解析日期部分
  3. 同格式两个版本按字符串比较结果与数字段比较一致
