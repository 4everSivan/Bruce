# Bruce 知识库

本知识库说明 Bruce 的本地用量、订阅额度、桌面应用和工程交付机制，依据当前工作区源码、配置、测试定义与原项目文档编写。正文描述静态实现；原设计目标、历史记录和未完成接口在相关位置单独注明，不包含本机运行测量或新增人工验收结论。

## 建立整体认识

- [系统设计](system-design.md)：先了解业务模块、两个桌面入口、共享 Collector 与独立 Widget 的边界。
- [术语表](glossary.md)：查阅 Bridge、Artifact、快照、调度与凭据存储在项目中的含义。

## 理解采集与额度

- [Collector 设计](collector-design.md)：从真实 CLI 和共享 Bridge 入口理解本地用量模块及响应契约。
- [本地会话解析与计费](collector-local-usage.md)：了解扫描窗口、增量缓存、Token 聚合和价格覆盖。
- [订阅额度查询设计](collector-provider-quota.md)：了解凭据注入、Provider 适配、额度窗口和局部失败。

## 理解桌面应用的行为

- [macOS 应用设计](macos-design.md)：了解启动、菜单栏、设置、看板和主题的职责。
- [订阅配置与凭据管理](credentials-design.md)：了解授权门控、受保护文件、外部登录态和 Codex 账号管理。
- [刷新生命周期](refresh-lifecycle.md)：沿一轮刷新追踪输入、采集、恢复、发布、告警与退出。
- [Windows 应用设计](windows-design.md)：了解 Tauri 入口、配置、IPC、窗口与共享引擎接入。
- [Windows 快照与刷新状态](windows-state-mapping.md)：区分刷新意图、快照状态与前端数据映射。
- [Widget 设计](widget-design.md)：了解独立宿主数据接口、展示口径和动画释放。

## 构建与交付

- [构建、验证与发布](build-release.md)：查找验证入口、Preview 产物、tag CI 与手工签名公证的边界。

最后更新：2026-10-18
