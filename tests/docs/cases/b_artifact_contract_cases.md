# `artifact_contract` 模块性能基准规格 (`b_artifact_contract_cases`)

> **module**: artifact_contract ｜ **type**: benchmark_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 基准测试用例总表

| 用例 ID | 基准名称 | 关联功能点 | 目标源码符号 | 负载规模 | 核心采集指标 | 绑定基准函数 | 状态 |
|---|---|---|---|---|---|---|---|
| `BM-artifact_contract-001` | artifact 解析与一致性校验 | `FP-artifact_contract-01` | `collector-bridge :: artifact JSON` | 5,000 次 | `ops/sec`, `us/op` | `bench_bm_artifact_contract_001_parse_validate` | `active` |

## 2. 基准规格详情

### BM-artifact_contract-001: artifact 解析与一致性校验

- **关联功能点与热点说明**：`FP-artifact_contract-01`；每次面板刷新与工作台切换都要解析 artifact 并核对 bucket 总量，解析成本直接影响刷新延迟。
- **目标符号**：`tests/fixtures/artifacts/agent-usage/valid.json :: JSON.parse + bucket 校验`
- **负载规模（Workload）**：`valid.json` 样本，5,000 次解析+校验。
- **预热与迭代策略**：200 次预热；固定 5,000 次采样。
- **采集指标与基线阈值**：`ops/sec`、`us/op`；回归阈值 15%。
