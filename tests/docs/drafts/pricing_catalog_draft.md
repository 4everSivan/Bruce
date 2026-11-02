# `pricing_catalog` 模块功能点与测试草稿

> **module**: pricing_catalog ｜ **type**: draft ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 来源与模块边界

- **源文档路径**：`docs/devel/design/09-模型价格表远端同步.md`、`docs/official/设置中心与价格校准设计.md`、`README.md`
- **目标源码路径**：`config/pricing-catalog.json`、`core/collector/crates/collector-domain/src/pricing.rs`（`CatalogFile::parse_and_validate`、`builtin_catalog`、`PricingTable::resolve`）
- **存量测试备份**：`_test_anything_backup/original_tests/tests/fixtures/`（36 个共享 fixture 已回填至新 `tests/fixtures/`）；Rust 单测仍留在 `collector-domain` 原生位置
- **模块职责边界**：模型基准价格表的唯一事实源与版本契约。本模块只覆盖目录文件的结构、身份唯一性、数值合法性、版本戳格式；Rust 计费算法与价格解析仍由 `cargo test` 覆盖，不在本模块重复。

## 2. 功能点拆解清单 (Functional Points)

| 功能点 ID | 功能名称 | 触发与输入约束 | 预期行为与输出 | 边界与异常规则 | 来源定位 |
|---|---|---|---|---|---|
| `FP-pricing_catalog-01` | 目录文件结构契约 | 读取 `config/pricing-catalog.json` | 顶层含 `schemaVersion`、`updatedAt`、`models`；`schemaVersion === 1`；`models` 非空数组 | 缺字段或版本不符时应拒绝加载 | design/09 §4；pricing.rs:57-99 |
| `FP-pricing_catalog-02` | 模型身份唯一 | 遍历 `models[].model` | 95 条目录项，`model` 键均唯一且非空 | 重复键视为目录损坏 | pricing.rs:62-90 |
| `FP-pricing_catalog-03` | 计费字段合法性 | 遍历每条目录项 | `displayName`/`vendor`/`note` 为非空字符串；`input`/`output`/`cacheRead` 为有限非负数 | 负数、`NaN`、缺字段应被拒 | pricing.rs:34-60 |
| `FP-pricing_catalog-04` | 版本戳格式与比较 | `updatedAt` 形如 `YYYY-MM-DD.N` | 可由 `compare_updated_at` 字典序比较，远端旧版本不得覆盖本地 | 非法格式应拒绝 | pricing.rs:124-166；design/09 |

## 3. 候选测试点分流

### 3.1 单元测试候选 (`u_`)

| 候选编号 | 关联功能点 | 场景维度 (`normal`/`boundary`/`exception`) | 候选测试描述 | 来源类型 |
|---|---|---|---|---|
| `CAND-U-01` | `FP-pricing_catalog-01` | `normal` | 断言 `schemaVersion === 1`、`updatedAt` 存在、`models` 为非空数组 | `both` |
| `CAND-U-02` | `FP-pricing_catalog-02` | `boundary` | 95 条模型键全部唯一，无空键 | `docs` |
| `CAND-U-03` | `FP-pricing_catalog-03` | `exception` | 所有计费字段为有限非负数，字符串字段非空 | `docs` |
| `CAND-U-04` | `FP-pricing_catalog-04` | `normal` | `updatedAt` 匹配 `^\d{4}-\d{2}-\d{2}\.\d+$`，且同格式可比较 | `docs` |

### 3.2 性能基准候选 (`b_`)

| 候选编号 | 关联功能点 | 性能热点原因 | 计划负载规模 | 关注指标 |
|---|---|---|---|---|
| `CAND-B-01` | `FP-pricing_catalog-01` | Node 侧消费方每次同步需解析 22 KB 目录并做结构校验 | 5,000 次解析+校验 | `ops/sec`, `us/op` |

## 4. 待确认与实现差异 (Gaps)

| 差异编号 | 涉及功能点 | 差异类型 (`unimplemented`/`conflict`/`missing_data`) | 详细说明与处置方式 |
|---|---|---|---|
| `GAP-pricing_catalog-01` | `FP-pricing_catalog-04` | `missing_data` | Node 侧没有与 Rust `compare_updated_at` 完全同构的生产实现；本模块只校验格式与字典序语义，双端一致性由 `collector-domain` 单测与 mac/win 共享用例保证 |
