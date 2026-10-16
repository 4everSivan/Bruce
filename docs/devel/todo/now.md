# 当前版本待办池 (now.md)

> **性质**: 临时缓冲池 ｜ **纪律**: 落地建卡即物理删除该行，零沉淀

---

## 1. 缺陷与回归待办 (Bugs)

| 登记编号 | 模块 | 现象简述 | 发现日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|
| B-001 | design/01 设计基线 | 「缓存文件统一保存在 `~/Library/Caches/Bruce/collector-cache/`」与实现不符：`collector-local::default_cache_root` 实际解析为 `~/Library/Application Support/Bruce/collector-cache-v1`（Windows 为 `%LOCALAPPDATA%\Bruce\collector-cache-v1`），全仓无任何 `Library/Caches` 路径。C054 仅更正 README 表述，基线正文待单独建卡回写。 | 2026-10-16 | 待建卡 |

---

## 2. 体验与参数微调 (Enhancements)

| 登记编号 | 模块 | 微调诉求 | 登记日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|

---

> **本轮批次**: 2026-10-16 全仓对抗性审查（`docs/devel/2026-10-16-全仓对抗性审查报告.md`）
> 发现的 12 项缺陷已全部立项并移出本表：C042–C051（已修复待复核）、C052（基线回写完成）、
> C048/C053（结构性债，登记 `future.md` TD-005/TD-006，独立开批实施）。
