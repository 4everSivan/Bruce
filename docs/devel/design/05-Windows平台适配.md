# Windows 平台适配设计方案

<!-- @topic: WindowsCompat -->
> **文档ID**: DESIGN-WINDOWS ｜ **状态**: 现行基线
> **最后更新**: 2026-10-06 ｜ **所属总体**: [00-系统总体设计.md](00-系统总体设计.md) ｜ **对应 Topic**: `WindowsCompat`
> 📌 **变更总账**: 参见 [变更总账 (WindowsCompat)](../change/index.json#WindowsCompat)

---

## 1. 简介 (Introduction)

本文档定义 Bruce 从 macOS 菜单栏应用向 **Windows 10/11 托盘常驻应用** 扩展的完整技术方案。Windows 版与 mac 版共享同一采集引擎（`core/collector`，Rust）与同一 artifact 数据契约，UI 层独立实现，行为一致性由双端 fixture 对拍测试锁定。

三项方向性决策已于 2026-10-06 由用户拍板：

| 决策点 | 结论 |
|---|---|
| UI 技术路线 | **Tauri 2**（Rust 后端 + WebView2 前端），collector 以 Rust lib 进程内嵌入，不经 stdio Bridge |
| 首版功能范围 | **首版全量**：本地会话扫描 + 订阅额度出站查询 + 配额通知 + 全局热键 + 设置中心 + Onboarding 凭证引导一次对齐 |
| Core 逻辑归属 | **Windows 侧 Rust 实现 + 双端 fixture 对拍**：`BruceAppCore` 的视图模型/调度/账本逻辑在 Windows 侧以 Rust 重实现，与 mac Swift 端用同一组 artifact fixture 逐字段对拍 |

关键背景（2026-10-06 实测，基线 v0.9.0 / `0a7f2e2`）：当前代码库已完成大量跨平台铺垫，Rust 采集端的 Windows 化剩余改动**已收敛至 1 处硬编码路径**；主要工作量在 Windows UI 壳与视图模型层的全新实现（对齐 mac 侧约 31k 行 Swift 的能力矩阵）。

---

## 2. 目标与非目标 (Goals & Non-Goals)

### 2.1 目标 (Goals)
1. **单引擎双平台**：`core/collector` 保持唯一采集真理源，Windows 端进程内调用，artifact schema 与 mac 完全一致（`schemas/agent-usage-v1.json`）；
2. **托盘常驻形态**：Windows 托盘图标 + 点击弹出置顶看板面板，对齐 mac 菜单栏交互模型；
3. **首版全量功能矩阵**：会话扫描、订阅额度、配额 Toast 通知、全局热键、设置中心与价格校准、Onboarding 凭证引导全部交付；
4. **行为一致性可证明**：视图模型层双端 fixture 对拍，同一 artifact 输入下 mac Swift 输出与 Windows Rust 输出逐字段一致；
5. **双平台 CI**：`windows-latest` CI job 覆盖 Rust 全量测试，mac 侧现有 3 job 不回退。

### 2.2 非目标 (Non-Goals)
1. **液态玻璃不移植**：`NSGlassEffectView` / macOS 26 门控（`GlassTheme.swift` 等）为 mac 独占，Windows 恒走 Fluent/经典风格分支；
2. **Daimon Widget 不迁移**（`apps/widget/`）：Windows 无 Daimon 宿主；
3. **Linux 不承诺**：路径表天然大部分覆盖 Linux，但不做适配、不做验收；
4. **mac 侧不做架构重构**：Swift Core 保持 mac 事实源地位，Windows 适配严禁反向污染 mac 代码路径；
5. **不充当代理/网关**：延续 00 总体设计红线，仅旁路只读分析。

---

## 3. 需求分析 (Requirements)

### 3.1 Rust Collector 依赖面实测（基线 v0.9.0 / `0a7f2e2`）

| 模块 | 现状 | 结论 |
|---|---|---|
| 会话源路径表 | 已是独立跨平台模块 `collector-application/src/paths.rs`：opencode 含 `%LOCALAPPDATA%`/`%APPDATA%` 探测（:59-96）；kimi-work 含 3 组 Windows 候选（:107-175）；orca 含 `%APPDATA%` 分支（:178-193）；claude/codex/grok/pi/zcode/codebuddy 走 `~/.xxx` 布局（:25-52, :196-208），Windows 上天然解析为 `%USERPROFILE%\.xxx` | **已就绪**，待真机实测回填 |
| kimi-work / orca 源 | 路径探测按目录存在性自动空转，Windows 无对应应用时零输出 | **无需禁用决策** |
| 凭证读取 | `collector-credential/src/lib.rs:74-78`：`read_keychain` trait 默认 `Ok(None)`（Keychain 归属 Swift App 侧）；Claude CLI 走 注入→Keychain trait→文件回退 `~/.claude/.credentials.json`（:169-187），无 `/usr/bin/security` 子进程依赖 | **已就绪**，Windows 补一个 `CredentialSource` 实现即可 |
| 缓存文件身份与权限 | inode/dev 身份非 unix 回落 `(0, 0)`（`collector-local/src/sources.rs:361-370`、`lib.rs:324`）；0600 权限仅 `#[cfg(unix)]`（`lib.rs:829, 868`） | **已就绪** |
| 平台度量 | `collector-bridge/src/metrics.rs:9-32`：`physical_disk_read_bytes` 非 macOS 恒 `None` | **已就绪**，可选后续接 PDH |
| 纯逻辑 crates | `collector-runtime`（预算/取消原语）、`collector-aggregate`、`collector-domain`、`collector-provider`（ureq/rustls 出站）均无平台分支 | **已就绪** |
| **缓存根目录** | `collector-local/src/lib.rs:157-158`：`default_cache_root` 硬编码 `~/Library/Application Support/Bruce/collector-cache-v1` | **唯一硬编码残留**，Windows 需 `%LOCALAPPDATA%\Bruce\collector-cache-v1` |

### 3.2 Swift 侧规模（重写面）

| 模块 | 规模（2026-10-06 实测） | Windows 处置 |
|---|---|---|
| `BruceApp`（UI + 系统集成） | 30 文件 / 13,175 行；AppKit/Carbon/UserNotifications 集成面 13 文件（托盘 `MenuBarStatusItemController`、玻璃面板 `DashboardGlassPanelController`、热键 `GlobalHotkeyMonitor`/`Recorder`、通知 `QuotaAlertNotifier` 等） | 整体重写为 Tauri 前端 + Rust 系统集成 |
| `BruceAppCore`（视图模型/调度/账本） | 34 文件 / 9,493 行；仅 `RefreshScheduler.swift:1` 一处 AppKit 导入（NSWorkspace 唤醒监听），其余纯 Foundation | **Rust 重实现 + fixture 对拍**（本设计 §6.2） |
| `BruceOnboardingCore`（凭证引导/门控） | 30 文件 / 8,248 行（含 Keychain 写入 `OnboardingConfiguration`） | Rust/前端重实现，凭证落盘改 Windows 等价方案（§4.3） |
| `BruceGlassSurfaceCore` | 1 文件 / 396 行 | 不移植（液态玻璃非目标） |

### 3.3 CI 与脚本

- `.github/workflows/ci.yml`：3 job 全 `macos-26`（:15, :29, :47），无 Windows 覆盖；
- `scripts/*.sh` 全部 zsh/bash 且假设 mac 工具链（codesign/plutil/swift run），Windows 需独立 PowerShell 产物线；
- `verify-local.sh` 中 Rust 平台无关部分（fmt/test/clippy + fixture 扫描）需抽取为双平台可复用入口。

### 3.4 Windows 真机待实测清单（P0 回填本表）

| 项 | 待确认内容 |
|---|---|
| Claude Code | `%USERPROFILE%\.claude\projects` 会话布局；CLI 凭证实际位置（预期 `~/.claude/.credentials.json` 或 Credential Manager） |
| Codex | `%USERPROFILE%\.codex\sessions` 布局 |
| Grok / Pi / ZCode / CodeBuddy | `~/.grok`、`~/.pi/agent/sessions`、`~/.zcode/cli/db/db.sqlite`、`~/.codebuddy/projects` 在 Windows 的真实布局 |
| OpenCode | `%LOCALAPPDATA%\opencode\opencode.db` vs `%APPDATA%` 实际落点（`paths.rs:59-96` 已覆盖双候选） |
| 增量缓存 | Windows 目录元数据在长驻写句柄未关闭时可能报告陈旧文件大小：实测各 Agent 会话文件的写入模式（追加即关 vs 长驻句柄），确认增量追加检测在真实采集节奏下可靠（CI 已见测试级复现，见 T01） |
| WebView2 | Windows 10 目标版本上 Evergreen Runtime 可用性 |

---

## 4. 功能设计 (Functional Design)

### 4.1 系统集成能力映射

| 能力 | mac 实现 | Windows 实现 |
|---|---|---|
| 托盘常驻 | `NSStatusItem` + `NSPanel` | Tauri tray（`Shell_NotifyIcon`）+ 置顶无边框 WebView 面板 |
| 弹出看板 | `DashboardGlassPanelController`（NSGlassEffectView） | Tauri WebviewWindow（skip taskbar、失焦自动隐藏） |
| 液态玻璃 | `GlassTheme` macOS 26 门控 | **不移植**，恒走 Fluent/Mica 观感分支 |
| 全局热键 | Carbon `RegisterEventHotKey`（`GlobalHotkeyMonitor`） | Tauri global-shortcut 插件（`RegisterHotKey`） |
| 配额通知 | `UNUserNotificationCenter`（`QuotaAlertNotifier`） | Tauri notification 插件（Windows Toast） |
| 唤醒补采 | `NSWorkspace.didWake`（`RefreshScheduler.swift:174`） | 可选 `WM_POWERBROADCAST` 监听；首版可由退避调度兜底 |
| 自启 | mac 侧未实现 | 可选：Run 注册表键 / 启动文件夹（Tauri autostart 插件） |
| 凭证存储 | `OnboardingConfiguration` SecItemAdd → Keychain + `credentials.json` 0600 | `%APPDATA%\Bruce\credentials.json` + Windows ACL 限定当前用户（等价 0600），temp + rename 原子写 |
| 外部 CLI 凭证探测 | `kSecUseAuthenticationUISkip` 静默回退 | 文件读取 + 失败静默跳过原则照搬，禁止交互式弹窗 |

### 4.2 看板功能区（首版全量）

对齐 mac `MenuBarViews`/`Views/` 能力矩阵，WebView 前端实现：今日总量 Hero 卡、Agent 用量卡（模型用量区块、月卡联动、三档语义配色）、逐小时折线、热力图、订阅额度卡（8 Provider）、Nothing 风格控制台主题（Windows 侧以 CSS/点阵等价实现）。菜单栏圆环指示器由托盘图标渲染等价承载（刷新中/告警态图标切换）。

### 4.3 凭证与安全红线

- 订阅凭据统一落盘 `%APPDATA%\Bruce\credentials.json`，目录与文件 ACL 限定当前用户（等价 mac POSIX 0600 语义），temp + rename 原子替换；
- 外部应用 SQLite（opencode/zcode/cc-switch）强制 `mode=ro` 只读连接；
- Claude CLI Windows 凭证位置实测前，`CredentialSource` Windows 实现仅做文件探测 + 静默回退，绝不触发交互式鉴权 UI；
- 严禁向 `core/collector` 引入任何 Windows 专有出站行为。

---

## 5. 总体设计 (High-Level Architecture)

### 5.1 仓库拓扑

```text
apps/
├── macos/          # 现有 SwiftUI 应用（mac 事实源，不动）
├── widget/         # Daimon 小组件（不迁移）
└── win/           # 新增 Tauri 2 应用
    ├── src-tauri/  # Rust 后端
    │   ├── collector-*（workspace 依赖，进程内直调）
    │   ├── viewmodel/（视图模型层，§6.2）
    │   └── shell/（托盘/热键/通知/自启/凭证集成）
    └── src/        # TS + HTML/CSS 看板前端
core/collector/     # 共享采集引擎（唯一真理源）
```

### 5.2 数据流

```text
Windows Tauri 后端 (Rust)
  → collector-application (进程内调度, RuntimeLimits/取消原语复用)
  → collector-local / collector-provider (本地扫描 + 出站额度)
  → artifact (agent-usage-v1, 与 mac 同 schema)
  → viewmodel 层 (Rust, artifact → 看板视图模型)
  → Tauri IPC → WebView 前端渲染
```

与 mac 的唯一结构差异：mac 经 stdio Bridge 拉起 `Bruce-collector` 子进程，Windows 端进程内直调（免子进程，`bin/Bruce-collector` CLI 仍保留用于 P1 阶段独立验收）。

### 5.3 一致性保障机制（对拍）

- mac `BruceAppCore` 与 Windows Rust `viewmodel` 消费**同一组 artifact fixture**（`tests/fixtures/` 既有资产）；
- 对拍协议（golden 快照模式，已落地）：mac 侧 `PanelParityHarness` 将 Swift 视图模型序列化为与 Rust serde 同构的 camelCase JSON，`--update` 刷新 golden 快照（`tests/fixtures/viewmodel-parity/`），默认模式比对；Windows 侧 `mac_parity_golden_matches` 测试消费同一快照，数值按 f64 归一后逐字段断言；
- 双向门禁：mac 端行为变更 → `--update` 刷新 golden 并审视 Windows 侧同步；Windows 侧漂移 → Rust 测试直接红。verify-local.sh 与 verify-windows CI 双侧执行；
- 已知实现约束：serde_json 需开启 `float_roundtrip`（mac JSONEncoder 输出 17 位浮点表示）；数值并列排序以稳定键序破并列，对拍 fixture 避免构造并列场景。

---

## 6. 详细设计 (Detailed Technical Design)

### 6.0 核心业务规则 (Core Rules)
<!-- @topic: WindowsCompat -->

#### 变更演进索引
| 变更编号 | 类型 | 简介 | 规则演进 |
|---|---|---|---|
| 暂无增量变更 | - | 初始基线定稿 | Windows 适配初始设计（Tauri 2 / 首版全量 / Rust 视图模型+对拍） |

#### 现行设计规则
1. **领域模型与数据结构**：视图模型层输入输出均为纯数据结构，序列化即对拍协议；
2. **核心算法与处理流程**：调度/合并/告警判定为纯函数，与 mac `BruceAppCore` 逐模块对齐；
3. **边界与约束**：所有外部探测（凭证/路径/出站额度）失败一律静默降级，禁止交互式 UI 阻塞。

### 6.1 Rust 端改动清单（收敛后）

| # | 改动 | 位置 | 内容 |
|---|---|---|---|
| R1 | 缓存根平台化 | `collector-local/src/lib.rs:157-158` | `#[cfg(windows)]` 返回 `%LOCALAPPDATA%\Bruce\collector-cache-v1`（env 优先，回退 `~/AppData/Local`），mac/Linux 行为不变；补单元测试 |
| R2 | Windows CI job | `.github/workflows/ci.yml` | 新增 `windows-latest` job：`cargo fmt --check` / `cargo test --workspace` / `cargo clippy` |
| R3 | 验证脚本抽取 | `scripts/` | Rust 平台无关部分抽为 `verify-rust.sh`（Windows 侧 PowerShell 等价或 PowerShell 驱动） |
| R4 | 真机路径实测 | 本文档 §3.4 | P0 实测后回填；如有布局差异改 `paths.rs` 对应 resolver 并补测试 |
| R5 | Claude CLI Windows 凭证 | `collector-credential` | 视实测结论：文件回退已覆盖则仅登记；否则实现 Windows `CredentialSource`（文件探测优先，禁止交互） |

### 6.2 Windows 视图模型层（`apps/win/viewmodel/`，独立纯 Rust crate）

对齐 `BruceAppCore` 职责的 Rust 模块划分（消费 artifact，产出看板视图模型）：

| Rust 模块 | 对齐 mac 源 | 职责 |
|---|---|---|
| `usage_mapping` | `UsageMapping.swift` / `PanelViewModelMapper` | artifact → 今日总量/Agent 明细/逐小时/热力图/模型用量视图模型 |
| `subscription_mapping` | `SubscriptionMapping.swift` / `SubscriptionPresentationPolicy` | Provider 额度快照 → 订阅卡展示模型（窗口语义、进度、告警态） |
| `quota_alert_evaluator` | `QuotaAlertEvaluator.swift` / `SystemNotificationDeliveryPolicy` | 配额告警判定与通知去重 |
| `refresh_scheduler` | `RefreshScheduler.swift` / `RefreshBackoffPolicy` / `RefreshExecutionPipeline` | 刷新调度、指数退避、唤醒/前台触发 |
| `ledger` | `DeepSeekUsageLedger.swift` / `CodexQuotaSnapshotMerger` 等 | 账本与快照合并 |
| `settings_model` | 设置中心相关 | 价格校准、卡片排序、主题偏好的加载与持久化 |

对拍测试位于 `apps/win/viewmodel/tests/`（`cargo test`，无需 Tauri/WebView 依赖，双平台 CI 均可执行），fixture 直接引用 `tests/fixtures/` 共享资产；mac 侧在 `verify-local.sh` 中增加对拍 invocation（Swift Harness 输出与 Rust 输出比对）。

### 6.3 Windows 系统集成壳（`apps/win/src-tauri/shell/`）

- **托盘**：Tauri tray icon + 左键弹面板/右键菜单（刷新/设置/退出），图标态（就绪/刷新中/告警）与 mac 圆环语义对齐；
- **面板**：置顶、无任务栏项、失焦隐藏的 WebviewWindow；位置记忆对齐 mac `DashboardPanelPlacement`；
- **热键/通知/自启**：Tauri 官方插件（global-shortcut / notification / autostart）；
- **凭证壳**：`credentials.json` 的 ACL 写入器与 Onboarding 引导流程（Tauri 深链/本地页）。

### 6.4 打包与发布线

- `tauri.conf.json`：产品名 Bruce、identifier 沿用 `com.bruce.dashboard` 系命名；
- 打包：Tauri bundler → NSIS 安装包（+ 可选 MSIX）；`signtool` 签名（测试期可不签）；
- CI：release 阶段增加 Windows 构建矩阵 job，产物 `Bruce_x.y.z_x64-setup.exe` + SHA256；
- 文档：README/`docs/guide/` 补 Windows 数据位置（`%APPDATA%\Bruce`、`%LOCALAPPDATA%\Bruce\collector-cache-v1`）。

---

## 7. 扩展设计 (Additional Technical Design)

### 7.1 实施阶段与任务卡映射

| 阶段 | 内容 | 任务卡 | 验收口径 |
|---|---|---|---|
| P0 | Windows CI + 真机路径实测 | T01 | windows-latest 全绿；§3.4 实测表回填 |
| P1 | 缓存根平台化 + CLI Windows 采集跑通 | T01 | Windows 本机 artifact 与 mac 同 schema 且数值合理 |
| P2 | Tauri 骨架 + 视图模型 + fixture 对拍 + 最小看板 | T02 | 双端 fixture 对拍逐字段一致 |
| P3 | 全功能对齐（订阅额度/通知/热键/设置/Onboarding） | T03 | 功能矩阵逐项勾选 |
| P4 | 打包发布线 | T04 | 安装/升级冒烟 + SHA256 |

### 7.2 风险与预案

| 风险 | 预案 |
|---|---|
| 各 Agent Windows 布局与预期不符 | P0 实测先行，`paths.rs` resolver 按实测回填，env 覆盖机制兜底 |
| WebView2 Runtime 缺失（老 Win10） | 安装包内置 WebView2 Bootstrapper（Tauri 默认行为） |
| 对拍长期维护成本 | fixture 即 mac Harness 既有资产，对拍失败即 CI 红，漂移无处藏身 |
| Claude CLI Windows 凭证形态未知 | R5 按实测结论落地，文件探测优先、静默回退，绝无交互弹窗 |
| ureq/rustls 在企业代理环境行为 | 出站探测失败静默降级为本地扫描口径（与 mac 一致） |

### 7.3 后续演进

- 更新通道：Tauri updater（P4 后可选）；
- Linux：路径表已天然大部分覆盖，视需求另行立项；
- PDH 磁盘度量：`metrics.rs` Windows 分支（可选，非目标）。

---

## 8. 参考资料 (References)

- `core/collector/crates/collector-application/src/paths.rs`：跨平台路径解析（Windows 候选分支实测锚点）
- `core/collector/crates/collector-local/src/lib.rs:157`：`default_cache_root`（唯一待平台化硬编码）
- `core/collector/crates/collector-credential/src/lib.rs:74`：`read_keychain` 平台无关契约
- `apps/macos/Sources/BruceAppCore/`：视图模型/调度/账本的 mac 事实源（Rust 对齐基准）
- `docs/devel/design/00-系统总体设计.md`：Monorepo 分层与 `apps/` + `core/` 拓扑依据
- [变更总账 (WindowsCompat)](../change/index.json#WindowsCompat)
