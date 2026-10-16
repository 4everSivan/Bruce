# 版本与阶段归档库 (archive/)

> **created**: 2026-09-23 ｜ **last-change**: 2026-10-16 ｜ **status**: active

---

## 1. 归档原则

1. **版本封箱**：每当项目完成既定里程碑打出 Git Tag（如 `v0.1.0`）时，当前版本周期内产生的所有已闭环变更卡（`Cxxx.json`）与阶段任务卡（`Txx.json`）整体移入本目录；
2. **只读保护**：归档后的文件处于永久冻结状态，严禁二次修改或作为活文档更新；
3. **零断链中枢**：设计文档不需要改写单个卡片的相对链接，由各版本归档的 `index.json` 承担该版本内的索引与跳转职责。

---

## 2. 发版归档 SOP 四步法

```
【第 1 步】创建归档目录: docs/archive/<version>/{change,task}
     ↓
【第 2 步】物理迁移卡片: 将 closed 状态卡片移入归档目录
     ↓
【第 3 步】更新中枢总账: 更新 index.json 中的 file 映射路径
     ↓
【第 4 步】设计文档零修改: 现行基线保持纯净，0 断链
```

---

## 3. 归档版本目录索引

```
docs/archive/
├── README.md                 # 本索引文档
└── 0.12.0/                   # v0.12.0 发版封箱归档
    ├── change/               # 全部 closed 变更卡 (27 张)
    │   ├── index.json        # 该版本变更总账快照 (卡片 id/type/version/file)
    │   ├── C015.json ... C041.json
    ├── task/                 # 全部 completed 任务卡
    │   ├── index.json        # 该版本任务总账快照
    │   └── T05.json, T06.json
```

**归档实况（2026-10-16，随 v0.12.0 tag 封箱）**

| 项 | 实况 |
|---|---|
| 变更卡 | 27 张（C015–C041），全部为 `closed` 状态；`docs/devel/change/index.json` 的 `file` 映射已同步刷新 |
| 任务卡 | 2 张（T05 Jev 适配、T06 ClinePass 适配），状态为 `completed`；T01–T04 仍为 `in_progress`（待 Windows 真机验收），故留在 `docs/devel/task/` |
| 卡片内容 | 一字未改，仅迁移物理位置；目录冻结只读 |
| 断链核验 | 全仓指向 `change/Cxxx.json` / `task/Txx.json` 的 Markdown 链接 6 条，全部指向仍留在 `docs/devel/` 的 C001–C004，归档后 0 断链 |
| 首次执行说明 | 本目录此前只有 README，16 个历史 tag 均未执行归档 SOP。本次为首度执行，故除本版本周期闭环的卡外，也一并收拢了此前已发版但未归档的 C015–C018（其自身 `version` 声明分别为 v0.11.3 / v0.11.4 / v0.11.5，卡内原样保留，未按发版版本重新归属）。C001–C014 虽已随 v0.9.0–v0.11.2 发布，但状态仍为 `verified` 而非 `closed`，按 SOP 第 2 步「仅迁移 closed 卡片」留在 `docs/devel/change/` |
