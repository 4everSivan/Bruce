# 远期特性与技术债池 (future.md)

> **性质**: 跨版本远期池 ｜ **发版约定**: 每次版本发版前必须联合评审本表事项（立项/推迟/废弃）

---

## 1. 远期特性规划 (Future Features)

| 规划编号 | 业务领域 | 方向概述 | 期望版本 | 状态 |
|---|---|---|---|---|

---

## 2. 技术债务排查 (Technical Debts)

| 债务编号 | 模块 | 债务风险说明 | 发现日期 | 建议处置方案 |
|---|---|---|---|---|
| TD-002 | collector-domain PricingTable | DeepSeek V4 Pro 峰谷双价 (`$1.32/$3.96` vs `$0.66/$1.98`) 与 Qwen3.7 Plus >256K 分档 (`$0.40/$1.60` vs `$1.20/$4.80`) 未建模，现按非峰值/单档建卡（已按非峰值/单档口径登记于 design/01） | 2026-10-14 | **2026-10-28 评估**：无法在现有聚合层准确计价 —— `UsageAccumulator` 按模型×日合并为 `TokenBucket`，已丢失请求时间与单请求输入长度。需先扩展 `TokenBucket` 分时/分档份额并升 `AGGREGATION_VERSION`、采集适配器逐样本分流、价卡改为带时间段/阈值的规则集，再建独立卡实施；本批次暂缓，费用保持单档近似（详见 design/01「分时/分档价卡的扩展门槛」） |
| TD-005 | collector-application 编排层 | **既有重构已下沉 ProviderOutcome / 新鲜度 / 失败类别 / 挑战与凭据解析；剩余** `codexQuotaRetryOnly` 短路与 `collect_codex_quota_retry_only` 独立路径仍在编排层（`lib.rs`），新增 provider 无需改此处，但 codex 重试语义尚未由 provider 层声明式表达 | 2026-10-16 | 独立开卡：先补 codex 重试/降级回归用例，再把重试请求改为通用「仅额度重试」契约并删除 codex 专属入口；禁止与其它改动混批 |
