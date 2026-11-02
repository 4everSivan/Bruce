# `pricing_presentation` 模块性能基准规格 (`b_pricing_presentation_cases`)

> **module**: pricing_presentation ｜ **type**: benchmark_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 基准测试用例总表

| 用例 ID | 基准名称 | 关联功能点 | 目标源码符号 | 负载规模 | 核心采集指标 | 绑定基准函数 | 状态 |
|---|---|---|---|---|---|---|---|
| `BM-pricing_presentation-001` | 同步状态机吞吐 | `FP-pricing_presentation-04` | `pricing-presentation.js :: stageDisplay` | 13 条 stage × 2,000 轮 | `ops/sec`, `ns/op` | `bench_bm_pricing_presentation_001_stage_display` | `active` |
| `BM-pricing_presentation-002` | 时间格式化吞吐 | `FP-pricing_presentation-03` | `pricing-presentation.js :: timestamp` | 10,000 次 | `ops/sec`, `ns/op` | `bench_bm_pricing_presentation_002_timestamp` | `active` |

## 2. 基准规格详情

### BM-pricing_presentation-001: 同步状态机吞吐

- **关联功能点与热点说明**：`FP-pricing_presentation-04`；状态区在每次同步进度与倒计时 tick 时重算，属于高频纯计算路径。
- **目标符号**：`apps/win/src/pricing-presentation.js :: stageDisplay(stage)`
- **负载规模（Workload）**：`pricing-sync-parity.cases.json` 的 13 条 stage，循环 2,000 轮（26,000 次调用）。
- **预热与迭代策略**：先跑 5 轮预热；随后固定 2,000 轮采样。
- **采集指标与基线阈值**：`ops/sec`、`ns/op`；回归阈值 15%。

### BM-pricing_presentation-002: 时间格式化吞吐

- **关联功能点与热点说明**：`FP-pricing_presentation-03`；同步副标题与状态栏时间每次渲染都会格式化。
- **目标符号**：`apps/win/src/pricing-presentation.js :: timestamp(iso, now)`
- **负载规模（Workload）**：同日/跨天/空值 3 组输入，合计 10,000 次调用。
- **预热与迭代策略**：200 次预热；固定 10,000 次采样。
- **采集指标与基线阈值**：`ops/sec`、`ns/op`；回归阈值 15%。
