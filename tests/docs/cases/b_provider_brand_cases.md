# `provider_brand` 模块性能基准规格 (`b_provider_brand_cases`)

> **module**: provider_brand ｜ **type**: benchmark_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 基准测试用例总表

| 用例 ID | 基准名称 | 关联功能点 | 目标源码符号 | 负载规模 | 核心采集指标 | 绑定基准函数 | 状态 |
|---|---|---|---|---|---|---|---|
| `BM-provider_brand-001` | glyph 键查表吞吐 | `FP-provider_brand-01` | `provider-brand.js :: BRUCE_PROVIDER_GLYPHS[key]` | 19 个键 × 20,000 轮 | `ops/sec`, `ns/op` | `bench_bm_provider_brand_001_lookup` | `active` |

## 2. 基准规格详情

### BM-provider_brand-001: glyph 键查表吞吐

- **关联功能点与热点说明**：`FP-provider_brand-01`；工作台逐行渲染 Agent/模型徽章时按 key 查表，属于高频读取路径。
- **目标符号**：`apps/win/src/provider-brand.js :: window.BRUCE_PROVIDER_GLYPHS[key]`
- **负载规模（Workload）**：9 个 agent + 10 个模型 glyph 键，20,000 轮（380,000 次查表）。
- **预热与迭代策略**：1,000 轮预热；固定 20,000 轮采样。
- **采集指标与基线阈值**：`ops/sec`、`ns/op`；回归阈值 15%。
