# 远期特性与技术债池 (future.md)

> **性质**: 跨版本远期池 ｜ **发版约定**: 每次版本发版前必须联合评审本表事项（立项/推迟/废弃）

---

## 1. 远期特性规划 (Future Features)

| 规划编号 | 业务领域 | 方向概述 | 期望版本 | 状态 |
|---|---|---|---|---|
| FF-001 | 跨端架构 | 把 mac Swift 与 Windows Rust 重复实现的刷新策略（额度门禁 / 回填 / Codex 快照合并等）收敛为一份 Rust 实现，分期评估见 design/08 草稿 | 待定 | 设计草稿待维护者批准；批准后拆 T 卡 |

---

## 2. 技术债务排查 (Technical Debts)

| 债务编号 | 模块 | 债务风险说明 | 发现日期 | 建议处置方案 |
|---|---|---|---|---|
| TD-002 | collector-domain PricingTable | DeepSeek V4 Pro 峰谷双价 (`$1.32/$3.96` vs `$0.66/$1.98`) 与 Qwen3.7 Plus >256K 分档 (`$0.40/$1.60` vs `$1.20/$4.80`) 未建模, 现按单档建卡 （已按非峰值/单档口径登记于 design/01） | 2026-10-14 | 待后续按需扩展 ModelPricing 分时/分档结构并建 C 卡 |
| TD-003 | apps/win 订阅额度看板 | Windows 侧设置/看板 Provider 清单落后于 macOS: design/05 记载 "9 Provider", 而 macOS 已含 Jev(界面隐藏) 与 Cline/ClinePass 共 11 家（2026-10-16 基线回写后统一为 10 家）; 双端凭据白名单共享 (ALLOWED_CREDENTIAL_FIELDS), 但 Windows 无对应配置 UI 与卡片渲染对齐 | 2026-10-14 | 待后续按既有 Windows 对齐模式建卡补齐 (或明确 Windows 暂不纳管新增 Provider) |
| TD-004 | collector-local 缓存层 | **遗留自「缓存与原子写盘去重复」变更**：四套缓存适配器各自持有 `fingerprint_range` / `ends_with_newline` / `append_is_safe` 与自有签名结构（`FileSignature`/`JsonlFileSignature`/`SqliteSignature`），逐字重复仅 3 个函数但分属两套类型系统，机械合并在不变更类型契约前收益有限；余额是任何指纹/追加语义修复都需改两处（跨窗口合并清空缺陷已实际发生） | 2026-10-16 | 并入巨型文件结构重构：抽 `cache_util` 统一签名与追加安全判定原语，再收敛写盘模板 |
| TD-005 | collector-application 编排层 | **遗留自「provider 专属逻辑下沉」变更**：codex 专属语义（`freshness`/`failureKind`/`challenge`/`codexQuotaRetryOnly` 短路）与 claude/grok 凭据硬编码分支留在编排层（`execution.rs:250-337`、`lib.rs:106-113`）；新增 provider 需改 3 个 crate，抽象收益递减。改法已定（provider 层标准化输出 `ProviderOutcome`），但触及刚经「额度窗口边界唤醒」与「缓存结构修复」验证的 codex 重试与降级路径，需独立回归窗口 | 2026-10-16 | 独立开卡：先补 codex 重试/降级回归用例再重构，禁止与其它改动混批 |
| TD-006 | 巨型文件内聚 | `sources.rs` 5,231 行 / `collector-provider/lib.rs` 4,155 行 / `SettingsView.swift` 1,972 行 / `SubscriptionService.swift` 1,630 行，均已违反单一职责（详见审查报告 §4.2）。纯结构重构无行为收益但显著降低 review 与缺陷定位成本 | 2026-10-16 | 独立开卡（已建卡，状态 pending）：按数据源/解析器/面板/服务四组机械切片，以既有全部测试全绿为验收 |
| TD-008 | mac 凭据迁移逻辑 | `CodexCredentialStore.swift`（814 行，约 55% 为迁移/校验机器）与 Windows 侧 `credentials/lifecycle.rs`（555 行）各自实现「旧格式 → v2 账号库」迁移，无对拍 fixture 覆盖迁移路径 | 2026-10-16 | 补迁移路径的双端 fixture 对拍，或明确迁移只在 mac 侧发生并在 design/02 记录 |
| TD-009 | apps/macos 菜单栏与面板口径 | 面板订阅段经「验证门禁 + mapper 过滤」，而菜单栏摘要用未门控 artifact（`AppModel.swift:599-611` → `MenuBarMetrics.swift:130-147` 仅过滤 status=error/failed），三处口径各异：菜单栏「最低剩余额度」可能来自面板已隐藏的 provider | 2026-10-16 | 统一为同一门禁输入后再计算菜单栏摘要；需先明确产品口径（菜单栏是否应跟随验证门禁） |
| TD-010 | collector-credential 只读探测 | `read_claude_token` / `read_grok_token` / `is_expired` 生产零调用（mac 生产路径按 design/02 走 Swift 注入），仅测试消费者，长期靠无 `#[allow(dead_code)]` 的 pub 导出存活 | 2026-10-16 | 若确认无 CLI 直读计划则删除并下沉语义至测试 fixture；若保留则加文档说明其为兼容面（兼容面取舍已记录） |
| TD-011 | apps/win 设置窗口前端 | `apps/win/src/settings.js` 3,259 行，为单个 IIFE 闭包，超出 design/00「单文件内聚与规模边界」约 1,500 行的上限。实测（2026-10-26）各职责段均读写共享可变状态并引用大量顶层绑定：工作台 586 行 15 处外部引用（可变 `settings` / `currentRuntimeInfo` / `selectedTimeRange`）、模型计费 287 行 13 处、Provider 配置对话框 470 行 36 处、Codex 登录 147 行 9 处、StepFun 网页登录 580 行 40 处、软件更新 151 行 11 处；拆分不是纯移动，需先抽共享状态 | 2026-10-26 | 独立开卡：先抽 `settings-state.js`（共享状态 + `node` / `byId` / `invoke` 等基础助手，挂 `window.BruceSettingsCore`），再按段拆为按序加载的经典脚本（DOM 测试 harness 已按 settings.html 的 `<script src>` 顺序加载，无需改造）；以 Windows 前端用例与 Windows 真机冒烟为验收；2026-10-26 架构审查轮因无法真机验证而暂缓 |
| TD-012 | apps/macos 看板滚动区 | `MenuBarViews.swift` 的 `SuppressorView` 在面板可见期间以 0.3 s 周期 Timer 轮询并压制 NSScrollView 的 scroller（macOS 26 上 `.scrollIndicators(.hidden)` 不生效，SwiftUI 会反复重设 `hasVerticalScroller`）；隐藏态已停止计时。每次回调只沿 superview 链查找一次 NSScrollView，开销很小，但属轮询 | 2026-10-26 | 可改为 KVO 观察 `hasVerticalScroller` / `hasHorizontalScroller` / `scrollerStyle` 并监听 `NSScroller.preferredScrollerStyleDidChangeNotification`，事件驱动后去掉 Timer；须在 macOS 26 真机目视确认滚动条不再闪现后再替换 |
