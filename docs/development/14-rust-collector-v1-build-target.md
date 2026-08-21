# Bruce 1.0 Rust Collector 构建目标

> 版本目标: `1.0.0`
> 文档日期: 2026-08-21
> 状态: 目标已确认, 本文只定义构建目标与验收口径, 不代表 Rust 迁移已经实施
> 适用范围: `agent-usage/collector/`、`bridge/`、macOS `CollectorRunner`、测试、CI 与正式打包

## 1. 目标声明

Bruce `1.0.0` 正式版的采集运行时以 Rust 原生 Collector 为唯一生产实现. App 继续通过进程输入输出运行采集器, 但正式 `.app` 不再依赖 Python 解释器、Python 源码或用户本机 Python 路径.

本目标的核心不是改变仪表盘布局、统计口径或 Provider 功能, 而是把采集链路的实现从 Python 迁移为一个可签名、可审计、可复现构建的 macOS 原生 Rust 二进制.

`1.0.0` 必须同时满足以下三个不变性:

1. **展示不变**: 不修改当前菜单栏面板的布局、卡片内容、液态玻璃主题和按钮交互.
2. **数据不变**: 不改变现有 token、成本、额度、热力图和订阅统计的计算口径.
3. **协议不变**: 保持 Bridge v1 request/response、artifact schema、状态、诊断和凭证更新语义兼容.

## 2. 当前基线与迁移范围

当前生产采集链路为:

```text
Swift CollectorRunner
        ↓
Python bridge/run_bridge.py
        ↓
collect_usage.py + RunContext
        ├─ local_usage.py: JSONL / SQLite 扫描
        ├─ service_catalog.py: Provider 目录与统一状态
        ├─ quota_services.py: Kimi / DeepSeek / 火山 / Zhipu
        ├─ quota_official.py: Claude / Grok / OpenCode Go
        └─ Codex / Antigravity / OAuth / Keychain 兼容逻辑
        ↓
artifact JSON → Swift PanelViewModel → 仪表盘
```

当前规模基线:

| 区域 | 代码量 | 迁移含义 |
|---|---:|---|
| `agent-usage/collector/*.py` | 4,048 行 | 本地扫描、聚合、额度和运行时上下文 |
| `bridge/run_bridge.py` + `bridge/security.py` | 1,077 行 | Bridge v1、输入校验、脱敏和凭证更新 |
| `CollectorRunner.swift` | 636 行 | 子进程、stdin/stdout、超时、取消和诊断 |
| Python 测试 | 约 246 项 | 现有行为、fixture 和安全契约 |

因此, 这是一次中大型工程迁移, 不是逐文件翻译. 最大工作量在行为兼容和测试重建, 而不是 Rust 语法本身.

## 3. 1.0 目标架构

### 3.1 运行方式

正式版采用 Rust 独立进程, 通过 stdin/stdout 继续实现 Bridge v1. 不采用 Swift 与 Rust 复杂对象的双向 FFI, 避免把生命周期、错误和版本耦合扩散到 UI 层.

```text
Swift CollectorRunner
        ↓ JSON stdin
Rust Bruce-collector (signed universal binary)
        ├─ collector-domain: RunInput / Artifact / 状态 / 错误
        ├─ collector-local: JSONL / SQLite reader adapters
        ├─ collector-aggregate: token / cost / day / model 聚合
        ├─ collector-provider: quota / OAuth / refresh adapters
        └─ collector-bridge: Bridge v1 校验、脱敏、输出 envelope
        ↓ JSON stdout
Swift PanelViewModel
```

Bridge v1 是迁移期间唯一必须稳定的 seam. Swift 只关心协议和诊断, 不直接依赖 Rust 内部 module.

### 3.2 计划目录

Rust 实现统一放在 `rust/Bruce-collector/`, 采用单 Cargo workspace:

```text
rust/Bruce-collector/
├─ Cargo.toml
├─ crates/
│  ├─ collector-domain/       # 版本化输入、artifact、状态和错误类型
│  ├─ collector-local/        # JSONL / SQLite 读取 adapter
│  ├─ collector-aggregate/    # token、成本、日期、模型和项目聚合
│  ├─ collector-provider/     # Provider 接口及各 Provider implementation
│  ├─ collector-credential/   # Keychain、文件回退、refresh/update 适配
│  └─ collector-bridge/       # Bridge v1、安全校验、脱敏和 stdout envelope
└─ bin/Bruce-collector/        # macOS arm64/x86_64 入口
```

各 module 必须通过窄 interface 连接. Provider 只能通过 credential 和 HTTP adapter 访问外部能力, 聚合器不得直接读取 Keychain 或发起网络请求.

## 4. 迁移分层与实施顺序

### 4.1 契约冻结

先把当前 Python 的 request、artifact、diagnostics、status、service 顺序、失败 note、`credentialUpdates` 和 `credentialChallenges` 固化为 golden fixtures.

验收重点:

- 同一输入产生相同字段和值.
- 缺失、过期、刷新失败和部分成功的状态保持一致.
- 账号排序、日期时区、窗口名称和数值精度保持一致.
- 任何 token、refresh token、Keychain 值都不会进入 stdout、artifact 或测试报告.

### 4.2 Rust 纯逻辑深度

先迁移无网络、无凭证副作用的实现:

- JSONL reader 和坏行容错.
- SQLite 只读 reader 和 schema 诊断.
- token/cost/day/model/project 聚合.
- artifact 序列化和版本校验.
- 时间、时区、日期窗口和用量热力图数据.

这一步完成后, Rust 可以对 fixture 运行并与 Python 输出逐项比较, 但不替换生产 App.

### 4.3 Provider adapter 迁移

按风险从低到高迁移:

1. 只读额度查询.
2. HTTP 签名和窗口解析.
3. OAuth 文件/Keychain 读取.
4. access token 刷新和 `credentialUpdates` 写回.
5. 设备码登录、challenge 和 provider 特有协议.

每个 Provider 必须保留自己的 adapter 和 fixture, 不允许把认证分支重新堆回一个 God module.

### 4.4 App 与打包切换

- `CollectorRunner` 增加 Rust binary 路径解析, 保留现有超时、取消、stdout 清洗和 runId 语义.
- Preview 构建允许 Rust/Python 双实现和显式 fallback.
- Release 构建只复制签名后的 Rust universal binary, 不复制 Python runtime、collector 源码或 `bridge/`.
- `scripts/runtime-manifest.zsh`、Preview/Release 脚本和 CI 都使用同一份 Rust 产物清单.

## 5. 1.0 正式版验收标准

### 5.1 功能与数据

- [ ] 现有 Agent 扫描范围保持一致: Kimi、Claude、Codex、Grok、OpenCode、Pi、ZCode 等.
- [ ] 现有订阅和额度 Provider 的字段、窗口、状态和失败语义保持一致.
- [ ] Codex 额度刷新、账号合并、上次成功时间和 stale/unavailable 语义保持一致.
- [ ] 仪表盘、菜单栏展示、设置页和液态玻璃样式无布局差异.
- [ ] 14 天和 182 天采集窗口、热力图、柱状图和成本聚合通过 parity fixture.

### 5.2 安全与副作用

- [ ] 正式二进制不接受命令行 token 或密码参数.
- [ ] 凭证只从已批准的 stdin 输入、Keychain 或本机文件读取.
- [ ] 只有明确授权的 refresh 才能产生凭证写回.
- [ ] stdout 只输出 Bridge v1 envelope; 诊断写入受控 stderr/diagnostics.
- [ ] 请求、响应、artifact、日志和构建产物完成敏感字段扫描.
- [ ] 读取 CC Switch、Agent 数据库时继续使用只读连接, 不执行迁移或修复.

### 5.3 工程与测试

- [ ] Rust 单元测试覆盖 domain、时间、聚合、reader 和每个 provider adapter.
- [ ] Python golden fixture 与 Rust 输出逐字段比较, 差异必须有版本化说明.
- [ ] Swift Harness 覆盖进程参数、stdin 凭证、stdout/stderr 清洗、超时、取消、重复运行和诊断.
- [ ] `python3 -m pytest tests/`、Rust workspace tests、`zsh scripts/verify-local.sh` 全部通过.
- [ ] 完成冷启动、14/182 天扫描、峰值内存、额度尾延迟和 App 包体基准, 记录到发布归档.

### 5.4 正式打包与回滚

- [ ] Rust arm64 与 x86_64 产物合并并验证架构.
- [ ] Release App 使用正式 bundle ID、Developer ID、Hardened Runtime 和 Apple notarization.
- [ ] `codesign --verify`、`spctl --assess`、`stapler validate` 通过.
- [ ] 首次安装、升级、降级、Keychain 读取、本地缓存读取和卸载行为通过人工验收.
- [ ] 1.0 发布包中不存在 Python 源码、测试 fixture、`data/*.json`、OAuth 数据或私钥.
- [ ] 发布失败时可回退到上一正式版本; Preview fallback 不作为公开生产路径.

## 6. 版本与兼容策略

### 6.1 版本定义

```text
产品版本: 1.0.0
Collector protocol: Bridge v1
Artifact schema: v1
Rust binary: Bruce-collector 1.0.x
```

Rust 内部版本可以独立迭代, 但不得在 `1.0.x` 中无理由改变 artifact 字段或状态语义. 需要破坏性变化时, 新增 schema/version 并保留旧读取路径.

### 6.2 过渡发布

迁移期间允许 Preview 同时携带 Python 和 Rust 实现, 并支持:

- 显式选择实现.
- 同一请求双跑但只展示主实现结果.
- artifact parity 差异写入脱敏诊断.
- Rust 失败自动回退 Python, 不覆盖成功的旧快照.

正式 `1.0.0` 退出过渡期后, 生产包删除 Python fallback. 若发现严重回归, 通过发布 `1.0.1` 修复, 不在用户机器上动态下载或替换采集器.

## 7. 不纳入 1.0 的内容

- 不重做仪表盘布局、卡片内容、颜色和液态玻璃视觉.
- 不新增 Agent、Provider 或趋势图功能.
- 不把 Swift UI 改成 Rust UI.
- 不引入服务端数据库或远程同步.
- 不为了迁移而改变额度刷新周期、授权方式和用户可见措辞.
- 不在第一阶段重写安全层和所有 OAuth; 这些属于 parity 通过后的独立迁移阶段.

## 8. 完成判定

只有同时满足以下条件, 才能把构建标记为 `1.0.0`:

1. Rust Collector 已成为 Release 唯一生产实现.
2. Bridge v1 与 artifact v1 通过完整 parity fixture.
3. 所有现有 Swift/Python/Rust 测试和正式打包检查通过.
4. 认证、凭证写回和失败回退完成授权人工验收.
5. 签名、公证、安装升级、回滚和敏感信息扫描全部有可追溯记录.
6. 仪表盘布局、内容和统计流程保持不变.

在上述条件全部满足前, 构建只能称为 Preview 或 migration candidate, 不得称为 Bruce `1.0.0` 正式版.

## 9. 关联文档

- [Bruce 设计文档](01-bruce-design.md)
- [架构收尾与流程修复设计](09-architecture-remediation-design.md)
- [正式版打包与发布流程](08-production-packaging-and-release.md)
- [发布人工验收清单](05-release-acceptance.md)
- [工具链基线](03-toolchain.md)
