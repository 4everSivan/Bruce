# `pricing_catalog` 模块性能基准规格 (`b_pricing_catalog_cases`)

> **module**: pricing_catalog ｜ **type**: benchmark_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 基准测试用例总表

| 用例 ID | 基准名称 | 关联功能点 | 目标源码符号 | 负载规模 | 核心采集指标 | 绑定基准函数 | 状态 |
|---|---|---|---|---|---|---|---|
| `BM-pricing_catalog-001` | 目录解析与结构校验 | `FP-pricing_catalog-01` | `config/pricing-catalog.json :: JSON.parse + validate` | 5,000 次 | `ops/sec`, `us/op` | `bench_bm_pricing_catalog_001_parse_validate` | `active` |

## 2. 基准规格详情

### BM-pricing_catalog-001: 目录解析与结构校验

- **关联功能点与热点说明**：`FP-pricing_catalog-01`；设置页与工作台每次同步都要解析 22 KB 价格表并做结构校验，解析成本直接影响启动与同步响应。
- **目标符号**：`config/pricing-catalog.json :: JSON.parse + 字段校验`
- **负载规模（Workload）**：仓库内 95 条模型目录，约 22 KB；5,000 次解析+校验。
- **预热与迭代策略**：前 200 次预热不计时；随后固定 5,000 次采样，取总耗时与平均值。
- **采集指标与基线阈值**：`ops/sec`、`us/op`；回归阈值沿用 `tests/.state/config.json` 的 15%。首次运行记录基线。
