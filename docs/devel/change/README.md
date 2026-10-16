# 变更与核验卡池 (change/)

> **created**: 2026-09-23 ｜ **last-change**: 2026-09-23 ｜ **status**: active

---

## 1. 为什么需要变更核验卡？

在系统进入维护与演进期后，**严禁只改代码而使文档失真，也不要无序涂抹历史基线**：
1. **Bug 修复 (BugFix)**：发现并修复了业务规则、接口或算法中的缺陷；
2. **功能回调 (Rollback)**：实测后发现某项设计不合理，需要回调至上一版参数或逻辑；
3. **接口/契约微调 (Param/Refactor)**：联调时对请求参数、错误码、数据类型或枚举值进行调整。

此时，在 `docs/devel/change/` 下以 `C001`、`C002` 递增编号新建变更卡，记录变更原因、前后规则对照及证据锚。

---

## 2. 变更卡使用流程

```
[发现 Bug / 提出回调]
        ↓
[从 template.json 复制新建 Cxxx.json]  ★ 立即从 todo/now.md 物理删除对应行 (零沉淀)
        ↓
[填写 branch 分支标签、precheck 预检命令与 callback 前后回调钩子]
        ↓
[执行 precheck 嗅探已修复性 -> 执行 callback.before 前置环境准备]
        ↓
[修改代码 + 补充针对性回归测试 -> 执行 callback.after 收尾质量门禁]
        ↓
[运行测试采集 evidence 与脱敏 run_id]
        ↓
[AI 汇报实测并在会话中对齐]
        ↓
[人工确认无误 -> AI 摘录原话代签 user_quote (状态转为 verified)]
        ↓
[代码合入主干 -> 双向回写闭环 (更新 design、CHANGELOG、并在 index.json 标记 closed)]
```

---

## 3. 标准模板与中枢总账

- **标准卡片模板**：[template.json](template.json)
- **全局变更总账**：全量卡片索引与所属 Topic 映射请查阅 [index.json](index.json)。

### 3.1 `topics[].changes` 语义（TD-011 定稿，2026-10-16）

`index.json` 的每个 topic 是**一篇现行设计文档的变更总账**：

- **下限（机器可校验，强制）**：该数组**必须包含所有以该设计文档为 `design.doc`（即卡片 `topic` 字段所指）的卡**。此不变式由 `scripts/check-change-ledger.mjs` 在每次 `verify-local.sh` 中校验，违反即门禁失败。
- **上限（人工维护，可选）**：允许把**非主卡归属、但确实改过该设计文档**的卡一并登记，使该文档的总账完整可读（跨文档多归属）。判定依据以 git 历史或卡内证据为准，不做机器强校验。
- **卡片自身只有一个 `topic` 字段**：它表示主卡归属，因此「数组 ⊋ 主卡归属集合」是合法且预期的（例如 C055 主卡归属为 `TokenUsage`，同时因改写了 design/04 而登记在 `PricingEngine`）。
- **历史缺口**：该语义此前未写明，导致 C039/C040/C041 声明了 `topic` 却未登记进数组，且 design/04 回链的 `PricingEngine` topic 在总账中根本不存在（均已于 C055 修复）。
