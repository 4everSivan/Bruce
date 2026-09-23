# AGENTS.md

<!-- @ad-flow: initialized -->
> Bruce 研发与 AI 协作规范 —— 适用于团队开发者与 AI Agent 的统一工程底线。

---

## 一、代码风格与编写规范 (Code Style & Quality)

1. **语言标准与类型契约**：严格遵循所用技术栈的官方推荐规范（Rust 严格通过 `clippy` 与 `rustfmt`；Swift 遵循 Swift 6 并发安全与严格类型检查）；关键业务对象与公共函数必须提供完整严密的类型定义与前置防御断言。
2. **单一职责与模块解耦**：业务逻辑与外部 I/O（数据库、网络请求、文件系统）必须清晰分层；Collector 负责纯数据采集与度量聚合，App 负责原生渲染与调度交互，严禁在模块初始化阶段执行隐式网络请求或副作用。
3. **命名与注释规范**：变量与函数命名精准表达业务意图；核心算法、业务规则分支、非显而易见的边界防御必须附带精确代码注释，杜绝无意义的废话注释。
4. **依赖引入克制**：严禁未经讨论擅自引入体积庞大或维护度低下的重型外部三方库；优先利用语言标准库、轻量专用 crate 或 Swift 官方模块。

---

## 二、开发流程 (Development Workflow)

日常研发分为两大入口，共同遵守“文档先行 → 编码 → 补测 → 人工核验代签 → 基线回写”的闭环，不跨步、不省略：

### 1. 功能设计入口 (新功能 / 大需求 / 阶段里程碑)
1. **方向登记**：在 `docs/devel/todo/` 登记方向级灵感与事项；
2. **设计基线定稿**：在 `docs/devel/design/` 撰写或修订对应微设计文档（`01~99-[功能名].md`），状态置为 `现行基线`，并标明概念主题锚标 `<!-- @topic: TopicName -->`；完成设计后从 `todo/` 移除对应项；
3. **任务拆解**：在 `docs/devel/task/` 建立 `Txx.json` 任务卡（声明 DAG 依赖 `depends_on` 与 DoD 完成定义），并在 `task/index.json` 总账登记；
4. **顺序开发**：按依赖拓扑顺序编码与实现；
5. **测试与验收**：跑通测试，验收通过后在 `task/index.json` 中闭环，阶段发版时执行归档。

### 2. Bug 修复入口 (缺陷 / 功能回调 / 参数微调 / 重构)
1. **登记并移出 (零沉淀)**：在 `docs/devel/todo/now.md` 登记；一旦在 `docs/devel/change/` 新建 `Cxxx.json` 变更卡并在 `change/index.json` 登记后，**必须立即从 todo 表格中物理删除该项**（落地即删除）；
2. **条件契约与对比表**：卡内定义前后逻辑对比，以及 `true_if`（通过依据）与 `false_if`（失败依据）；
3. **改代码 + 补测试**：修复问题并补充对应的回归测试；
4. **核验与代签**：AI 运行测试采集真实证据并在会话中向人类汇报；人工口头确认后，AI 代为在卡内签署收口（记录人类原话），卡状态转为 `verified`；
5. **基线回写与闭环**：合入主干，若涉及设计规则变动则同步反哺回写对应微设计文档正文，更新 `CHANGELOG.md`，并在 `change/index.json` 中标记 `closed`。

---

## 三、本地部署与环境隔离 (Local Deployment & Environment)

1. **严格依据部署文档**：本地环境准备与服务部署，**必须严格遵循 `docs/guide/` 下的部署文档**（如 `docs/guide/01-本地部署指南.md`）进行操作，严禁随意臆测启动参数。
2. **产物全量收拢至 `local/`**：部署与测试运行产生的所有临时文件、本地数据库、缓存、日志等，**一律写入项目根目录的 `local/` 目录**（已加入 `.gitignore`），严禁向源码树扩散污染。
3. **部署必须产出实况报告**：部署执行完毕后，**必须在 `local/` 目录下产出一份部署实况报告（`local/deploy_report.md`）**，明确记录真实分配的端口、实际数据库路径、进程管理与重启命令、健康检查端点及日志位置。
4. **测试与重新部署的事实依据**：**后续所有的自动化测试、联调验证、日常重启与重新部署，必须参考 `local/deploy_report.md` 实际运行数据执行，严禁抛开报告重新翻阅部署指南**（防止端口冲突、配置漂移或覆盖正在运行的实例）。
5. **重新部署与报告刷新**：若环境配置、启动参数发生变动，或执行了重新部署，必须同步更新 `local/deploy_report.md`；若部署架构基线变动，同步修订 `docs/guide/` 对应文档。
6. **【严格红线】`local/` 仅人工清理**：**AI Agent 严禁擅自删除或重置 `local/` 目录**！所有本地数据库、部署报告与调试环境的清理权 100% 归人类开发者所有，防止运行实况与调试数据被意外销毁。

---

## 四、测试规范 (Testing Standards)

1. **测试文件归拢**：所有测试用例原则上统一存放在模块的 `tests/` 目录或原生 Harness 测试目标中。
2. **改动必伴随补测**：任何功能实现、接口微调或 Bug 修复，**必须同步补充或更新对应的自动化测试用例**，严禁裸跑无测代码。
3. **测试独立与全绿通过**：测试必须具备独立幂等性，不依赖不可控的外部真实外网服务（外部依赖必须 Mock）；提交或合入前所有相关测试必须全绿通过。

---

## 五、分支与提交规范 (Git Branching & Commit Conventions)

1. **多分支隔离与卡片标签**：
   * 为适配多分支并行开发，新特性开发必须创建专属特性分支（如 `feat/<Txx-简述>`），Bug 修复与微调必须创建专属修复分支（如 `fix/<Cxxx-简述>`）；
   * 对应任务卡（`Txx.json`）与变更卡（`Cxxx.json`）中**必须显式登记执行分支（`"branch": "..."`）**，以便人机随时对齐当前研发上下文；
   * 严禁在未经建卡或分支未对齐的情况下向主干随意提交混合代码。
2. **语义化提交格式**：采用 Conventional Commits 规范，格式为 `<type>(<scope>): <subject>`：
   * `feat`: 新增业务功能
   * `fix`: 修复缺陷
   * `docs`: 文档、设计方案或注释变动
   * `test`: 新增或修订测试用例
   * `refactor`: 代码重构（不影响业务功能的结构调整）
   * `chore`: 构建配置、依赖更新或辅助工具变动
3. **原子性提交**：每次提交保持单一职责，严禁将不同模块的不相干改动或大范围重构混在同一个 commit 中。
4. **关联卡号**：涉及具体 C 卡或 T 卡的改动，提交标题或说明中建议附带卡号（如 `(C001)` 或 `(T02)`），以便追溯。

---

## 六、发布与归档检查 (Release & Documentation Hygiene)

1. **统一发版版本号**：全局严格遵循单一 SemVer 版本号（`vX.Y.Z`），Markdown 文档仅标注最后更新日期，不单独搞孤立的文档小版本号。
2. **CHANGELOG 记账**：发版前必须在 `CHANGELOG.md` 汇总本版本的所有新增特性、修复与破坏性变动。
3. **全景文档核对**：检查 `docs/README.md` 与各目录 README 是否有陈旧失真的描述，保持文档与现实一致。
4. **发版归档 SOP**：发版封箱时，将本版本完成的卡片统一移入 `docs/archive/<版本号>/`，刷新 `index.json` 中的物理路径映射，并打出对应 Git Tag（如 `git tag -a v0.1.0 -m "Release v0.1.0"`）。

---

## 七、安全与防泄漏红线 (Security & Secrets)

1. **敏感凭证绝不上库**：API Key、Secret、私钥、Token、数据库真实密码与内网敏感拓扑，**一律禁止硬编码入代码或提交 Git**；必须使用 `.env` 或配置注入，且 `.env` 必须加入 `.gitignore`。
2. **数据安全快照隔离保护**：若项目根目录存在 `_adflow_backup/`，**AI Agent 严禁擅自删除或篡改**。该备份为人类安全底线资产，仅允许人类在终端手动核验清理。

---

## 八、AI 真实性与核验纪律 (Truthfulness & Evidence)

1. **运行结果必呈事实**：执行自动化测试或编译构建时，AI 必须向人类客观汇报真实命令输出、失败详情与退出码（Exit Code），**严禁在有警告/报错时用“已全部通过”含糊概括**。
2. **签署代签必有依据**：卡片内的收口代签，必须在会话中收到人类明确确认后才可执行，并将人类原话写入 `user_quote`，严禁 AI 自导自演代签。

---

## 项目自定义规则 (Project Custom Rules)

> 本节包含 Bruce 项目特有的架构拓扑、关键路径、验证脚本与环境能力约定：

### 1. 项目核心事实与架构定位

- `Bruce` 运行在 macOS 菜单栏场景中，核心能力是统一监控与分析本机各类 AI Agent 的 Token 用量、费用估算和订阅额度。
- **架构解耦分工**：
  - **Rust Collector** (`rust/Bruce-collector/`)：高性能本地数据采集边界，负责扫描本机 Agent 会话目录、增量缓存计算、聚合 Token/费用，并对外出站查询服务额度。输出标准 JSON artifact；
  - **macOS App** (`macos/BruceApp/`)：原生 SwiftUI 菜单栏常驻应用，支持经典与液态玻璃主题，负责调度刷新、图表与状态指示呈现，具备 Universal 2（Apple Silicon + Intel Mac）通用兼容性；
  - **本地优先运行**：项目无自有云端服务端，所有数据在用户本机闭环。

### 2. 目录与关键路径约定

| 目录/文件 | 核心职责 |
|---|---|
| `rust/Bruce-collector/` | Rust Collector workspace（含 `collector-application`, `collector-local`, `collector-domain`, `collector-provider`, `collector-aggregate` 等 crates） |
| `macos/BruceApp/` | 原生 macOS SwiftPM 模块（`BruceApp`, `BruceAppCore`, `BruceOnboardingCore`, `BruceGlassSurfaceCore` 以及各测试 Harness） |
| `docs/` | `ad-flow` 标准文档中心（`docs/devel/` 现行设计与卡池、`docs/guide/` 部署指南、`docs/assets/` 静态图片与截图） |
| `scripts/` | 验证与打包核心脚本（`verify-local.sh`, `build-test-app.sh`, `check-collector-fixtures.sh`, `release-notes.sh`） |
| `dist/` | 仅作为本地 Release/Preview 打包构建产物目录，严格加入 `.gitignore` |

### 3. 标准验证与打包命令

| 命令 | 用途 |
|---|---|
| `zsh scripts/verify-local.sh` | **标准本地全量验证**：Rust fmt / test / clippy + JSON fixture 语法与敏感扫描 + Swift build + 全部 9 项 Harness 测试 |
| `cargo test --manifest-path rust/Bruce-collector/Cargo.toml --workspace` | Rust Collector 单元与集成测试 |
| `zsh scripts/check-collector-fixtures.sh` | 测试 fixture 语法校验与敏感凭证扫描 |
| `swift run --package-path macos/BruceApp BruceOnboardingCoreHarness` | Onboarding Core 核心凭证、存储与门控边界测试（165 项） |
| `zsh scripts/build-test-app.sh --universal --install` | 构建 Universal 2 双架构 App 并安装至 `/Applications/Bruce.app` |

### 4. 数据安全与凭据管理规范

- **应用凭据存储隔离**：应用内存储的订阅凭据统一落盘至 `~/Library/Application Support/Bruce/credentials.json`，权限强制限制为 **POSIX `0600`**（仅当前操作系统用户可读写，父目录 `0700`），采用临时文件 + `replaceItemAt` 原子写入，彻底杜绝本地构建由于签名哈希变动引发的系统钥匙串密码弹窗。
- **外部 CLI 读取静默防护**：探测 Claude CLI 等外部凭据时，必须附加 `kSecUseAuthenticationUISkip` 属性；遇需要鉴权交互时直接静默跳过并优雅回退至本地文件，严禁引发侵入式系统弹窗。
- **外部数据库只读访问**：读取外部应用 SQLite 数据库时强制使用 `mode=ro` 只读连接，严禁向外部数据库执行 DDL、写入或修复操作。

### 5. 已确认环境协作能力

- **代码语义探索先用 Semble**：定位实现、查找调用关系或理解代码结构时，优先调用 `semble` MCP 语义搜索，获取精确行号与文件后再按需读取，避免在整个仓库盲目 grep。
- **大上下文优先使用 Headroom**：大文件 diff、长日志或多文件探索进入推理前，优先使用 Headroom 进行保真压缩与结构化提取。
- **第三方库查阅 Context7**：涉及外部 SDK、云服务或系统框架变更时，优先使用 Context7 查询官方实时文档。
