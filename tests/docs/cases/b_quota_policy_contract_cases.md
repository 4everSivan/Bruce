# `quota_policy_contract` 模块性能基准规格 (`b_quota_policy_contract_cases`)

> **module**: quota_policy_contract ｜ **type**: benchmark_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 基准测试用例总表

| 用例 ID | 基准名称 | 关联功能点 | 目标源码符号 | 负载规模 | 核心采集指标 | 绑定基准函数 | 状态 |
|---|---|---|---|---|---|---|---|
| `BM-quota_policy_contract-001` | 三份夹具加载与结构校验 | `FP-quota_policy_contract-01` | `quota-*-parity / refresh-policy-parity` | 三份夹具 × 2,000 轮 | `ops/sec`, `us/op` | `bench_bm_quota_policy_contract_001_fixture_validation` | `active` |

## 2. 基准规格详情

### BM-quota_policy_contract-001: 三份夹具加载与结构校验

- **关联功能点与热点说明**：`FP-quota_policy_contract-01`；Rust 与 Swift 测试启动时都要加载三份共享裁判用例，fixture 膨胀会拖慢双端测试。
- **目标符号**：`quota-policy-parity` + `quota-carry-over-parity` + `refresh-policy-parity` 的结构校验
- **负载规模（Workload）**：三份夹具（21 + 15 + 3/10/12 条），2,000 轮校验。
- **预热与迭代策略**：100 次预热；固定 2,000 轮采样。
- **采集指标与基线阈值**：`ops/sec`、`us/op`；回归阈值 15%。
