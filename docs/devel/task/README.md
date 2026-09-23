# 阶段任务卡池 (task/)

> **created**: 2026-09-23 ｜ **last-change**: 2026-09-23 ｜ **status**: active

---

## 1. 为什么需要任务卡？

在新阶段立项或进行大模块重构时：
1. **架构到执行的桥梁**：将设计方案（`design/`）中的宏观设计拆解为可逐个执行、可独立验收的最小研发单元；
2. **拓扑顺序保障**：通过 `depends_on` 显式声明任务间依赖，防止越级开发导致的频繁返工；
3. **完成定义防烂尾**：每个任务定义明确的 `acceptance.checks`，全部通过方可标记为 `completed`。

---

## 2. 任务卡流转流程

```
[阶段立项 / 里程碑规划]
        ↓
[从 template.json 复制新建 Txx.json]
        ↓
[填写 capability 交付目标、depends_on 依赖与 acceptance 判定依据]
        ↓
[在 index.json 注册该卡]
        ↓
[根据 DAG 依赖拓扑，依赖全满足的任务就绪开工 (status: in_progress)]
        ↓
[纯函数/服务实现 + 单元测试覆盖]
        ↓
[DoD 验收全绿 (result: true) -> 状态转为 completed]
        ↓
[阶段全量任务完成 -> 打版本 Git Tag 整体封箱归档至 archive/<version>/task/]
```

---

## 3. 标准模板与中枢总账

- **标准任务模板**：[template.json](template.json)
- **全局任务总账**：里程碑聚合大盘与任务拓扑图请查阅 [index.json](index.json)。
