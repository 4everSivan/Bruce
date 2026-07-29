<!-- source: template/tool-entry/codex -->
# Codex

@constitution.md
@AGENTS.md

本文件只描述 Codex 工具自身的专属能力与行为. Codex 原生读取 `AGENTS.md` 获取项目事实; 工程原则见 `constitution.md`.

---

## 1. 会话管理

- **长时间任务**: 大型独立工作流建议开启新会话, 避免上下文污染.
- **上下文卫生**: 接近上下文上限时主动总结关键事实并交接.

---

## 2. Codex 专属能力

- **Agent 委派**: 使用专用 agent 处理聚焦任务. 默认只读; 写操作需显式授权.
- **TDD 工作流**: 适用场景遵循红-绿-重构循环.
- **内联审查**: 提交变更前使用基于 diff 的审查.
- **多模态**: 使用视觉能力分析截图和图表.

---

## 3. 已确认环境能力

本项目确认的 MCP、skills 与 workflow capabilities, 以及 Skill 索引, 均以 `AGENTS.md` 的"已确认环境能力"为唯一来源; 本文件不重复定义. 未在其中出现的能力不得视为项目强制依赖.
<!-- /source: template/tool-entry/codex -->
