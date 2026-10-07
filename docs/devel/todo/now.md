# 当前版本待办池 (now.md)

> **性质**: 临时缓冲池 ｜ **纪律**: 落地建卡即物理删除该行，零沉淀

---

## 1. 缺陷与回归待办 (Bugs)

| 登记编号 | 模块 | 现象简述 | 发现日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|
| BG-001 | 示例模块 | 描述发现的问题表现 | 2026-09-23 | 待建 C 卡 |
| BG-002 | BruceOnboardingCore Harness (TOK-01) | `markReauthFirstSaveFailureBlocksAndRetries` CI 间歇失败 (run 37441542527 绿 / 37442743288 红, 同代码): `validAccessToken` 预热后设置的 `failSaves` 配额疑似与其遗留并发保存任务竞争, 快照读不到 `storageBlocked`; 需查明 validAccessToken 是否遗留异步持久化并修测试或时序 | 2026-10-06 | 待建 C 卡 |
| BG-003 | apps/win 壳层 | get_dashboard (IPC 直采) 与调度器 run_refresh 双执行流无互斥; 前端刷新按钮一次点击触发两轮采集 (get_dashboard + refresh_now); 有凭证时出站额度查询翻倍易触发限流。建议采集收敛到调度器单通道 | 2026-10-07 | 待建 C 卡 |
| BG-004 | apps/win credentials.rs | `app_data_root_with` 对空白 APPDATA 未 trim (仅滤完全空串), 与 T01 已修正的 windows_cache_root/paths.rs env_non_empty trim 语义不一致; `APPDATA="  "` 会生成 `"  \Bruce"` 目录 | 2026-10-07 | 待建 C 卡 |
| BG-005 | apps/win credentials.rs | Windows icacls 收权静默尽力而为: exit code 不检查、USERNAME 可与真实账户名不符、失败无诊断; T03 卡与 README 验收口径 ("仅当前用户 ACL") 强于实际实现且从未真机验证 | 2026-10-07 | 待建 C 卡 |
| BG-006 | .github/workflows/ci.yml | release-windows 上传走 `gh api /releases` 列表端点无分页参数, release 超 30 个后草稿不在首页将上传失败; `cargo install tauri-cli --locked` 未钉版本, 违背同代钉版纪律 (Cargo.lock 管不到 CLI) | 2026-10-07 | 待建 C 卡 |
| BG-008 | apps/win credentials.rs | mac 开发回落与 mac App 共用 `~/Library/Application Support/Bruce/credentials.json`: Windows 壳 load 静默丢弃白名单外键后一旦保存, 会用过滤子集重写 mac App 凭证 (未知键被削) | 2026-10-07 | 待建 C 卡 |
| BG-009 | apps/win scheduler.rs | mac 有 `lastTriggerWasManual` 语义 (手动刷新不弹额度预警), Windows 手动刷新照常评估告警弹 Toast, 双端口径不一致 | 2026-10-07 | 待建 C 卡 |

---

## 2. 体验与参数微调 (Enhancements)

| 登记编号 | 模块 | 微调诉求 | 登记日期 | 处理去向 (建卡即删) |
|---|---|---|---|---|
| EN-001 | 示例模块 | 描述参数或体验微调细节 | 2026-09-23 | 待建 C 卡 |
| EN-002 | apps/win 前端 | Nothing 点阵主题仅有 settings.theme 字段与 body class 切换, styles.css 无 nothing 变体样式 (T03-5 "双主题" 声明超前于实现); 另 PanelParityHarness 手写 J 编码层与 Swift mapper 输出存在脱节风险 | 2026-10-07 | 待建 C 卡 |
| EN-003 | 对拍资产 | golden 对拍仅锁 valid.json 一个 fixture, partial.json 无 golden、empty.json 只查诊断; T02 验收 "全部共享 fixture" 口径与实际覆盖不符, 建议扩展 golden 覆盖 partial/empty | 2026-10-07 | 待建 C 卡 |
