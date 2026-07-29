<!-- source: template/tool-entry/codex -->
# Codex

@constitution.md
@AGENTS.md

本文件只描述 Codex 工具自身的专属能力与行为. Codex 原生读取 `AGENTS.md` 获取项目事实; 工程原则, 安全红线和工作模式见 `constitution.md`.

---

## 1. 会话管理

- **长时间任务**: 大型独立工作流建议开启新会话, 避免上下文污染.
- **上下文卫生**: 接近上下文上限时主动总结用户目标, 已确认约束, 已改文件, 验证结果, 未完成事项和阻塞点.
- **证据可追溯**: 压缩摘要不能替代源码, 原始日志和测试输出; 需要细节时按 `AGENTS.md` 的 Headroom 规则取回原文.

---

## 2. Codex 专属能力

- **Agent 委派**: 使用专用 agent 处理目标明确, 可独立验证的聚焦任务. 默认只读; 只有用户明确授权且写入范围互不重叠时才允许修改文件.
- **TDD 工作流**: 关键采集, 聚合, artifact 契约, 时间边界和凭证处理路径遵循红-绿-重构循环.
- **内联审查**: 提交变更前检查 diff, 重点关注凭证泄露, 外部副作用, TLS 校验, JSON 契约兼容和动态 HTML 转义.
- **多模态**: 使用视觉能力分析 Widget 截图, 热力图, 图表和 macOS Dock 栏展示效果; 视觉结论必须与实际渲染结果对应.
- **实时采集边界**: 静态分析, 普通代码审查和测试不得默认运行真实 Collector. 可能访问外部服务, 刷新 OAuth 或写回认证文件时, 必须先取得用户明确授权.

---

## 3. 已确认环境能力

本项目确认的 MCP, skills 与 workflow capabilities, 以及使用边界, 均以 `AGENTS.md` 的"已确认环境能力"为唯一来源; 本文件不重复定义. 未在其中出现的能力不得视为项目强制依赖.

Codex 执行代码探索时必须遵循 `AGENTS.md` 的 Semble-first 规则; 涉及第三方库, CLI 或云服务时遵循 Context7 规则; 大型内容遵循 Headroom 可追溯压缩规则.
<!-- source: user-input -->
<!-- source: scan/project-governance, confidence: HIGH -->
<!-- /source: template/tool-entry/codex -->
