# mddd · 个人研发数据看板

本机 AI 编程活动的统一监控项目，由三个**互相独立**的模块组成。
每个模块结构相同：`collector/` 采集数据（输出 JSON），`widget/` 渲染界面
（Daimon/Kimi Work Blueprint Widget，单文件 HTML）。

```
mddd/
├── agent-usage/            # 模块一：本机 AI agent 额度与 token 用量
│   ├── collector/collect_usage.py
│   └── widget/index.html
├── github/                 # 模块二：GitHub 贡献日历（个人开源活动）
│   ├── collector/collect_github.py
│   └── widget/index.html
├── gitlab/                 # 模块三：用户配置的私有 GitLab 贡献日历
│   ├── collector/collect_gitlab.py
│   └── widget/index.html
└── docs/
```

---

## 模块一 · agent-usage（AI agent 额度与用量）

一个页面看清每个 agent 今天烧了多少 token、折多少钱，以及各家云服务额度还剩多少。

**用量区（全部来自本机会话日志，零外部依赖）**

- Kimi Work、Kimi Code CLI、Claude Code、Codex CLI、Codex · Orca 的今日消耗
- 14 日分 agent 堆叠柱状图、逐小时折线图、分模型 / 分项目明细
- 按内置价目表（174 个模型，USD / 1M tokens）估算今日成本

**额度区（实时查询）**

| 服务 | 数据来源 | 窗口 |
|---|---|---|
| Kimi | kimi.com 会员接口（本机浏览器令牌，自动刷新） | 5 小时 / 7 天 / 每月 / 赠送额度 / 加量包 |
| DeepSeek | 官方 balance 接口 | 余额（CNY） |
| 火山引擎（Coding Plan） | 火山 OpenAPI（AK/SK 签名） | 5 小时 / 每周 / 每月 |
| Codex（多账号） | OpenAI wham/usage 接口（OAuth 自动轮换写回） | 5 小时 / 每周 |
| Antigravity (agy) | Google Cloud Code 接口（OAuth 自动刷新） | Gemini、Claude/GPT 分组 |

运行：`python3 agent-usage/collector/collect_usage.py [--out 路径]`

## 模块二 · github（GitHub 贡献日历）

- 通过本机 `gh` CLI 的 GraphQL API 拉取 contributionCalendar
- 产出：总贡献数、今日、当前 / 最长连续 streak、最佳单日、53 周日历
- 界面为绿色热力墙（GitHub 风格）
- 依赖：`gh` CLI 已登录

运行：`python3 github/collector/collect_github.py [--out 路径]`

## 模块三 · gitlab（私有 GitLab 贡献日历）

- 实例地址由用户在 App 设置中配置，CLI 使用 `--base-url` 显式传入
- 使用 Events API 分页拉取后按天聚合，产出结构与 GitHub 模块一致
- App 将 PAT 保存到 macOS Keychain；CLI 默认从
  `~/.config/mddd/gitlab.token` 读取，不落仓库
- 请求自带 2 次重试，容忍私有网络 / VPN 的短暂连接抖动
- 界面使用橙色热力墙，与 GitHub 模块区分

运行：`python3 gitlab/collector/collect_gitlab.py --base-url https://gitlab.example.com [--out 路径]`

---

## 统一落盘参数 `--out`

三个 collector 都支持 `--out <路径>`：把结果 JSON **原子写入**指定文件
（先写 `.tmp` 再替换，读取方不会拿到半截文件），缺省则打印到 stdout。
目录不存在会自动创建，适合作为 macOS app / 定时任务的统一数据出口，例如：

```bash
python3 agent-usage/collector/collect_usage.py --out data/agent-usage.json
python3 github/collector/collect_github.py     --out data/github.json
python3 gitlab/collector/collect_gitlab.py     \
  --base-url https://gitlab.example.com --out data/gitlab.json
```

`data/` 目录为运行产物，请勿提交。

---

## 本机数据依赖（除注明外均只读）

| 模块 | 路径 | 用途 |
|---|---|---|
| agent-usage | `~/Library/Application Support/kimi-desktop/.../sessions` | Kimi Work 会话日志 |
| agent-usage | `~/.kimi-code/sessions` | Kimi Code CLI 会话日志 |
| agent-usage | `~/.claude/projects` | Claude Code 会话日志 |
| agent-usage | `~/.codex/sessions`、`~/.codex/auth.json` | Codex 会话与当前账号令牌（轮换写回） |
| agent-usage | `~/Library/Application Support/orca` | Orca 托管的 Codex 会话 |
| agent-usage | `~/.config/kimi-dashboard/kimi-web-tokens.json` | Kimi 网页端令牌（自动刷新写回） |
| agent-usage | `~/.cc-switch/cc-switch.db` | 服务凭证发现 + 价目补充（可选，缺失自动降级） |
| agent-usage | `~/.cc-switch/codex_oauth_auth.json` | Codex 多账号库（轮换写回，留 `.bak-kimi` 备份） |
| agent-usage | `~/.gemini/antigravity-cli/` | agy 的 Google OAuth 与活动计数 |
| github | `gh` CLI 登录态 | GraphQL 查询 |
| gitlab | App Keychain 或 `~/.config/mddd/gitlab.token` | GitLab PAT |

## 设计规范

- 视觉：Claude 官网书卷风——米白底 `#f7f5ee`、陶土橙 `#d97757` 强调色
- 字体：英文 Times New Roman，中文宋体（同一衬线栈）
- 图表：纯静态展示，无悬停高亮；额度用量统一量条（≥60% 橙、≥85% 红）
- 热力墙配色：GitHub 绿 / GitLab 橙，两个模块一眼区分

## 注意

- 仓库内不含任何令牌 / 凭证，请勿把上述本机配置文件提交进来
- 采集脚本仅兼容 macOS 目录结构
