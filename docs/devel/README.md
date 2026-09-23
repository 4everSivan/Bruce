# 开发文档索引 (devel/)

> **created**: 2026-09-23 ｜ **last-change**: 2026-09-23 ｜ **status**: active

---

## 1. 简介

`docs/devel/` 是人类开发者与 AI Agent 的研发内场作战室。为了彻底解决传统研发中“代码改动频繁但文档失真失控”的顽疾，本目录采用**“基线真理 + 变更核验 + 阶段任务 + 待办缓冲”**的四层中枢解耦架构：
- **`design/`**：现行设计基线，系统唯一事实源，以 `@topic` 标注主题，保持全文自洽；
- **`change/`**：变更核验卡池，承载日常 Bug 修复与回调，维护 `index.json` 变更总账；
- **`task/`**：阶段研发任务，承载 Phase/Milestone 交付，维护 `index.json` DAG 依赖总账；
- **`todo/`**：待办缓冲池，登记未入轨想法与缺陷，严格执行建卡即移出的零沉淀纪律。

---

## 2. 索引

### 2.1 子系统矩阵速查

| 子目录 | 机器索引 | 核心职责 | 状态/纪律 |
|---|---|---|---|
| **design/** | *(由 devel/index.json 汇聚)* | 包含系统总体设计与各模块现行方案，为系统唯一真理 | 现行基线 |
| **change/** | [change/index.json](change/index.json) | 承载日常 Bug 修复，维护变更对照、证据与回写基线 | 持续轮转 |
| **task/** | [task/index.json](task/index.json) | 承载当前阶段研发任务，维护 DAG 依赖拓扑与交付物 | 随阶段演进 |
| **todo/** | *(now.md / future.md)* | 未入轨缺陷与需求缓冲池，落地建卡即物理移出 | 零沉淀 |
| **../archive/** | *(由 docs/index.json 索引)* | 历史版本发版封箱库，卡片按版本冻结只读 | 永久归档 |

> 📌 **机器访问入口**：AI Agent 可直接通过 [docs/devel/index.json](index.json) 获取内场各子系统的结构化路由与元数据。

---

## 3. 规范

内场研发所有文档必须严格遵守以下工程规范：

### 3.1 头部元数据规范
所有内场 Markdown 文档必须在一级标题正下方标注引用块元数据：
- **`created`**（必填）：初次创建日期，格式 `2026-09-23`；
- **`last-change`**（必填）：最近实质变更日期，格式 `2026-09-23`；
- **`status`**（必填）：纯净状态枚举（如 `active`、`baseline`、`draft`）；
- **`version`**（卡片必填/设计可选）：变更卡（`Cxxx.json`）与任务卡（`Txx.json`）必须包含 `version` 声明归属发布批次；设计文档不设独立小版本号。

```markdown
# 模块名称或设计方案

> **created**: 2026-09-23 ｜ **last-change**: 2026-09-23 ｜ **status**: active
```

### 3.2 研发红线纪律
1. **设计基线唯一性**：`design/` 下的方案代表系统当下的最新状态，以 `<!-- @topic <name> -->` 作为主题锚点；
2. **零沉淀缓冲纪律**：`todo/now.md` 与 `future.md` 中的条目，一旦创建对应的变更卡（`Cxxx`）或任务卡（`Txx`），必须立即从 `todo` 中**物理删除**，严禁堆积已办事项；
3. **路径脱钩**：卡片与设计文档严禁直接硬写相对路径，一律通过 `index.json` 中枢总账与 `@topic` 动态解析关联；
4. **证据闭环**：变更与任务完成时，必须采集真实可复现的验证证据（命令与执行输出），方可代签关闭。

---

## 4. 研发事项流转总线

研发内场严格实行**双轨分流**：

```text
【登记层】  缺陷 / 微调 / 突发 ──► todo/now.md 登记
           远期特性 / 技术债   ──► todo/future.md 登记
                  （落地即移出 · 零沉淀 · 编号全局自增）

【变更修复流 (BugFix Track)】 
  now.md 登记 ──► change/ 建 Cxxx.json  ★ 建卡即从 todo 物理移出
        └─► 声明 target.topic 与 rule_diff (修改前 vs 修改后)
             └─► 代码修改 + 补回归测试
                  └─► 采集 evidence + run_id，人机对齐代签 (verified)
                       └─► 合入主干 ──► 回写 design + CHANGELOG + index.json 闭环

【阶段任务流 (Feature Track)】
  future.md / now.md 登记方向 ──► design/ 修订设计基线 (@topic)
        └─► task/ 拆解 Txx.json + 注册 task/index.json
             └─► 按 depends_on DAG 拓扑顺序推进开发与能力交付
                  └─► DoD 验收全绿 ──► 阶段封箱归档至 archive/<version>/
```
