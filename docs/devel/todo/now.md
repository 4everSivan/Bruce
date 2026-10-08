# 当前版本待办池 (now.md)

> **性质**: 临时缓冲池 ｜ **纪律**: 落地建卡即物理删除该行，零沉淀

---

## 1. 缺陷与回归待办 (Bugs)

| 登记编号 | 模块 | 现象简述 | 发现日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|
| BG-001 | 示例模块 | 描述发现的问题表现 | 2026-09-23 | 待建 C 卡 |
| BG-002 | BruceOnboardingCore Harness (TOK-01) | `markReauthFirstSaveFailureBlocksAndRetries` CI 间歇失败 (run 37441542527 绿 / 37442743288 红, 同代码): `validAccessToken` 预热后设置的 `failSaves` 配额疑似与其遗留并发保存任务竞争, 快照读不到 `storageBlocked`; 需查明 validAccessToken 是否遗留异步持久化并修测试或时序 | 2026-10-06 | 待建 C 卡 |
| BG-006 | .github/workflows/ci.yml | release-windows 上传走 `gh api /releases` 列表端点无分页参数, release 超 30 个后草稿不在首页将上传失败; `cargo install tauri-cli --locked` 未钉版本, 违背同代钉版纪律 (Cargo.lock 管不到 CLI) | 2026-10-07 | 待建 C 卡 |

---

## 2. 体验与参数微调 (Enhancements)

| 登记编号 | 模块 | 微调诉求 | 登记日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|
| EN-001 | 示例模块 | 描述参数或体验微调细节 | 2026-09-23 | 待建 C 卡 |
