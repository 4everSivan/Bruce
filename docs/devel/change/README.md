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
[填写前后规则对照 changes 与二值化判据 true_if / false_if]
        ↓
[修改代码 + 补充回归测试用例]
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
