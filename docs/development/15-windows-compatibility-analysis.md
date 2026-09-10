# Bruce Windows 兼容性分析

> 版本: 0.1 (提案, 待确认)
> 日期: 2026-09-01
> 适用范围: 评估 Bruce 在 Windows 上提供同等能力 (菜单栏/托盘看板 + Collector 采集) 所需的全部改动, 细化到具体文件与代码位置
> 状态: **仅分析, 未实施**。确认本文档后才进入实施。

---

## 1. 结论

**"移除液态玻璃"远不足以兼容 Windows。** 液态玻璃只是 18 处 `#available(macOS 26)` 门控 (源: `GlassTheme.swift` 等), 且已有经典主题回退, 属于整个平台依赖面里最小的一块。真实依赖面:

| 层 | 结论 | 规模 |
|---|---|---|
| Rust Collector (7 crates) | **保留, 中等改动**: 路径表 + Keychain 读取 + 缓存目录 | ~5 个文件 |
| Bridge 协议与 artifact schema | **零改动** | 0 |
| Swift Core 逻辑层 (29 文件) | 1 个文件有 AppKit 依赖, 其余纯 Foundation | 随 UI 策略二选一 |
| Swift UI 层 (13 AppKit 文件 + 26 SwiftUI 视图) | **整体重写**, 无一可复用 | 整个产品前端 |
| 凭证/热键/通知/唤醒 系统集成 | **全部重写** | 4 个子系统 |
| 打包与 CI | **新增 Windows 产物线** | 脚本 + workflow |
| Daimon Widget | Windows 无对应宿主, **不迁移** | 0 |

估算: 相当于重做产品前端 + 半个采集端移植。核心资产 (数据契约, 聚合算法, 缓存设计, 测试规格) 全部可复用。

---

## 2. Rust Collector: 保留 + 改动清单

### 2.1 会话源路径表 (collector-application/src/lib.rs:380-421)

`collect_local` 内硬编码 mac 路径。需要抽出平台路径表:

| 源 | 现路径 (mac) | Windows 处置 |
|---|---|---|
| claude_projects | `~/.claude/projects` | 保留 `~/.claude/projects` (Claude Code Windows 同布局, 待实测确认) |
| codex_sessions | `~/.codex/sessions` | 同上待实测 |
| grok_home | `~/.grok` | 待实测 |
| kimi_code | `~/.kimi-code/sessions` (lib.rs:603) | 待实测 |
| pi_sessions | `~/.pi/agent/sessions` | 待实测 |
| opencode_db | `~/.local/share/opencode/opencode.db` | Windows 版 opencode 布局待实测 |
| zcode_db | `~/.zcode/cli/db/db.sqlite` | 待实测 |
| kimi-work | `~/Library/Application Support/kimi-desktop/...` (lib.rs:385) | **Windows 无此应用, 直接禁用该源** |
| orca (codex-runtime/codex-accounts) | `~/Library/Application Support/orca/...` (lib.rs:393-404) | **同上禁用** |

实现方式: 在 `collector-application` 增加 `SourcePaths` 构造 (按 `cfg!(windows)` 或运行时探测二选一, 建议运行时探测 + `cfg` 默认值), 保持 `source_path(context, key, default)` 注入口不变 (lib.rs:381 已有 context 覆盖机制, Windows 可先靠 context 注入路径验证, 再固化默认表)。

### 2.2 凭证读取 (collector-credential/src/lib.rs)

- `lib.rs:86,104`: Claude CLI 凭证走 `/usr/bin/security` 子进程读 macOS Keychain → Windows 替换: Claude Code Windows 版的存储位置**待实测** (预期 `%USERPROFILE%\.claude\.credentials.json` 或 Windows Credential Manager); 实现 `CredentialSource` 的 Windows 分支 (Win32 `CredRead` 或 `keyring` crate)。
- Grok `~/.grok/auth.json`、Codex `~/.codex/auth.json`: 纯文件, 路径随 2.1。
- 订阅凭证注入 (`kimi_web_tokens` / `provider_env` 等): App 模式经 Bridge stdin 注入, **平台无关, 零改动**; 仅 CLI 模式的 CC Switch SQLite 路径 (`~/Library/Application Support/cc-switch/...`) 需 Windows 定位或禁用。

### 2.3 缓存目录 (collector-local/src/lib.rs:156-158)

`default_cache_root` = `~/Library/Application Support/Bruce/collector-cache-v1` → Windows 改为 `%LOCALAPPDATA%\Bruce\collector-cache-v1` (`dirs` crate 或手写 `env::var("LOCALAPPDATA")`)。缓存格式 (`CompactContribution`) 平台无关。

### 2.4 平台度量 (collector-bridge/src/metrics.rs:9-31)

已有 `#[cfg(target_os)]` 骨架, 非 macOS 返回 `None` — **无需改动**; 可选后续接 Windows PDH 磁盘计数。

### 2.5 构建与测试

- `cargo build --target x86_64-pc-windows-msvc` / `x86_64-pc-windows-gnu`: 依赖 (rusqlite bundled, ureq rustls, chrono-tz) 均可交叉编译; 先在 CI 加 `windows-latest` job 跑 `cargo test --workspace` 验证。
- `scripts/collector-release-smoke.sh` 为 mac shell, Windows 需 PowerShell 等价物或先跳过。

### 2.6 明确不做

- Widget (`agent-usage/widget/`): Daimon 宿主 macOS 独有。
- Kimi-work / Orca 源: Windows 无对应应用。

---

## 3. Swift 层: 二选一策略 (需决策)

### 3.1 现状盘点

- **AppKit 深度绑定的 13 个文件** (`Sources/BruceApp/`): `ApplicationBootstrap` / `ApplicationLifecycle` / `BruceApp` / `DashboardGlassPanelController` (NSGlassEffectView) / `GlassTheme` / `GlobalHotkeyMonitor`+`Recorder` (Carbon) / `MenuBarStatusItemController` (NSStatusItem+NSPanel) / `MenuBarViews` / `QuotaAlertNotifier` (UNUserNotifications) / `SettingsView` / `SubscriptionService`。
- **SwiftUI 视图 26 个** (`Views/` 等): 按 macOS 控件规范编写 (NothingFont, NSGlass 适配, AppKit 面板生命周期), 无直接对应物。
- **Core 逻辑 30 个文件** (`Sources/BruceAppCore/`): 仅 `RefreshScheduler.swift:1` `import AppKit` (用途: `NSWorkspace.didWake` 唤醒监听, RefreshScheduler.swift:174-175); 其余 (AppModel, PanelViewModelMapper, ArtifactStore, DeepSeekUsageLedger, 调度/退避/合并器) 纯 Foundation。
- **OnboardingCore**: `OnboardingConfiguration.swift` 含 `SecItemAdd` 系 Keychain 写入 (全项目唯一写入方)。

### 3.2 策略 A · 原生重写 UI, Core 移植到 Rust (推荐)

- UI 框架候选 (按推荐序):
  1. **Tauri 2** (Rust + WebView): 复用现有 Rust collector 与 HTML/CSS 技能栈, 托盘/全局热键/自启/通知有现成插件, 包体小;
  2. **WinUI 3** (C#): 最原生观感, 代价是引入 C# 双语言栈;
  3. **Avalonia** (C#): 跨平台备用。
- Core 逻辑处置: `BruceAppCore` 的映射/调度/账本逻辑**下沉 Rust** (新建 `collector-uimodel` crate, artifact → UI 视图模型直接在 Rust 端产出), Swift 版保留为 mac 事实源, 双端由同一组 artifact fixture 对拍测试锁一致。
- 工作量: 大 (前端全量重做), 但换来单一 Rust 核心双平台。

### 3.3 策略 B · 本地服务 + 浏览器看板 (低成本替代)

- Collector 增加本地 HTTP server (127.0.0.1), 看板用现有 widget 的 HTML 渲染。
- 避开托盘/热键/通知全部原生集成; 用户体验从"菜单栏常驻"降级为"浏览器标签页"。
- 工作量小; 适合先验证 Windows 采集链路, 后续再补原生壳。

### 3.4 系统集成映射表 (两策略通用)

| 能力 | mac 实现 | Windows 对应 |
|---|---|---|
| 菜单栏常驻 | `MenuBarStatusItemController` NSStatusItem | 系统托盘 `Shell_NotifyIcon` / Tauri tray |
| 弹出面板 | NSPanel + `DashboardGlassPanelController` NSGlassEffectView | Win11 Mica/Acrylic 或普通置顶无边框窗 |
| 液态玻璃 | `GlassTheme` 18 处 macOS 26 门控 | **不移植**, 恒走经典分支 |
| 全局热键 | `GlobalHotkeyMonitor` Carbon RegisterEventHotKey | `RegisterHotKey` Win32 / Tauri global-shortcut |
| 唤醒补采 | `RefreshScheduler.swift:174` NSWorkspace.didWake | `WM_POWERBROADCAST` / Tauric power 插件 |
| 配额通知 | `QuotaAlertNotifier` UNUserNotificationCenter | Windows AppNotification (Toast) |
| 凭证存储 | `OnboardingConfiguration` SecItemAdd, service `com.bruce.dashboard.credentials` | Windows Credential Manager (DPAPI) 同 service 命名 |
| 自启 | (未实现, mac 无) | 可选: Run 注册表键 |

---

## 4. 打包 / CI / 文档

- `scripts/build-test-app.sh:21,88-95` (codesign/plutil/LSUIElement/ditto): Windows 产物线另建 `build-test-app.ps1`: cargo build (release) → UI 打包 (Tauri bundler / MSIX / wix) → `signtool` (测试期可 signtool /skipcertcheck 或不签)。
- `.github/workflows/ci.yml` (现 4 个 job 全 `macos-26`): 增加 `windows-latest` job 跑 Rust workspace 测试 + Windows 冒烟 (阶段 1 就可加, 与 UI 无关)。
- `scripts/verify-local.sh`: 平台无关部分 (Rust fmt/test/clippy, fixture scan) 抽成 `verify-rust.sh` 供双平台复用。
- README/AGENTS.md: 数据位置章节补 Windows 路径 (`%APPDATA%\Bruce`, `%LOCALAPPDATA%\Bruce\collector-cache-v1`)。

---

## 5. 分阶段实施 (每阶段可独立验收)

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 可行性 | CI 加 windows-latest 跑 Rust 测试; 实测 7 个 agent 在 Windows 的数据布局与 Claude/Grok 凭证位置 | Rust 测试绿; 路径实测表回填本文档 |
| P1 Rust Windows 化 | 2.1 路径表, 2.2 凭证分支, 2.3 缓存目录; `--local-preview` CLI 在 Windows 跑通真实采集 | Windows 上 artifact 与 mac 同 schema 且数值合理 |
| P2 UI 选型原型 | 按策略 A/B 出最小看板 (今日总量 + 用量卡), 接 Bridge 协议 | 双端 artifact fixture 对拍一致 |
| P3 完整功能 | 订阅卡/逐小时/热力图/模型用量/通知/热键/自启逐项对齐 mac 功能矩阵 | 功能矩阵勾选 |
| P4 打包发布 | Windows 安装包 + 签名 + 更新通道 (可后置) | 安装/升级/回滚冒烟 |

---

## 6. 待用户决策的点

1. **UI 策略**: A 原生重写 (Tauri/WinUI3/Avalonia, 选框架) vs B 浏览器看板先行?
2. **首版 provider 范围**: Windows 首版是否先只做本地会话扫描 (订阅额度链路凭证全在 Keychain, 迁移成本另计)?
3. **Core 下沉 Rust** (策略 A 的一部分) 是否接受双端对拍测试的长期维护成本?
4. kimi-work / orca 源在 Windows 直接禁用是否可接受?
