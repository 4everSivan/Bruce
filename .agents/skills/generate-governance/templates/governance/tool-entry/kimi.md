<!-- source: template/tool-entry/kimi -->
# Kimi Code CLI

本文件只描述 Kimi Code CLI 自身的专属能力与行为. Kimi 的原生项目入口 `.kimi-code/AGENTS.md` 负责指向本文件; 跨工具共享工作模式与项目事实见 `AGENTS.md`, 工程原则见 `constitution.md`.

---

## 1. 启动与上下文管理

- **治理上下文**: 开始任务前确认已读取 `constitution.md`, `AGENTS.md` 与本文件. 规则冲突时按项目既有治理优先级处理, 不在本文件重新定义优先级.
- **会话隔离**: 大型独立任务使用新会话, 避免无关历史污染当前判断.
- **上下文压缩**: 长任务需要压缩上下文时, 保留适用约束, 关键证据, 未决事项与验证状态.

---

## 2. Kimi 专属能力

- **`explore` 子 Agent**: 用于只读搜索, 阅读, 调用链整理和代码库梳理. 不得修改文件.
- **`plan` 子 Agent**: 用于设计和实施计划. 不执行项目修改.
- **`coder` 子 Agent**: 用于边界明确的实现任务. 委派时给出目标, 输出格式, 允许读写范围和禁止事项.
- **上下文隔离**: 子 Agent 只能依赖任务中显式传递的上下文, 不得假设它知道主会话中的未传递信息. 主 Agent 应核对其结论与代码证据.
- **权限边界**: 工具审批, 会话级允许规则或 YOLO 模式只改变确认方式, 不降低 `constitution.md` 的安全红线与高风险操作约束.

---

## 3. 已确认环境能力

本项目确认的 MCP、skills 与 workflow capabilities, 以及 Skill 索引, 均以 `AGENTS.md` 的"已确认环境能力"为唯一来源; 本文件不重复定义. 未在其中出现的能力不得视为项目强制依赖.
<!-- /source: template/tool-entry/kimi -->
