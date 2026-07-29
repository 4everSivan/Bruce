<!-- source: template/tool-entry/gemini -->
# Gemini CLI

@constitution.md
@AGENTS.md

本文件只描述 Gemini CLI 工具自身的专属能力与行为. 跨工具共享工作模式见 `AGENTS.md` 的 AI 协作指令; 工程原则见 `constitution.md`, 项目事实与协作约定见 `AGENTS.md`.

---

## 1. 会话管理

- **新会话隔离**: 大型独立任务建议开启新会话, 避免上下文污染.
- **上下文长度**: 接近上下文上限时主动总结关键事实并建议新会话.

---

## 2. 专属能力

- **Shell 工具**: 执行命令前确认工作目录和影响范围; 高危操作需显式确认.
- **文件编辑**: 优先使用结构化编辑; 大范围修改采用可审查的批量方式.
- **网络搜索**: 涉及最新版本, 安全漏洞, API 变更时主动使用 Search 验证.

---

## 3. 已确认环境能力

本项目确认的 MCP、skills 与 workflow capabilities, 以及 Skill 索引, 均以 `AGENTS.md` 的"已确认环境能力"为唯一来源; 本文件不重复定义. 未在其中出现的能力不得视为项目强制依赖.
<!-- /source: template/tool-entry/gemini -->
