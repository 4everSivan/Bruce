# 当前版本待办池 (now.md)

> **性质**: 临时缓冲池 ｜ **纪律**: 落地建卡即物理删除该行，零沉淀

---

## 1. 缺陷与回归待办 (Bugs)

| 登记编号 | 模块 | 现象简述 | 发现日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|
| B-001 | design/01 设计基线 §7.1「缓存持久化」 | 2026-10-16 复核：该节**三条断言全部与实现不符**，且系自诞生即错（非重构失同步）。(1) **路径**：`~/Library/Caches/Bruce/collector-cache/` 从未存在过 —— C001 重构之前的代码（`b2b580e^:rust/Bruce-collector/crates/collector-local/src/lib.rs:158`）已是 `Library/Application Support/Bruce/collector-cache-v1`；全仓（除本待办与 CHANGELOG/C054 记录外）零 `Library/Caches`，mac App 亦无法覆盖（`collector-application` 恒调 `default_cache_root`，仅 Windows 壳注入且注入同值）。真值：mac/Linux `~/Library/Application Support/Bruce/collector-cache-v1`、Windows `%LOCALAPPDATA%\Bruce\collector-cache-v1`；design/05 已记正确路径，design/01 为唯一孤例。(2) **结构**：所称「单会话缓存包含 `fingerprint`, `last_byte_offset`, `parsed_turn_count`, `bucket_deltas`」——后三个字段名在**全部 git 历史中零命中**（唯一次出现即 b2b580e 引入 design/01 正文本身）；现行模型为 C021 起的**源级缓存**，实体是 `JsonlCacheEntry` / `SqliteCacheEntry`（含 `safe_offset`、`head/prefix_tail_fingerprint`、`window_days`、`append_safe`、`capped` 等）。(3) **版本迁移**：`PARSER_VERSION = 2` / `AGGREGATION_VERSION = 2` 属实（另有 `CACHE_SCHEMA_VERSION = 1` 未提），但「版本升级时自动淘汰旧缓存文件」表述失准：版本失配是**忽略该条目并无损重建**（`cache_identity_matches` 不命中），文件删除只发生在源文件从源路径集合消失时（`jsonl_cache.rs:526`，计 `cache_deletions`）。C054 仅更正 README 表述，基线正文待单独建卡回写。 | 2026-10-16 | 待建卡 |

---

## 2. 体验与参数微调 (Enhancements)

| 登记编号 | 模块 | 微调诉求 | 登记日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|

---

> **本轮批次**: 2026-10-16 全仓对抗性审查发现的 12 项缺陷已全部立项并移出本表：
> C042–C051（已修复待复核）、C052（基线回写完成）、C048/C053（结构性债，登记 `future.md` TD-005/TD-006）。
