# 远期特性与技术债池 (future.md)

> **性质**: 跨版本远期池 ｜ **发版约定**: 每次版本发版前必须联合评审本表事项（立项/推迟/废弃）

---

## 1. 远期特性规划 (Future Features)

| 规划编号 | 业务领域 | 方向概述 | 期望版本 | 状态 |
|---|---|---|---|---|
| FT-001 | 示例领域 | 远期功能构想（不写细节，立项时入 design） | v2.0 | 规划中 |

---

## 2. 技术债务排查 (Technical Debts)

| 债务编号 | 模块 | 债务风险说明 | 发现日期 | 建议处置方案 |
|---|---|---|---|---|
| TD-001 | 示例模块 | 描述架构坏味道或潜在性能隐患 | 2026-09-23 | 待后续重构建 C 卡 |
| TD-002 | collector-domain PricingTable | DeepSeek V4 Pro 峰谷双价 (`$1.32/$3.96` vs `$0.66/$1.98`) 与 Qwen3.7 Plus >256K 分档 (`$0.40/$1.60` vs `$1.20/$4.80`) 未建模, 现按单档建卡 (T06 已按非峰值/单档口径登记于 design/01) | 2026-10-14 | 待后续按需扩展 ModelPricing 分时/分档结构并建 C 卡 |
| TD-003 | apps/win 订阅额度看板 | Windows 侧设置/看板 Provider 清单落后于 macOS: design/05 记载 "9 Provider", 而 macOS 已含 Jev(界面隐藏) 与 Cline/ClinePass(T06) 共 11 家; 双端凭据白名单共享 (ALLOWED_CREDENTIAL_FIELDS), 但 Windows 无对应配置 UI 与卡片渲染对齐 | 2026-10-14 | 待后续按 C005-C009 Windows 对齐模式建卡补齐 (或明确 Windows 暂不纳管新增 Provider) |
