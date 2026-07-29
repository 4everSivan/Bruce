<!-- source: template/tool-entry/claude -->
# Claude Code

@constitution.md
@AGENTS.md

本文件只描述 Claude Code 工具自身的专属能力与行为. 跨工具共享工作模式见 `AGENTS.md` 的 AI 协作指令; 工程原则见 `constitution.md`, 项目事实与协作约定见 `AGENTS.md`.

---

## 1. 启动与上下文加载

- **`/memory` 检查**: 首次进入项目, 切换 worktree, 发现规则冲突或怀疑 memory 未加载时, 使用 `/memory` 检查当前生效的规则配置.
- **会话隔离**: 每个独立的大型任务建议开启新会话, 避免长生命周期导致的上下文污染.

---

## 2. 专属能力运用

- **Plan Mode**: 用于复杂架构设计或大重构前的方案收敛. 简单修改直接在默认模式执行, 进入执行后不反复停留在计划层面.
- **Subagent 委派**: 适用于独立检索, 代码审查, 边界条件枚举和写入范围清晰的子任务. 委派时给出目标, 输出格式, 允许读写范围和禁止事项. 默认只读; 仅任务明确授权且写入文件集合互不重叠时, 才允许 subagent 修改文件.
- **Explore Subagent 三档**: Claude Code 内置的只读探索 subagent, 按任务广度选档:
    - `quick`: 单点定位 (查找文件, 类, 函数, 配置项).
    - `medium`: 局部模块理解, 单模块调用分析, 普通上下文探索.
    - `very thorough`: 调用链分析, 架构梳理, 跨模块依赖分析.
      Explore subagent 仅做搜索, 阅读, 总结和建立调用链, 不修改文件.
- **编辑工具选型**: 修改项目文件优先使用 Claude Code 的结构化编辑能力. 简单机械替换可使用可审查脚本.

---

## 3. 已确认环境能力

本项目确认的 MCP、skills 与 workflow capabilities, 以及 Skill 索引, 均以 `AGENTS.md` 的"已确认环境能力"为唯一来源; 本文件不重复定义. 未在其中出现的能力不得视为项目强制依赖.
<!-- /source: template/tool-entry/claude -->
