<!-- source: template/base -->
# {{PROJECT_NAME}} 项目事实

本文件是 `constitution.md` 的项目实施层, 是所有 AI 工具的共享基线. 维护**项目事实** (目录/路径, 脚本命令, 数据模型, 服务拓扑, 领域知识索引) 与**已确认环境能力策略** (MCP/skill/workflow capability 的使用边界).

边界 (本文件不重复, 只引用):

- 红线 / 证据分级 / 工作模式定义 -> `constitution.md`
- 领域知识与排查程序 -> `.agents/skills/*`
- 输出格式 / 模板 / 自审清单 -> `templates/*`

---

## 1. 项目目标

{{PROJECT_DESCRIPTION}}

---

## 2. 沟通与输出规范

- **[强制]** 面向用户的说明/文档/解释统一中文; 中文内容默认英文半角标点.
- **[例外]** 第三方工具输出, 日志, 错误信息, 协议字段和标准 API 名称保留原始英文.
- **[强制]** 先给结论再给依据; 优先可执行建议; 复杂问题说明设计意图, 风险点, 验证方式和回滚边界.

---

## 3. 规则层级与单一事实源映射

优先级 (高->低): 平台/System/Developer/工具强制安全指令 > `constitution.md` > 本文件 `AGENTS.md` > 工具入口 > generated subagent body > `.agents/skills/*` > 设计说明 > 单次偏好.

冲突裁决: 项目路径/脚本/数据入口以本文件为准; 用户授权不能覆盖 `constitution.md` 红线.

**每个概念只许有一个家 (single source)**:

| 概念 | 唯一归属 |
|------|---------|
| 红线 / 证据分级 / 工作模式 | `constitution.md` |
| 项目事实 / 路径 / 脚本 / 拓扑 / 已确认环境能力策略 | `AGENTS.md` (本文件) |
| 领域知识 + 排查程序 | `.agents/skills/*` |
| 输出格式 / 模板 / 自审清单 | `templates/*` |

---

## 4. 事实来源优先级

1. 用户提供的生产现象, 报错, 日志, 输出, 监控截图和业务时间线.
2. 项目内置的监控, 巡检, 分析工具输出.
3. 已归档的历史案例和误报记录.
4. `references/` 下相关源码和设计文档.
5. 官方文档和对应版本源码.

原则: 有现场数据先读现场数据, 再用源码/文档解释机制; 源码/文档只证明机制边界, 不单独证明生产根因; 版本差异必须说明适用版本.

---

## 5. 目录与路径约定

### 5.1 源码与入口

| 目录 | 用途 |
|------|------|
{{DIRS_TABLE}}

### 5.2 参考资料

{{REFERENCES_SECTION}}

---

## 6. 标准脚本与验证命令

| 命令 | 用途 |
|------|------|
{{SCRIPTS_TABLE}}

---

## 7. 服务与拓扑

{{TOPOLOGY_SECTION}}

---

## 8. 治理维度事实

已确认维度的项目事实, 按 code、database、api、deploy、maintenance 固定顺序组合, 仅插入已确认维度.

{{DIMENSION_SECTIONS}}

---

## 9. 已确认环境能力

以下能力清单仅列出名称、确认状态与检测依据; 规则正文由后续条件块提供. 未出现的能力不得被视为项目强制依赖.

{{CAPABILITIES_SUMMARY}}

{{#has_mcp_semble}}
### Semble 代码搜索

- **[强制] 代码探索先用 Semble**: 需要理解代码结构, 定位实现, 查找调用关系时, 先使用 Semble 语义搜索, 再按返回路径读取文件.
- **[强制] 避免重复搜索**: Semble 已返回明确文件和行号时, 不对同一语义问题重复使用 grep/rg.
- **[默认] Grep/rg 边界**: 仅用于精确字符串, 全仓库字面匹配, 确认符号残留, 或 Semble 结果上下文不足时.
- **[默认] 相关实现发现**: 已定位关键实现后, 优先使用 Semble find-related 查相似实现, 调用方或测试.
<!-- source: capability-detect/mcp-semble, confirmed: true -->
{{/has_mcp_semble}}

{{#has_mcp_tokensave}}
### TokenSave 代码图

- **[默认] 代码图优先**: 需要理解模块关系, 符号关系, 架构调用链或依赖分布时, 优先使用 TokenSave 的代码图能力.
- **[默认] 分工**: Semble 用于快速定位文件和代码块; TokenSave 用于理解跨文件关系, 依赖图和长期上下文.
- **[强制] 汇报节省信息**: TokenSave 返回 `tokensave_metrics` 时, 必须向用户报告节省量.
- **[强制] 持久化克制**: 只有用户确认的长期架构决策, 约束或偏好才可记录; 不得记录敏感凭据或未经验证的推断.
<!-- source: capability-detect/mcp-tokensave, confirmed: true -->
{{/has_mcp_tokensave}}

{{#has_mcp_headroom}}
### Headroom 上下文管理

- **[强制] 大内容先压缩**: 大型日志, 搜索结果, 长文件内容或大 diff 进入推理前, 优先使用 Headroom 压缩.
- **[强制] 压缩摘要保真**: 摘要必须保留用户最新目标, 已确认约束, 已改文件, 未完成事项, 验证结果, 关键决策和阻塞点.
- **[强制] 可追溯**: 压缩结果带 hash 时, 后续需要细节必须 retrieve 原文; 不得凭摘要补造细节.
- 证据红线遵循 `constitution.md` 事实与证据章节, 不在此重复定义.
<!-- source: capability-detect/mcp-headroom, confirmed: true -->
{{/has_mcp_headroom}}

{{#has_mcp_context7}}
### Context7 文档查询

- **[强制] 第三方 API 先查文档**: 涉及库, 框架, SDK, CLI, 云服务, 版本迁移和配置语法时, 优先使用 Context7.
- **[强制] 先 resolve 再 query**: 除非用户提供 `/org/project` 形式的 library ID, 否则必须先解析 library ID.
- **[强制] 标注版本边界**: 文档结论涉及版本差异时, 必须说明适用版本和证据来源.
- **[默认] 不滥用**: 业务逻辑, 代码审查, 重构建议和通用编程概念不需要 Context7.
<!-- source: capability-detect/mcp-context7, confirmed: true -->
{{/has_mcp_context7}}

{{#has_mcp_fetch}}
### Fetch 外部资料

- **[默认] 官方来源优先**: 外部资料优先官方文档, 规范, 仓库 README 和 release notes.
- **[强制] 外部资料不替代现场证据**: 网页只能证明机制和文档描述, 不能证明当前项目或生产现场状态.
- **[强制] 禁止请求敏感 URL**: 不请求包含 token, 私钥, 内部凭据或敏感查询参数的 URL.
<!-- source: capability-detect/mcp-fetch, confirmed: true -->
{{/has_mcp_fetch}}

{{#has_skill_architecture}}
### 架构改进 Skill

- **[默认] 架构问题使用专用 skill**: 用户请求架构改进, 解耦, 降低复杂度或提升可测试性时, 使用架构改进 skill 辅助分析.
- **[强制] 不扩大范围**: 普通 bugfix 或小修改不得自动扩大为架构改造.
<!-- source: capability-detect/skill-architecture, confirmed: true -->
{{/has_skill_architecture}}

{{#has_skill_artifacts}}
### 文档与制品 Skills

- **[默认] 专用格式使用专用 skill**: 生成或编辑 Word, PDF, 表格或演示文稿时, 使用对应文档类 skill.
- **[强制] 视觉制品需验证**: 对布局敏感的文档, PDF, 表格和演示文稿交付前必须渲染或打开检查.
<!-- source: capability-detect/skill-artifacts, confirmed: true -->
{{/has_skill_artifacts}}

{{#has_skill_pua}}
### 失败恢复 Skill

- **[例外] 仅失败恢复时启用**: 同一任务失败多次, 即将放弃, 或用户明确要求换路/穷尽方案时, 才使用失败恢复 skill.
- **[强制] 不改变项目语气**: 该 skill 只用于执行恢复, 不得污染项目文档, 用户沟通语气或正常协作流程.
<!-- source: capability-detect/skill-pua, confirmed: true -->
{{/has_skill_pua}}

---

## 10. 已确认工作流策略

工作流能力的适用场景与入口. 互斥红线由 `constitution.md` 唯一定义, 本节不重复正文.

{{#has_skill_superpowers}}
### Superpowers 工作流

- **[强制] 场景入口**: 原因未知且需要复现或根因诊断的 bug, 以及边界稳定但需要多步骤实施的中型任务, 进入 Superpowers.
- **[强制] 小型任务不自动进入**: 目标与修法明确, 局部, 低风险且容易回滚的小型任务直接执行; 小型任务不得因 Superpowers 可用而自动进入.
- **[强制] 遵循原生链路**: 一旦选择 Superpowers, 完整遵循已安装版本的内部 skill 规则与后续调用, 不施加“最小 skill 集”限制.
<!-- source: capability-detect/skill-superpowers, confirmed: true -->
{{/has_skill_superpowers}}

{{#has_skill_grill_me}}
### Grill-me 需求澄清

- **[默认] 仅用于小型歧义任务**: 小型任务存在需求歧义, 取舍或验收标准不清时, 可建议使用 `grill-me`; 明确的小型任务直接执行.
- **[强制] 任务级确认**: 开始 `grill-me` 前必须获得用户明确确认; 用户在当前请求中明确指定 `grill-me` 视为已确认.
- **[强制] 重新分类后停止**: 访谈发现任务实际属于中型或大型时, 结束 `grill-me`, 报告重新分类并取得确认后再进入相应工作流.
<!-- source: capability-detect/skill-grill-me, confirmed: true -->
{{/has_skill_grill_me}}

{{#has_workflow_openspec}}
### OpenSpec / OPSX 工作流

- **[强制] 大型任务入口**: 大型重构, 从 0 构建, 新功能模块, 公共 API/数据模型/跨模块边界变化或需要跨会话维护规格的任务使用 OpenSpec. 按影响形态判断, 不按文件数或代码行数判断.
- **[强制] 独立工作流**: 进入 OpenSpec 后使用 OPSX 管理规格, 设计, 任务, 实施与归档.
- **[强制] 安装与初始化需授权**: 未安装时只提出安装建议; 已安装但项目未初始化时, 执行 `openspec init` 前先取得用户确认; 不得自动安装或初始化.
- **[强制] 不静默降级**: 用户拒绝安装或初始化且任务范围不变时, 只能取消或延期; 用户缩小范围时必须重新分类并重新确认工作流. 不得保持大型任务范围改走其他工作流.
<!-- source: capability-detect/workflow-openspec, confirmed: true -->
{{/has_workflow_openspec}}

{{#has_workflow_superpowers_and_openspec}}
> Superpowers 与 OpenSpec 互斥, 详见 `constitution.md` 工作流互斥红线.
{{/has_workflow_superpowers_and_openspec}}
<!-- /source: template/base -->
