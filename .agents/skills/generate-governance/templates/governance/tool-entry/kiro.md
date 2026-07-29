<!-- source: template/tool-entry/kiro -->
# Kiro

@constitution.md
@AGENTS.md

本文件只描述 Kiro 工具自身的专属能力与行为. Kiro 经 `resources` 引用 `AGENTS.md`; 工程原则见 `constitution.md`.

---

## 1. 会话与上下文

- **工作区隔离**: 大型独立任务使用独立工作区, 避免上下文交叉污染.
- **资源引用**: 项目事实通过 `resources/` 加载, 不重复定义.

---

## 2. Kiro 专属能力

- **Agent 编排**: Kiro 的 agent 系统支持多角色协作; 委派时明确输入/输出/读写边界.
- **知识库集成**: 可引用内置或自定义知识库; 领域知识优先走技能 (skills) 体系.
- **结构化输出**: 需要严格格式时使用 structured output 约束.

---

## 3. 已确认环境能力

本项目确认的 MCP、skills 与 workflow capabilities, 以及 Skill 索引, 均以 `AGENTS.md` 的"已确认环境能力"为唯一来源; 本文件不重复定义. 未在其中出现的能力不得视为项目强制依赖.
<!-- /source: template/tool-entry/kiro -->
