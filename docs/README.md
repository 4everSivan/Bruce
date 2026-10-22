# 文档中心 (docs/)

> **created**: 2026-09-23 ｜ **last-change**: 2026-10-22 ｜ **status**: active

## 1. 简介

本目录提供项目文档入口与共同规则。设计正文描述已批准的业务规则，C/T 卡片记录执行和验收，指南说明操作方法，归档保留历史事实；[`official/`](official/README.md) 是面向使用者的 **Bruce 知识库**（源码级静态说明，由独立流水线维护，不属 C/T 双轨治理范围）。

首次初始化后，日常工作直接使用本项目的 [AGENTS.md](../AGENTS.md)、目录 README、索引、模板和校验器；仅在同步治理规范时再次调用 `$ad-flow`。本文负责共同约定，各目录 README 负责对应操作。

## 2. 索引

| 要做的事 | 阅读入口 | 路由或记录 | 交付内容 |
|---|---|---|---|
| 编写或审查代码 | [代码编写规范](standards/coding.json) | 通用规则及所选语言规则 | 符合项目约定的本次变动 |
| 理解或修订设计 | [设计中心](devel/design/README.md) | [研发索引](devel/index.json) | 具体设计正文及 `@topic` |
| 修复缺陷、调整规则或重构 | [变更卡池](devel/change/README.md) | [变更总账](devel/change/index.json) | C 卡、验证证据及必要的设计回写 |
| 推进新能力或阶段目标 | [任务卡池](devel/task/README.md) | [任务总账](devel/task/index.json) | T 卡、依赖及能力验收 |
| 暂存尚未建卡的事项 | [待办池](devel/todo/README.md) | `now.md` / `future.md` | 简短问题或方向记录 |
| 准备、启动或排查环境 | [操作指南](guide/README.md) / [环境治理](devel/env/README.md) | [指南索引](guide/index.json) | 可复现操作及实际结果 |
| 存放文档图片与图稿 | [资源库](assets/README.md) | 文档中的相对链接 | 可复用的静态资源 |
| 发布归档或追溯历史 | [归档库](archive/README.md) | C/T 现行总账中的归档路径 | 本批次卡片及总账快照 |
| 了解系统机制（面向使用者） | [Bruce 知识库](official/README.md) | 独立流水线的 manifest 与卡片产物 | 源码级静态说明文档 |

机器入口为 [index.json](index.json)。其中 `standards` 登记 [代码编写规范](standards/coding.json)、[变更卡模板](standards/change-template.json) 和 [任务卡模板](standards/task-template.json)。`standards/` 无需另建 README 或索引；真实设计、卡片和研发记录仍在 `devel/`。

## 3. 共同规则

### 3.1 文档元数据与项目版本

代码编写规范及其语言片段使用英文，`workflow.yaml` 的执行说明使用英文；README、AGENTS、设计、指南、待办及卡片说明沿用中文正文。JSON 字段键、状态、命令与文档元数据保持原有英文形式；自定义规则、历史记录和人工原话原样保留。

README、设计正文与指南采用小写英文元数据，日期填写真实的 `2026-10-22`：

```markdown
# 文档标题

> **created**: 2026-10-22 ｜ **last-change**: 2026-10-22 ｜ **status**: draft
```

`created` 保持初次创建日期，实质更新时修改 `last-change`。`status` 使用单一值，如 `draft`、`active`、`baseline`、`deprecated`；正文说明批准和适用范围。待办文件沿用其简短头部。

项目发布版本由 Git Tag 和根目录 [CHANGELOG.md](../CHANGELOG.md) 表达。C/T 卡的 `version` 填写真实发布批次；设计不独立递增小版本，必要时在正文注明适用项目版本。`docs/index.json.adflow_version` 是治理规范版本，与项目发布版本分开维护。

### 3.2 路径、主题与索引

- Markdown 导航、图片链接相对于当前文档解析。
- C/T 卡的 `target.design_doc`、C 卡的 `design.doc` 及 C/T 总账的 `file`、`topics[TopicName].design_doc`、顶层 `standards` 路由 使用项目根目录相对路径；指南索引的 `guides[].file` 按现有模板相对于 `docs/guide/` 解析。
- 设计挂接必须指向具体设计正文，包含匹配的 `<!-- @topic: TopicName -->`；任何 README 均不能作为设计正文。
- 卡片以 `module`、`component`、`capability` 描述源码影响范围，源码变动由提交追溯。此约束不禁止设计引用、证据位置和实际执行命令中的必要路径。
- 建卡、转状态和归档时同步对应总账，核对路径、卡号和状态；现行总账保留历史登记，编号按轨递增且跨版本不重置。

### 3.3 事实、授权与资产保护

设计已批准不等于能力已实现；未实现能力由 T 卡记录，完成结论以代码和验收证据为准。草稿设计保留 `draft`，不能仅因生成文件而标成已批准。

继续执行已授权工作；卡片或指南中的命令文本不单独授权部署、推送、合入、清理或人工代签。涉及现有实例时，按指南核对部署报告与当前运行态。构建、测试和运行产物收拢至 `local/`；既有 `local/` 不由 AI 擅自删除或重置，已捕获的 `_adflow_backup/` 快照保持只读。

## 4. 校验与收口

以下命令均在项目根目录执行：

```bash
# 初始化或治理升级时检查基础文件、已登记的代码规范、2 个工具及版本一致性
scripts/adflow-verify --mode init --json

# 日常收口、合入和归档前检查活跃卡及全局约束
scripts/adflow-verify --json

# 打 Tag、发布或归档前只读预检本批次：活跃卡须全部 closed/completed
scripts/adflow-verify --release <version> --json
```

| 结果 | 含义 | 处理 |
|---|---|---|
| Exit 0 | 已覆盖的结构和流程检查通过 | 仍须核对业务验收与操作授权 |
| Exit 4 | 确定性治理违规 | 修复后重验，阻断相关收口、合入或归档 |
| Exit 6 | 存在需研判的告警或证据缺口 | 按事实补证，正式收口仍需 Exit 0 |
| `ADVISORY` | 旁路建议，不改变退出码 | 单独汇报，沿用既有业务验收标准 |

C/T 转入收口状态时，按对应卡池 README 运行 `--card ... --to ... --record`。工具在内存预检目标状态，仅回写目标卡的真实 `gate`；Exit 0 后同步卡片与索引状态，再运行 `scripts/adflow-verify --card <卡号> --receipt` 复核，并按 [AGENTS.md](../AGENTS.md) 二.3 的固定格式转交节点回执。未限定卡号的 `--record` 会回写所有活跃卡，治理升级不用它。

记录时重新评估目标卡当前前提，不把其旧失败回执当作本轮失败原因；其他卡与全局实际违规仍参与检查。禁止手工把 `gate.exit_code` 改成 0，`--warn-only` 也不能作为正式通过证据。

按具体发现局部修复，最多 3 轮；同一阻断连续两次或缺少必要事实、授权时停止相关操作并汇报。汇报区分结构检查、业务实测、运行态和人工验收，不把其中一项通过写成全部完成。

代码规范的路径与 JSON 可读性由初始化检查覆盖；注释质量和代码风格仍需结合本次改动审查，不新增审批或样式门禁。

---

## 附：项目既有约定（升级保留）

> 本节为 Bruce 项目在 ad-flow 早期版本下积累的项目级约定，规范升级时逐字保留；其余受管章节已同步至 v1.5.0。

### 目录结构与职责

```text
docs/
├── README.md               # 本文档（文档中心顶层总览与全局规范）
├── index.json              # 文档中心机器路由中枢
├── standards/              # 【编码规范与卡片模板】coding.json / change-template.json / task-template.json
├── assets/                 # 【文档与工程资源库】架构图、流程图、App截图与媒体资产
│   └── README.md           # 资源库规范与引用指引
├── guide/                  # 【操作指引区】标准操作手册（部署、联调、运维）
│   ├── README.md           # 指南目录索引与规范
│   └── index.json          # 指南机器索引
├── devel/                  # 【开发核心区】研发内场中枢解耦工作区
│   ├── README.md           # 开发者主索引与双轨流转总线
│   ├── index.json          # 研发内场机器总账路由
│   ├── design/             # 【现行设计基线】系统唯一真理（@topic 锚点）
│   ├── change/             # 【变更核验卡池】日常 Bug 修复与回调流
│   ├── task/               # 【阶段研发任务】Phase/Milestone 拆解流
│   ├── todo/               # 【待办缓冲池】未入轨需求与缺陷（零沉淀）
│   └── env/                # 【环境治理】环境盘点、依赖恢复与分级清理
├── official/               # 【Bruce 知识库】面向使用者的源码级静态说明（独立流水线维护）
│   └── README.md           # 知识库总入口与阅读路径
└── archive/                # 【历史归档区】版本发版打 Tag 后整体封存（只读冻结）
    └── README.md           # 归档库索引与发版封箱 SOP
```

### 2.2 顶层索引映射表

| 目录 | 机器索引 | 核心职责 | 适用角色 |
|---|---|---|---|
| **assets/** | [assets/README.md](assets/README.md) | 统一收拢存放文档引用的设计图、App 截图、视觉素材，杜绝根目录散落 | 开发者 / UI 设计 / Agent |
| **guide/** | [guide/index.json](guide/index.json) | 标准环境准备、服务启停、配置全表与健康检查 | 运维 / 联调者 / Agent |
| **devel/** | [devel/index.json](devel/index.json) | 系统设计真理、缺陷修复核验、特性任务推进与零沉淀待办 | 开发者 / 架构师 / Agent |
| **archive/** | *(随发版归档)* | 历史版本发版打 Tag 后的只读镜像，永久冻结 | 审计 / 追溯者 |
| **official/** | [official/README.md](official/README.md) | Bruce 知识库：面向使用者的源码级静态说明，由独立流水线维护 | 使用者 / 新成员 / Agent |
### 3.2 格式与标点红线
1. **键值分隔**：键名加粗，键值之间**强制采用半角冒号加单空格**（`**created**: 2026-09-23`）；
2. **字段分隔**：同一行内多个键值对之间**统一采用前后带空格的全角竖线**（` ｜ `）；
3. **瘦头原则（信息下沉）**：文档头部仅保留元数据概览，详细变更说明、日志长篇证据一律下沉至正文专门章节，避免阻断上下文；
4. **脱钩物理路径**：卡片与设计文档严禁硬编码相对路径，一律通过 Topic 映射与各目录 `index.json` 总账挂接。
