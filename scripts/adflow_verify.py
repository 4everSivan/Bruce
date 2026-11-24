#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""adflow-verify —— ad-flow 流程纪律的可执行校验层（方案 W：纯工作流内嵌，无钩子/CI）。

把 ad-flow 的不变量与双轨卡片 SOP 从"散文要求"变成"可机械判定"的门禁：
  * 流程门禁（默认）：状态感知地扫描活跃卡（docs/devel/change、docs/devel/task），
    按每张卡当前的 status 只校验"该状态此刻应成立的前提"（P1-P14）。
  * 初始化 DoD（--mode init）：核对基础文件、已登记代码规范、禁占位、版本标签、校验器副本版本。
  * 发版预检（--release VERSION）：本批次活跃卡必须已到达本轨终态，只读。
  * 节点回执（--card ID --receipt）：状态同步后复核，并按固定格式输出该卡回执，只读。
  * 路由查询（--next-id TRACK / --topic NAME）：跨现行总账与归档批次总账输出下一卡号或主题历史，只读。

设计原则：
  * 仅用标准库，栈无关——可在任意目标工程里运行。
  * 退出码对齐 references/05-audit-checklist：0 干净 / 4 确定性违规 / 6 仅软告警。
  * 只读；除非 --record（可用 --card 限定回写范围）。
  * --card ID --to STATE 仅在内存预检目标状态，不代替人工验收或修改状态。
  * 新增 ADVISORY 诊断不影响退出码，保持既有门禁标准。
  * 每条 finding 带注册表默认 hint，调用点可给出更具体的修复提示；--list-checks 输出静态
    诊断目录（不依赖目标项目），与校验行为共用同一张注册表。
  * 归档区只允许终态卡：非 closed/completed 即 ARCHIVE_NON_TERMINAL 确定性违规
    （v1.1.0 起既有归档前置的机器覆盖；历史冻结卡由人工口径处置，见归档 README）。
    总账路由与归档目录物理扫描双覆盖，未登记的归档卡同样受检。
  * 分层总账：现行总账只需登记活跃卡，归档卡路由冻结在 docs/archive/<批次>/index.json
    （adflow-archive-batch-v1），与现行总账适用同一组路由硬检查；旧布局仍有效。
  * 里程碑标记与成员任务状态矛盾仅旁路观察（MILESTONE_STATUS_DRIFT）。
  * gate 证伪：声称 exit_code==0 的终态卡，会被独立复算，矛盾即 GATE_CLAIM_CONTRADICTION。

用法：
  adflow-verify [target_dir=.] [--json] [--warn-only] [--mode init]
                [--card ID [--to verified|closed|completed]] [--record]
                [--release VERSION] [--card ID --receipt]
                [--next-id change|task] [--topic NAME]
                [--list-checks]
"""
import argparse
import copy
import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

VERSION = "1.8.1"

# ---- 常量 ----
TOPIC_RE = re.compile(r"<!--\s*@topic:\s*([A-Za-z0-9_]+)\s*-->")
TAG_RE = re.compile(r"@ad-flow:\s*initialized(?:\s+v([0-9.]+))?")
TAG_COMMENT_RE = re.compile(r"<!--\s*@ad-flow:\s*initialized(?:\s+v([0-9.]+))?\s*-->")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
TOOL_VERSION_RE = re.compile(r'^VERSION\s*=\s*"([^"]*)"', re.M)
RUNID_RE = re.compile(r"^(\d+|local-[\d\-]+)$")              # 纯数字或 local-YYYYMMDD-HH，禁内网
# Cxxx / Txx；用 ASCII 边界而非 \b，中文紧邻卡号（如“修复C001问题”）也能识别。
CARD_ID_RE = re.compile(r"(?<![A-Za-z0-9_])([CT]\d{2,3})(?![A-Za-z0-9_])")
SRC_PATH_RE = re.compile(r"(?:^|/)(src|app|lib|cmd|internal)/[\w/.\-]+\.\w+")
# ── Bruce 本地判据覆盖 (LOCAL PATCH — 非上游 ad-flow 1.8.1 内容) ──────────────
# 上游: CANNED_QUOTES 含中文确认词 (已确认/确认/已通过/同意), 且 user_quote 长度门槛为 6。
# 本项目维护者的确认天然简短 —— 会话存档实测原话为「确认」「确认，推送」「签收」,
# 逐字记录也一律被误报为套话, 且该门槛无法在不伪造原话的前提下满足。
# 经维护者决定 (2026-10-22) 调整如下:
#   * 套话集合仅保留不含实质确认的通用英文填充词;
#   * 长度门槛降为 2 (空值仍由 EVIDENCE_QUOTE 硬拦, 见 check_state)。
# ⚠ 重新安装或升级校验器副本后必须重新施加本补丁。
# 依据与约束见 AGENTS.md「项目自定义规则」第 6 条。
# ─────────────────────────────────────────────────────────────────────────────
CANNED_QUOTES = {"ok", "yes", "done", "tested", "lgtm"}
MIN_QUOTE_LEN = 2
PATH_KEYS = {"files", "file", "paths", "file_path", "filepath", "sources"}
TERMINAL = {"verified", "closed", "completed"}
CLOSED = {"closed", "completed"}
TRACK_TERMINAL = {"change": "closed", "task": "completed"}
TRANSITIONS = {"change": {"verified", "closed"}, "task": {"completed"}}
STATUSES = {"change": {"draft", "pending", "in_progress", "rejected", "verified", "closed"},
            "task": {"pending", "in_progress", "completed"}}
# 归档批次总账：冻结的归档卡路由随批次存放，现行总账只承载可变的活跃卡。
BATCH_SCHEMA = "adflow-archive-batch-v1"
BATCH_KEYS = {"change": "cards", "task": "tasks"}
TOPIC_KEYS = {"change": "changes", "task": "tasks"}
ID_PREFIX = {"change": "C", "task": "T"}
ID_WIDTH = {"change": 3, "task": 2}
TOPIC_NAME_RE = re.compile(r"[A-Za-z0-9_]+")
HERE = "当前工作区"  # --next-id 出处标签：目标目录本身

# Templates and coding standards use root-index registration; legacy layouts stay valid.
BASE_FILES = [
    "AGENTS.md", "CHANGELOG.md",
    "docs/README.md", "docs/index.json", "docs/assets/README.md",
    "docs/guide/README.md", "docs/guide/index.json", "docs/guide/01-本地部署指南.md",
    "docs/devel/README.md", "docs/devel/index.json", "docs/devel/design/README.md",
    "docs/devel/change/README.md", "docs/devel/change/index.json",
    "docs/devel/task/README.md", "docs/devel/task/index.json",
    "docs/devel/todo/README.md", "docs/devel/todo/now.md", "docs/devel/todo/future.md",
    "docs/devel/env/README.md", "docs/devel/env/01-环境缓存与依赖清理指南.md",
    "docs/archive/README.md",
]
PLACEHOLDER = "docs/devel/design/01-系统设计方案.md"
TOOL_FILES = ["scripts/adflow_verify.py", "scripts/adflow-verify"]
STANDARD_FILES = {
    "coding": "docs/standards/coding.json",
    "task_template": "docs/standards/task-template.json",
    "change_template": "docs/standards/change-template.json",
}
LEGACY_FILES = {
    "docs/guide/01-本地部署指南.md": "docs/guide/01-local-deployment.md",
    "docs/devel/env/01-环境缓存与依赖清理指南.md": "docs/devel/env/01-cache-and-dependency-cleanup.md",
    "docs/standards/task-template.json": "docs/devel/task/template.json",
    "docs/standards/change-template.json": "docs/devel/change/template.json",
    "docs/standards/coding.json": "docs/devel/coding-standards.json",
}
# 模板占位符：初始化须渲染为真实项目名与日期；正文中的格式示例不在检查范围。
PLACEHOLDER_VALUES = {"MyProject", "YYYY-MM-DD"}
PLACEHOLDER_FIELDS = {
    "docs/index.json": ("project", "created", "last_change"),
    "docs/devel/index.json": ("project", "created", "last_change"),
    "docs/guide/index.json": ("project", "created", "last_change"),
    "docs/devel/change/index.json": ("updated_at",),
    "docs/devel/task/index.json": ("updated_at",),
}

# ---- 诊断码注册表 ----
# 单一来源：code -> (severity, meaning, hint)。severity 是常规模式（--warn-only 之前）
# 发出时的级别，退出行为仍由调用点决定；回归测试比对全部发出点与注册表，防止两处漂移。
# hint 是默认修复提示，调用点可传更具体的一条覆盖。--list-checks 与回归测试共用本表。
CHECKS = {
    "ARCHIVE_ID_COLLISION": (
        "ADVISORY", "未登记的归档卡与其他卡撞号",
        "为两张不同事项分配不同卡号，并同步依赖、主题与总账引用；未登记归档卡不作为依赖解析来源。"),
    "ARCHIVE_NON_TERMINAL": (
        "ERROR", "归档区存在非终态卡",
        "先把卡收口到 C 卡 closed / T 卡 completed 再移入归档区；历史冻结卡按 "
        "docs/archive/README.md「历史批次账实修复」由人工定口径处置，升级不自动改写。"),
    "ARCHIVE_UNREGISTERED": (
        "ADVISORY", "归档卡未经总账路由",
        "把该卡登记到 docs/archive/<批次>/index.json（adflow-archive-batch-v1），file 指向归档路径；"
        "或确认它应留在活跃卡池。"),
    "BASE_FILE_MISSING": (
        "ERROR", "缺少基础治理文件或已登记规范",
        "按 finding 的 path 从技能包模板重新渲染缺失文件；不要手工空建占位文件，补齐后重跑 --mode init。"),
    "CHANGELOG_LINK_MISSING": (
        "WARN", "closed 卡号未出现在 CHANGELOG.md",
        "在 CHANGELOG.md 对应版本条目补该卡号的双向链接。"),
    "CHECKS_NOT_ALL_TRUE": (
        "ADVISORY", "验收项为空或未全部为 true",
        "逐项核对真实验收结果并落 true/false；结构门禁不能替代业务验收，未通过项不要收口。"),
    "CHECK_RESULT_MISSING": (
        "ERROR", "存在 result 未裁决的验收项",
        "为每个 checks[] 项写入 result: true 或 false（二值契约），再根据结果决定是否收口。"),
    "COMMIT_MISSING": (
        "ERROR", "终态卡缺少 sync.commit",
        "补 sync.commit，填本次交付的真实提交 SHA（应为当前 HEAD 的祖先）。"),
    "COMMIT_NOT_ANCESTOR": (
        "ERROR", "sync.commit 不是 HEAD 祖先",
        "核对实现提交与当前分支：确认该提交属于本次交付且已进入当前历史；"
        "未合入分支的提交不能作为终态证据。"),
    "COMMIT_SKIPPED_NO_GIT": (
        "WARN", "无 Git 环境，跳过 commit 祖先校验",
        "在目标项目的 Git 仓库内复核 sync.commit 与交付的关联；本项表示环境跳过，不是通过证据。"),
    "CONTRACT_INCOMPLETE": (
        "ERROR", "验收项缺少 true_if/false_if",
        "为每个验收项补齐 true_if（通过条件）与 false_if（失败条件），两者描述同一行为的两侧边界。"),
    "CONTRACT_SYMMETRIC": (
        "ERROR", "true_if 与 false_if 相同",
        "分别写出通过条件与失败条件，不能复用同一段判据。"),
    "DECOUPLING_VIOLATION": (
        "WARN", "卡片硬编码源码物理路径",
        "卡片只声明 module/component/capability，具体文件变动通过 sync.commit 追溯。"),
    "DEP_CYCLE": (
        "ADVISORY", "依赖出现环路",
        "调整 depends_on 消除环路；本版仅提示，不新增阻断，但环路会让开工顺序无法成立。"),
    "DEP_DANGLING": (
        "ERROR", "depends_on 引用不存在的卡",
        "修正卡号；若依赖任务尚未建立，先建卡并登记总账，再重跑。"),
    "DEP_NOT_COMPLETED": (
        "ERROR", "前置任务尚未 completed",
        "先完成并收口前置任务，或把 depends_on 调整为真实依赖；不要把未完成前置当作已完成。"),
    "DEP_NOT_READY": (
        "ADVISORY", "任务已开工但前置任务未完成",
        "先完成前置任务再推进本卡，或调整依赖与开工顺序并在卡内说明。"),
    "DESIGN_DOC_MISSING": (
        "ERROR", "缺少或找不到设计文档",
        "按 finding 的字段与路径处理：字段缺失则先写/改 docs/devel/design/ 下的基线设计并打 @topic 锚标；"
        "路径失效则修正 design_doc。禁止指向 README。"),
    "DESIGN_ROUTE_DRIFT": (
        "ADVISORY", "设计文档机器路由缺失或失效",
        "在 docs/devel/index.json 的 design 子系统 `designs` 数组登记 `{file, topic, status, title}`："
        "file 为项目根相对路径，topic 须在设计正文中存在对应 @topic 锚标；旧布局没有 designs 键时保持只读兼容。"),
    "DESIGN_TOPIC_MISSING": (
        "ADVISORY", "未声明 target.design_topic",
        "为卡片补 target.design_topic，并在对应基线设计中补匹配的 <!-- @topic: X --> 锚标。"),
    "EVIDENCE_QUOTE": (
        "ERROR", "缺少人类原话 user_quote",
        "在会话中取得人类明确确认后，把原话摘入 C 卡 verification.user_quote；"
        "确认缺失时保持当前状态，不要用套话代签。"),
    "EVIDENCE_QUOTE_CANNED": (
        "WARN", "user_quote 疑似套话",
        "核对会话并摘录维护者明确确认的原话。仅有英文填充词或少于两个字符时，先取得有效确认。"),
    "EVIDENCE_RUNID": (
        "ERROR", "run_id 为空或格式非法",
        "填真实流水号：纯数字或 local-YYYYMMDD-HH；禁止内网 URL、空值与编造。"),
    "EVIDENCE_SIGNOFF": (
        "ERROR", "缺少 signoff",
        "取得真实人工确认后补 signoff（代签人标识），不要自导自演。"),
    "GATE_CLAIM_CONTRADICTION": (
        "ERROR", "声称 gate 通过但实测有硬违规",
        "先只读复核定位并修复根因；确认无剩余阻断、证据真实且符合状态流转后，再用 "
        "--card <ID> --to <状态> --record 回写。不要只改 gate 期望值。"),
    "GATE_EXIT_NONZERO": (
        "ERROR", "终态卡未记录 gate.exit_code==0",
        "修复 finding 中的根因后，运行 scripts/adflow-verify --card <ID> --to <状态> --record "
        "记录真实结果；不要手填 gate 块。"),
    "HOTFIX_OPEN": (
        "WARN", "hotfix 卡仍未闭环",
        "故障恢复后 24 小时内补齐卡片、核验、设计回写与 CHANGELOG，并收口该卡。"),
    "ID_DUPLICATE": (
        "ERROR", "卡号重复",
        "为后建事项重新取号（scripts/adflow-verify --next-id <track>），并同步索引、依赖、主题与 "
        "CHANGELOG 引用；不要用后一张卡覆盖前一张。"),
    "INDEX_FILE_DEAD": (
        "ERROR", "索引 file 路径失效",
        "把 file 改为该卡实际路径；若卡已归档，改由 docs/archive/<批次>/index.json 路由并从活跃登记移除。"),
    "INDEX_FILE_DRIFT": (
        "ERROR", "索引 file 未指向该活跃卡",
        "把索引条目的 file 改为卡片实际相对路径（docs/devel/<track>/<ID>.json）。"),
    "INDEX_FILE_INVALID": (
        "ERROR", "索引 file 路径非法",
        "file 必须是目标项目内的相对路径；批次总账条目须指向本批次目录，活跃条目须指向所属轨道。"),
    "INDEX_FILE_MISSING": (
        "ERROR", "索引条目缺少 file",
        "为索引条目补非空 file，值为卡片在项目内的相对路径。"),
    "INDEX_ID_DRIFT": (
        "ERROR", "索引键与卡片 id 不一致",
        "统一索引键与卡片 id，并同步依赖、主题与 CHANGELOG 中的卡号引用。"),
    "INDEX_MISSING": (
        "ERROR", "缺少卡片总账索引",
        "创建对应轨道的 index.json（含 cards/tasks 与 topics），并登记现有活跃卡。"),
    "INDEX_MISSING_CARD": (
        "ERROR", "卡片未登记到总账",
        "在 finding 指向的 index.json 对应轨道补登记：卡号 → {status: 当前状态, file: 卡片相对路径}。"),
    "INDEX_STATUS_DRIFT": (
        "ERROR", "索引状态与卡片不一致",
        "先确认真实状态，再把索引条目 status 同步为卡片当前状态；收口时卡片与索引同改。"),
    "INDEX_TOPIC_README": (
        "ERROR", "topics design_doc 指向 README",
        "改指基线设计文档（00-系统总体设计.md 或 01~99-*.md），并在其中补匹配的 @topic 锚标。"),
    "JSON_PARSE": (
        "ERROR", "JSON 文件无法解析",
        "按 finding 的 path 与解析位置修复 JSON（常见为逗号、引号、重复键），保留既有登记，"
        "修好后重跑原命令。"),
    "JSON_TYPE": (
        "ERROR", "JSON 字段类型不符合契约",
        "按 finding 指出的字段改为模板要求的类型（对象/数组/字符串/数字），保留其他字段后重跑。"),
    "LEGACY_TEMPLATE_EXISTS": (
        "ERROR", "仍存在旧模板副本",
        "先确认快照、规范模板自定义字段与引用已迁移，再按已授权的升级流程退役 "
        "docs/devel/{change,task}/template.json。"),
    "LEDGER_ARCHIVED_ENTRIES": (
        "ADVISORY", "现行总账仍登记归档卡",
        "按 docs/archive/README.md「现行总账瘦身」把归档登记迁入 docs/archive/<批次>/index.json；"
        "旧布局仍有效，可择机整理。"),
    "LEDGER_DUPLICATE_KEY": (
        "ADVISORY", "总账内卡号重名",
        "同一卡号只保留一条登记；合并冲突时修正卡号与引用，不要两侧都留（JSON 重名键只保留最后一条）。"),
    "MILESTONE_STATUS_DRIFT": (
        "ADVISORY", "里程碑状态与成员任务不一致",
        "把里程碑状态与成员任务对齐：任务未全部完成时不要把里程碑标记为 completed。"),
    "NO_README_AS_DESIGN_DOC": (
        "ERROR", "design_doc 指向 README",
        "改指 docs/devel/design/ 下的基线设计（00-系统总体设计.md 或 01~99-*.md），并在该文档补匹配的 "
        "<!-- @topic: X -->；禁止指向任何 README。"),
    "PLACEHOLDER_DESIGN_EXISTS": (
        "ERROR", "存在禁用的占位设计文档",
        "删除 docs/devel/design/01-系统设计方案.md，用实际成立的基线设计取代。"),
    "PLACEHOLDER_UNRENDERED": (
        "ADVISORY", "模板占位符未渲染",
        "用真实项目名与初始化日期替换 MyProject/YYYY-MM-DD；正文中的格式示例保持原样。"),
    "REJECTION_NO_AUDIT": (
        "ERROR", "rejected 卡缺少驳回审计",
        "在 rejections[] 补 reason（及返工动作）；返工后重新取证并取得新确认。"),
    "RELEASE_BATCH_EMPTY": (
        "ADVISORY", "未找到该批次的卡片",
        "核对版本拼写；确认本批次确无卡片时在发布记录中显式说明。"),
    "RELEASE_NOT_TERMINAL": (
        "ERROR", "发布批次内存在非终态卡",
        "先收口本批次卡片（C closed / T completed），或显式延后到下一批次，再重跑 --release。"),
    "RELEASE_SCOPE_UNKNOWN": (
        "WARN", "未收口卡未填写 version",
        "为该卡补真实发布批次 version，或显式移出本批次，再重跑 --release。"),
    "RELEASE_STRANDED": (
        "ADVISORY", "早批次终态卡仍滞留活跃区",
        "确认该卡是否随本批次归档；不随本批次则规划下一批次并保持卡片 version 原值。"),
    "SIGNOFF_STALE": (
        "ADVISORY", "沿用驳回前的确认原话",
        "驳回后清空旧 user_quote/signoff；返工完成并取得新的人工确认后再写入。"),
    "STANDARD_ROUTE": (
        "ERROR", "docs/index.json.standards 路由不符",
        "只登记 canonical 三路径（docs/standards/{coding,change-template,task-template}.json），"
        "并确认文件存在且可解析。"),
    "STATUS_INVALID": (
        "ERROR", "状态不在该轨允许集合",
        "按轨道修正 status：change 为 draft/pending/in_progress/rejected/verified/closed，"
        "task 为 pending/in_progress/completed。"),
    "TAG_DUPLICATE": (
        "ADVISORY", "存在多个版本不同的初始化标签",
        "升级后只保留当前版本的 <!-- @ad-flow: initialized vX.Y.Z --> 标签，删除旧标签。"),
    "TAG_MISSING": (
        "ERROR", "缺少初始化版本标签",
        "在 AGENTS.md 首部补 <!-- @ad-flow: initialized v<当前治理版本> -->。"),
    "TASK_SIGNOFF_MISSING": (
        "ADVISORY", "completed 任务卡缺少人工确认",
        "取得人类明确确认后，把原话写入 acceptance.user_quote 并补 signoff。"),
    "TASKS_NOT_ALL_DONE": (
        "ADVISORY", "completed 任务卡仍有未完成能力单元",
        "把 tasks[].done 与真实完成情况对齐；未全部完成时不要把任务卡置为 completed。"),
    "TOOL_VERSION_DRIFT": (
        "ERROR", "校验器副本版本与治理版本不一致",
        "用技能包的 scripts/adflow_verify.py 与 scripts/adflow-verify 覆盖安装副本，使其 VERSION 与 "
        "docs/index.json.adflow_version 一致。"),
    "TOPIC_ANCHOR_MISSING": (
        "ERROR", "设计文档缺少匹配的 @topic 锚标",
        "在 finding 指出的设计文档补 <!-- @topic: <主题> -->，或修正卡内 design_topic 与实际锚标一致。"),
    "TOPIC_EMPTY": (
        "ADVISORY", "未找到该主题的登记或卡片",
        "核对主题拼写，或先在设计文档补 @topic 并在总账 topics 登记。"),
    "TRANSITION_CARD": (
        "ERROR", "目标卡不在活跃卡池",
        "确认卡号拼写正确且属于当前活跃卡池（未被归档），再重试。"),
    "TRANSITION_STATE": (
        "ERROR", "目标状态不被该轨支持",
        "按轨道选择目标状态：change 用 verified/closed，task 用 completed。"),
    "VERSION_DRIFT": (
        "ERROR", "AGENTS 标签与 index 版本不一致",
        "统一 AGENTS.md 标签与 docs/index.json.adflow_version；以 scripts/adflow_verify.py 的 VERSION 为准。"),
    "VERSION_MISSING": (
        "ERROR", "缺少 adflow_version",
        "在 docs/index.json 补 adflow_version（字符串形式的当前治理版本）。"),
    "ZERO_SEDIMENT_VIOLATION": (
        "ERROR", "todo 残留已建卡事项",
        "按 finding 的文件与行号在 now.md/future.md 核对事项，确认已建卡后物理删除该行。"),
}


def check_catalog():
    """按 code 排序输出注册表条目，供 --list-checks 与回归测试共用。"""
    return [{"code": code, "severity": CHECKS[code][0], "meaning": CHECKS[code][1],
             "hint": CHECKS[code][2]} for code in sorted(CHECKS)]


class Ctx:
    """一次运行的共享上下文。"""

    def __init__(self, root):
        self.root = Path(root).resolve()
        self.findings = []          # list[dict(sev, code, card, path, msg)]
        self._json_cache = {}
        self._text_cache = {}
        self._git = None            # None=未知, True/False
        self.proposed_id = None
        self.record_ids = set()
        self.paths = {}             # 卡号 -> 首个登记路径，供主题查询定位
        self.ledger_ids = set()     # 现行总账与批次总账出现过的全部卡号（含失效登记）
        self.legacy_routes = {"change": set(), "task": set()}  # 现行总账中仍登记的归档卡
        self.dup_keys = {}          # 文件 -> 重名键计数；json 默认只保留最后一个，合并冲突时会静默吞掉登记

    # ---- 基础读取 ----
    def read_text(self, rel):
        if rel not in self._text_cache:
            p = self.root / rel
            self._text_cache[rel] = p.read_text(encoding="utf-8") if p.is_file() else None
        return self._text_cache[rel]

    def load_json(self, rel):
        if rel not in self._json_cache:
            p = self.root / rel
            if not p.exists():
                self._json_cache[rel] = None
            else:
                dups = {}

                def keep_last(pairs):
                    seen = set()
                    for key, _ in pairs:
                        if key in seen:
                            dups[key] = dups.get(key, 1) + 1
                        seen.add(key)
                    return dict(pairs)

                try:
                    data = json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=keep_last)
                    self.dup_keys[rel] = dups
                    if not isinstance(data, dict):
                        self.hard("JSON_TYPE", None, rel, "JSON 顶层必须为对象")
                        data = None
                    self._json_cache[rel] = data
                except Exception as e:  # noqa: BLE001
                    self.hard("JSON_PARSE", None, rel, "JSON 解析失败: %s" % e)
                    self._json_cache[rel] = None
        return self._json_cache[rel]

    def exists(self, rel):
        return (self.root / rel).is_file()

    def topics_in(self, rel):
        txt = self.read_text(rel)
        return set(TOPIC_RE.findall(txt)) if txt else set()

    def git_ok(self):
        if self._git is None:
            try:
                subprocess.run(["git", "rev-parse", "--is-inside-work-tree"],
                               cwd=self.root, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=True)
                self._git = True
            except Exception:  # noqa: BLE001
                self._git = False
        return self._git

    def git_out(self, *args):
        """只读 git 查询的标准输出；无 git 或命令失败返回 None。"""
        if not self.git_ok():
            return None
        try:
            r = subprocess.run(["git"] + list(args), cwd=self.root, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, universal_newlines=True)
        except Exception:  # noqa: BLE001
            return None
        return r.stdout if r.returncode == 0 else None

    def is_ancestor(self, commit):
        """commit 是否为 HEAD 祖先。True/False；无 git 返回 None。"""
        if not self.git_ok():
            return None
        if not commit:
            return False
        try:
            r = subprocess.run(["git", "merge-base", "--is-ancestor", str(commit), "HEAD"],
                               cwd=self.root, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            return r.returncode == 0
        except Exception:  # noqa: BLE001
            return None

    # ---- findings ----
    def add(self, sev, code, card, path, msg, hint=None):
        """唯一发出路径：注册表提供默认 hint，调用点可传更具体的一条覆盖。"""
        meta = CHECKS.get(code)
        self.findings.append({"sev": sev, "code": code, "card": card, "path": path, "msg": msg,
                              "hint": hint if hint is not None else (meta[2] if meta else "")})

    def hard(self, code, card, path, msg, hint=None):
        self.add("ERROR", code, card, path, msg, hint)

    def soft(self, code, card, path, msg, hint=None):
        self.add("WARN", code, card, path, msg, hint)

    def advisory(self, code, card, path, msg, hint=None):
        self.add("ADVISORY", code, card, path, msg, hint)


def is_readme(rel):
    return Path(rel).name.lower() == "readme.md"


def checks_of(card):
    """变更轨读 verification.checks，任务轨读 acceptance.checks。"""
    if isinstance(card.get("verification"), dict) and card["verification"].get("checks"):
        return card["verification"]["checks"]
    if isinstance(card.get("acceptance"), dict) and card["acceptance"].get("checks"):
        return card["acceptance"]["checks"]
    return []


def runid_ok(rid):
    rid = str(rid or "").strip()
    return bool(RUNID_RE.match(rid)) and "http" not in rid and "://" not in rid


def mentions(text, cid):
    """卡号整词出现：C001 不命中 C0011，HTML 注释中的语法示例不算互链。"""
    text = HTML_COMMENT_RE.sub("", text or "")
    return re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(cid), text) is not None


def norm_version(v):
    """发布批次比较忽略前导 v：`v0.1.0` 与 `0.1.0` 视为同一批次。"""
    return v.strip().lstrip("vV") if isinstance(v, str) else ""


def version_key(v):
    """取版本号开头的数字段用于比较先后（`0.12.0+` 视为 0.12.0）；末尾补零不影响比较，无法解析返回 None。"""
    m = re.match(r"\d+(?:\.\d+)*", norm_version(v))
    if not m:
        return None
    key = [int(p) for p in m.group(0).split(".")]
    while len(key) > 1 and key[-1] == 0:
        key.pop()
    return tuple(key)


def check_card_shape(ctx, card, cid, rel, full=True):
    """仅校验后续读取必需的类型；归档卡只读取身份和状态。"""
    valid = True

    def require(ok, field, kind):
        nonlocal valid
        if not ok:
            ctx.hard("JSON_TYPE", cid, rel, "%s 必须为%s" % (field, kind))
            valid = False

    require(isinstance(cid, str), "id", "字符串")
    require(isinstance(card.get("status"), str), "status", "字符串")
    if not full:
        return valid
    for field in ("target", "verification", "acceptance", "sync", "gate", "design"):
        value = card.get(field)
        require(value is None or isinstance(value, dict), field, "对象或 null")
        if isinstance(value, dict):
            for key in (("design_doc", "design_topic") if field == "target" else
                        ("doc",) if field == "design" else ()):
                require(value.get(key) is None or isinstance(value[key], str),
                        "%s.%s" % (field, key), "字符串或 null")
            if field in ("verification", "acceptance"):
                checks = value.get("checks")
                require(checks is None or (isinstance(checks, list) and
                        all(isinstance(c, dict) for c in checks)),
                        field + ".checks", "对象数组或 null")
    deps = card.get("depends_on")
    require(deps is None or (isinstance(deps, list) and all(isinstance(d, str) for d in deps)),
            "depends_on", "字符串数组或 null")
    for field in ("rejections", "changes", "tasks"):
        value = card.get(field)
        require(value is None or (isinstance(value, list) and
                all(isinstance(item, dict) for item in value)), field, "对象数组或 null")
    return valid


def check_status(ctx, card, cid, rel, track):
    status = card.get("status")
    if not isinstance(status, str) or status not in STATUSES[track]:
        ctx.hard("STATUS_INVALID", cid, rel, "%s 轨不支持状态 %r" % (track, status))


# ---- 单卡结构校验（与终态无关，任何 status 都查）----
def check_structural(ctx, card, cid, rel):
    t = card.get("target", {}) or {}
    doc = t.get("design_doc")
    topic = t.get("design_topic")

    # P1 设计挂接
    if not doc:
        ctx.hard("DESIGN_DOC_MISSING", cid, rel, "缺少 target.design_doc（文档先行：必须先挂接现行基线设计）")
    elif is_readme(doc):
        ctx.hard("NO_README_AS_DESIGN_DOC", cid, rel, "design_doc 指向 README: %s" % doc)
    elif not ctx.exists(doc):
        ctx.hard("DESIGN_DOC_MISSING", cid, rel, "设计文档不存在: %s" % doc)
    elif topic and topic not in ctx.topics_in(doc):
        ctx.hard("TOPIC_ANCHOR_MISSING", cid, rel, "@%s 锚标未出现在 %s" % (topic, doc))
    design_doc = (card.get("design") or {}).get("doc")
    if design_doc and is_readme(design_doc):
        ctx.hard("NO_README_AS_DESIGN_DOC", cid, rel, "design.doc 指向 README: %s" % design_doc)

    # P5 二值契约对称
    for c in checks_of(card):
        ti = str(c.get("true_if", "")).strip()
        fi = str(c.get("false_if", "")).strip()
        if not ti or not fi:
            ctx.hard("CONTRACT_INCOMPLETE", cid, rel, "checks[].true_if/false_if 不完整: %r" % c.get("item"))
        elif ti == fi:
            ctx.hard("CONTRACT_SYMMETRIC", cid, rel, "true_if 与 false_if 相同: %r" % c.get("item"))

    # P12 悬空依赖（任务卡，任何状态都查存在性）
    for dep in card.get("depends_on", []) or []:
        if dep not in ctx.all_ids:
            ctx.hard("DEP_DANGLING", cid, rel, "depends_on 引用了不存在的卡: %s" % dep)

    # P6 脱钩物理路径（软）
    def scan(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if k in PATH_KEYS:
                    vals = v if isinstance(v, list) else [v]
                    for s in vals:
                        if isinstance(s, str) and SRC_PATH_RE.search(s):
                            ctx.soft("DECOUPLING_VIOLATION", cid, rel,
                                     "卡片硬编码源码物理路径（应只声明 module/component/capability）: %s" % s)
                else:
                    scan(v)
        elif isinstance(obj, list):
            for v in obj:
                scan(v)
    scan(card)


# ---- 单卡终态前置（状态感知）----
def check_state(ctx, card, cid, rel, track):
    status = card.get("status")
    checks = checks_of(card)
    v = card.get("verification", {}) if isinstance(card.get("verification"), dict) else {}
    acc = card.get("acceptance", {}) if isinstance(card.get("acceptance"), dict) else {}
    run_id = v.get("run_id") or acc.get("run_id")
    quote = v.get("user_quote")
    signoff = v.get("signoff")

    if status in TERMINAL:
        if not runid_ok(run_id):
            ctx.hard("EVIDENCE_RUNID", cid, rel, "run_id 为空或含内网/非法格式: %r" % run_id)
        if track == "change":
            if not str(quote or "").strip():
                ctx.hard("EVIDENCE_QUOTE", cid, rel, "缺少人类原话 user_quote（严禁 AI 自导自演代签）")
            elif str(quote).strip().lower() in CANNED_QUOTES or len(str(quote).strip()) < MIN_QUOTE_LEN:
                ctx.soft("EVIDENCE_QUOTE_CANNED", cid, rel, "user_quote 疑似套话: %r" % quote)
            if not str(signoff or "").strip():
                ctx.hard("EVIDENCE_SIGNOFF", cid, rel, "缺少 signoff")
        if any(c.get("result") is None for c in checks):
            ctx.hard("CHECK_RESULT_MISSING", cid, rel, "存在 result 未裁决的验收项（二值契约必须落 true/false）")

    if status in CLOSED:
        # P8 commit 祖先
        commit = (card.get("sync", {}) or {}).get("commit")
        anc = ctx.is_ancestor(commit)
        if anc is None:
            ctx.soft("COMMIT_SKIPPED_NO_GIT", cid, rel, "无 git 环境，跳过 commit 祖先校验")
        elif not commit:
            ctx.hard("COMMIT_MISSING", cid, rel, "终态卡缺少 sync.commit")
        elif not anc:
            ctx.hard("COMMIT_NOT_ANCESTOR", cid, rel, "sync.commit 非 HEAD 祖先（疑伪造）: %s" % commit)
        # P9 CHANGELOG 互链（软）
        if status == "closed":
            if not mentions(ctx.read_text("CHANGELOG.md"), cid):
                ctx.soft("CHANGELOG_LINK_MISSING", cid, rel, "closed 卡号未出现在 CHANGELOG.md")
        # P12 前置闭环（任务卡 completed）
        if status == "completed":
            for dep in card.get("depends_on", []) or []:
                dc = ctx.all_ids.get(dep)
                if dc is not None and dc.get("status") != "completed":
                    ctx.hard("DEP_NOT_COMPLETED", cid, rel, "前置任务 %s 尚未 completed" % dep)

    if status == "rejected":
        rej = card.get("rejections") or []
        if not rej or any(not str(r.get("reason", "")).strip() for r in rej):
            ctx.hard("REJECTION_NO_AUDIT", cid, rel, "rejected 卡缺少含 reason 的驳回审计记录")

    # P13 hotfix 超期（软）
    if card.get("is_hotfix") and status in ("draft", "pending", "in_progress"):
        ctx.soft("HOTFIX_OPEN", cid, rel, "hotfix 卡仍未闭环，需在故障恢复后 24h 内补票")

    # P3 gate 追责 + 证伪
    if status in CLOSED and cid != ctx.proposed_id and cid not in ctx.record_ids:
        gate = card.get("gate", {}) or {}
        if gate.get("exit_code") != 0:
            ctx.hard("GATE_EXIT_NONZERO", cid, rel,
                     "终态卡未记录 adflow-verify gate.exit_code==0（收口前必须过门禁并回写）")


def check_card(ctx, card, cid, rel, track):
    before = len([f for f in ctx.findings if f["card"] == cid and f["sev"] == "ERROR"])
    check_structural(ctx, card, cid, rel)
    check_state(ctx, card, cid, rel, track)
    # gate 证伪：声称已过门禁但实测有硬违规 → 追责
    if (cid != ctx.proposed_id and cid not in ctx.record_ids and card.get("status") in CLOSED
            and (card.get("gate", {}) or {}).get("exit_code") == 0):
        after = [f for f in ctx.findings if f["card"] == cid and f["sev"] == "ERROR"]
        if len(after) > before:
            ctx.hard("GATE_CLAIM_CONTRADICTION", cid, rel,
                     "卡片声称 gate.exit_code==0，但实测存在硬违规（伪造/漏跑门禁）")


def check_legacy_templates(ctx):
    idx = ctx.load_json("docs/index.json") or {}
    if "standards" in idx:
        for legacy in (LEGACY_FILES["docs/standards/change-template.json"],
                       LEGACY_FILES["docs/standards/task-template.json"]):
            if ctx.exists(legacy):
                ctx.hard("LEGACY_TEMPLATE_EXISTS", None, legacy,
                         "已启用 standards 规范，旧模板 %s 必须删除" % legacy)


def same_milestone(a, b):
    """判断两个里程碑标签是否指同一里程碑（ID、标题或带后缀的标题）。

    只认整词边界（`-`、空格、括号），因此 `M1` 不会误匹配 `M10`。
    """
    a, b = str(a).strip(), str(b).strip()
    if not a or not b:
        return False
    if a == b:
        return True
    shorter, longer = (a, b) if len(a) <= len(b) else (b, a)
    return any(longer.startswith(shorter + sep) for sep in ("-", " ", "(", "（"))


def milestone_members(mid, milestone, reg):
    """解析里程碑的成员任务号。

    真实项目存在三种登记形态，任一形态都应能定位成员：
    1. 里程碑对象自带 `tasks` 成员清单（模板结构）；
    2. 任务登记的 `milestone` 字段填里程碑 ID；
    3. 任务登记的 `milestone` 字段填里程碑标题（可能带 “(已发版归档)” 一类后缀）。
    """
    aliases = {str(mid)}
    title = milestone.get("title")
    if isinstance(title, str) and title.strip():
        aliases.add(title.strip())
        stripped = re.sub(r"\s*[（(][^）)]*[）)]\s*$", "", title.strip())
        if stripped:
            aliases.add(stripped)
    members = set()
    listed = milestone.get("tasks")
    if isinstance(listed, list):
        members.update(str(t) for t in listed if isinstance(t, str))
    for cid, ent in reg.items():
        if not isinstance(ent, dict):
            continue
        label = ent.get("milestone")
        if isinstance(label, str) and any(same_milestone(label, a) for a in aliases):
            members.add(str(cid))
    return members


def check_milestones(ctx):
    """里程碑标记与成员任务状态矛盾时旁路观察，不提高硬门槛。"""
    idx_rel = "docs/devel/task/index.json"
    idx = ctx.load_json(idx_rel) or {}
    milestones = idx.get("milestones")
    if not isinstance(milestones, dict):
        return
    reg = idx.get("tasks", idx.get("cards", {}))
    if not isinstance(reg, dict):
        reg = {}
    for mid, m in milestones.items():
        # list 型里程碑（仅成员清单、无状态字段）没有可矛盾的状态标记，跳过。
        if not (isinstance(m, dict) and m.get("status") == "completed"):
            continue
        for cid in sorted(milestone_members(mid, m, reg)):
            ent = reg.get(cid)
            if (isinstance(ent, dict) and ent.get("status") is not None
                    and ent.get("status") != "completed"):
                ctx.advisory("MILESTONE_STATUS_DRIFT", cid, idx_rel,
                             "里程碑 %s 标记 completed，但该任务状态为 %r（里程碑须与成员卡对齐）"
                             % (mid, ent.get("status")))


# ---- 全局检查 ----
def check_design_routes(ctx):
    """设计文档机器路由：仅在 devel index 声明 designs 时生效，旧布局保持只读兼容。"""
    rel_idx = "docs/devel/index.json"
    idx = ctx.load_json(rel_idx)
    if not isinstance(idx, dict):
        return
    subsystems = idx.get("subsystems")
    if not isinstance(subsystems, list):
        return
    design = next((s for s in subsystems
                   if isinstance(s, dict) and s.get("name") == "design"), None)
    if not isinstance(design, dict) or "designs" not in design:
        return  # 旧布局或尚未建立机器路由：不追溯要求
    if not isinstance(design["designs"], list):
        ctx.advisory("DESIGN_ROUTE_DRIFT", None, rel_idx,
                     "design 子系统的 designs 必须为数组")
        return
    registered = {}
    for i, entry in enumerate(design["designs"]):
        if (not isinstance(entry, dict) or not isinstance(entry.get("file"), str)
                or not entry["file"].strip()):
            ctx.advisory("DESIGN_ROUTE_DRIFT", None, rel_idx,
                         "designs[%d] 必须含非空 file 路径" % i)
            continue
        rel = entry["file"]
        registered[rel] = entry
        if not ctx.exists(rel):
            ctx.advisory("DESIGN_ROUTE_DRIFT", None, rel_idx,
                         "designs[%d] 指向不存在的设计文档: %s" % (i, rel))
            continue
        topic = entry.get("topic")
        if topic is not None and not isinstance(topic, str):
            ctx.advisory("DESIGN_ROUTE_DRIFT", None, rel_idx,
                         "designs[%d].topic 必须为字符串" % i)
        elif topic and topic not in ctx.topics_in(rel):
            ctx.advisory("DESIGN_ROUTE_DRIFT", None, rel_idx,
                         "designs[%d] 主题 @%s 未出现在 %s" % (i, topic, rel))
    design_dir = ctx.root / "docs/devel/design"
    if design_dir.is_dir():
        for path in sorted(design_dir.glob("*.md")):
            if path.name == "README.md":
                continue
            rel = str(path.relative_to(ctx.root))
            if rel not in registered:
                ctx.advisory("DESIGN_ROUTE_DRIFT", None, rel,
                             "设计文档未登记到 docs/devel/index.json designs；"
                             "补齐 file/topic/status/title 或确认其为非基线草稿")


def check_globals(ctx):
    check_legacy_templates(ctx)
    check_milestones(ctx)
    # P11 零沉淀：todo 行内含已存在卡号
    for todo in ("docs/devel/todo/now.md", "docs/devel/todo/future.md"):
        txt = ctx.read_text(todo)
        if not txt:
            continue
        for i, line in enumerate(txt.splitlines(), 1):
            for m in CARD_ID_RE.findall(line):
                if m in ctx.all_ids:
                    ctx.hard("ZERO_SEDIMENT_VIOLATION", m, "%s:%d" % (todo, i),
                             "todo 残留已建卡事项 %s（落地建卡即应物理删除）" % m)

    check_version(ctx)

    # index.topics 的 design_doc 也不得指向 README / 必须存在 / 含锚标
    for idx_rel in ("docs/devel/change/index.json", "docs/devel/task/index.json"):
        data = ctx.load_json(idx_rel) or {}
        topics = data.get("topics", {})
        if not isinstance(topics, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics 必须为对象")
            continue
        for topic, tinfo in topics.items():
            if not isinstance(tinfo, dict):
                ctx.hard("JSON_TYPE", None, idx_rel, "topics[%s] 必须为对象" % topic)
                continue
            d = tinfo.get("design_doc")
            if not d:
                continue
            if not isinstance(d, str):
                ctx.hard("JSON_TYPE", None, idx_rel, "topics[%s].design_doc 必须为字符串" % topic)
            elif is_readme(d):
                ctx.hard("INDEX_TOPIC_README", None, idx_rel, "topics[%s].design_doc 指向 README: %s" % (topic, d))
            elif not ctx.exists(d):
                ctx.hard("DESIGN_DOC_MISSING", None, idx_rel, "topics[%s].design_doc 不存在: %s" % (topic, d))
            elif topic not in ctx.topics_in(d):
                ctx.hard("TOPIC_ANCHOR_MISSING", None, idx_rel, "topics[%s] 锚标未出现在 %s" % (topic, d))

    check_design_routes(ctx)


def check_version(ctx, required=False):
    # P14 版本一致；初始化还要求路由元数据明确声明版本。
    am = ctx.read_text("AGENTS.md") or ""
    tag = TAG_RE.search(am)
    idx = ctx.load_json("docs/index.json") or {}
    ver = idx.get("adflow_version")
    if not tag or not tag.group(1):
        ctx.hard("TAG_MISSING", None, "AGENTS.md", "缺少 <!-- @ad-flow: initialized vX.Y.Z --> 标签")
    if required and not ver:
        ctx.hard("VERSION_MISSING", None, "docs/index.json", "缺少 adflow_version")
    elif ver is not None and not isinstance(ver, str):
        ctx.hard("JSON_TYPE", None, "docs/index.json", "adflow_version 必须为字符串")
    elif tag and tag.group(1) and ver and tag.group(1) != ver:
        ctx.hard("VERSION_DRIFT", None, "AGENTS.md",
                 "AGENTS.md 标签 v%s 与 docs/index.json adflow_version=%s 不一致" % (tag.group(1), ver))
    # 只读首个标签；残留的旧标签会让技能的版本路由产生歧义，旁路提示清理。
    tagged = {v for v in TAG_COMMENT_RE.findall(am) if v}
    if len(tagged) > 1:
        ctx.advisory("TAG_DUPLICATE", None, "AGENTS.md",
                     "存在多个版本不同的初始化标签: %s（升级应只保留当前标签）"
                     % ", ".join("v" + v for v in sorted(tagged)))


def check_tool_version(ctx, ver):
    """已安装校验器副本须与治理版本一致，否则升级后项目仍在运行旧门禁。"""
    txt = ctx.read_text(TOOL_FILES[0])
    if txt is None or not isinstance(ver, str) or not ver:
        return
    m = TOOL_VERSION_RE.search(txt)
    tool_ver = m.group(1) if m else None
    if tool_ver != ver:
        ctx.hard("TOOL_VERSION_DRIFT", None, TOOL_FILES[0],
                 "校验器副本版本 %s 与 docs/index.json adflow_version=%s 不一致（升级须同步校验器副本）"
                 % (tool_ver or "未知", ver))


def check_placeholders(ctx):
    """模板占位符未渲染仅旁路提示：只看 JSON 元数据字段与 Markdown 文首元数据行。"""
    for rel, fields in PLACEHOLDER_FIELDS.items():
        data = ctx.load_json(rel) if ctx.exists(rel) else None
        left = [k for k in fields if isinstance(data, dict) and isinstance(data.get(k), str)
                and data[k] in PLACEHOLDER_VALUES]
        if left:
            ctx.advisory("PLACEHOLDER_UNRENDERED", None, rel, "模板占位符未渲染: %s" % ", ".join(left))
    for rel in BASE_FILES:
        if not rel.endswith(".md"):
            continue
        head = (ctx.read_text(rel) or "").splitlines()[:6]
        if any(("**created**" in line or "**last-change**" in line or "MyProject" in line)
               and any(p in line for p in PLACEHOLDER_VALUES) for line in head):
            ctx.advisory("PLACEHOLDER_UNRENDERED", None, rel, "文首元数据仍为模板占位符（项目名或日期）")


def check_archived_terminal(ctx, card, cid, rel, track):
    # 归档区只允许终态卡：这是 v1.1.0 起既有归档前置的机器覆盖，非新增追溯门槛。
    if card.get("status") in STATUSES[track] and card.get("status") not in CLOSED:
        ctx.hard("ARCHIVE_NON_TERMINAL", cid, rel,
                 "归档卡处于非终态 %r（归档前置：C 卡 closed / T 卡 completed；"
                 "历史冻结卡按归档 README「历史批次账实修复」人工处置）" % card.get("status"))


def scan_archive(ctx, routed):
    """物理扫描归档区：未经总账路由的卡同样只允许终态，未登记本身仅旁路提示。

    未登记卡与其他卡撞号时旁路提示（不进入依赖解析：依赖仍须经总账可达）。
    """
    base = ctx.root / "docs" / "archive"
    if not base.is_dir():
        return
    unrouted = {}  # 卡号 -> 首个未登记归档路径
    for jf in sorted(base.rglob("*.json")):
        rel = str(jf.relative_to(ctx.root))
        track = jf.parent.name
        if (track not in STATUSES or jf.name == "index.json" or rel in routed
                or len(Path(rel).parts) < 5):
            continue
        try:
            card = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001  总账快照、测试报告等非卡片资料不在本检查范围
            continue
        if not isinstance(card, dict):
            continue
        cid = card.get("id", jf.stem)
        # 卡号文件名或 id 可识别缺状态卡，报告等非卡片 JSON 仍跳过。
        if ("status" not in card and not CARD_ID_RE.fullmatch(jf.stem)
                and not (isinstance(cid, str) and CARD_ID_RE.fullmatch(cid))):
            continue
        if not check_card_shape(ctx, card, cid, rel, full=False):
            continue
        check_status(ctx, card, cid, rel, track)
        check_archived_terminal(ctx, card, cid, rel, track)
        if CARD_ID_RE.fullmatch(cid):
            first = ctx.paths.get(cid) if cid in ctx.all_ids else unrouted.get(cid)
            if first:
                ctx.advisory("ARCHIVE_ID_COLLISION", cid, rel,
                             "未登记的归档卡与 %s 撞号；依赖与主题判定无法区分两张卡，先修正卡号及引用" % first)
            else:
                unrouted[cid] = rel
        ctx.advisory("ARCHIVE_UNREGISTERED", cid, rel,
                     "归档卡未经现行总账或批次总账路由（缺登记或 file 未指向此处），依赖与主题查询不可达")


def ledger_cards(idx, track):
    # 任务模板使用 tasks；兼容已经使用 cards 的项目，不迁移其索引结构。
    return idx.get("tasks", idx.get("cards", {})) if track == "task" else idx.get("cards", {})


def batch_manifests(ctx):
    """归档批次总账：docs/archive/<批次>/index.json 且声明 adflow-archive-batch-v1。

    未声明该 schema 的批次根文件（如项目自建快照）不按清单解析，也不新增检查。
    """
    base = ctx.root / "docs" / "archive"
    if not base.is_dir():
        return []
    found = []
    for p in sorted(base.glob("*/index.json")):
        rel = str(p.relative_to(ctx.root))
        if BATCH_SCHEMA not in (ctx.read_text(rel) or ""):
            continue
        data = ctx.load_json(rel)
        if isinstance(data, dict) and data.get("$schema") == BATCH_SCHEMA:
            found.append(rel)
    return found


def check_duplicate_keys(ctx, idx_rel):
    """同一登记表内卡号重名：解析时只保留最后一条，另一张卡的登记被静默吞掉；先旁路观察，不新增阻断。"""
    for key, n in sorted((ctx.dup_keys.get(idx_rel) or {}).items()):
        if CARD_ID_RE.fullmatch(key):
            ctx.advisory("LEDGER_DUPLICATE_KEY", key, idx_rel,
                         "总账中卡号 %s 登记了 %d 次（JSON 重名键只保留最后一条，常见于合并冲突保留两侧登记）；"
                         "先修正卡号及引用" % (key, n))


def check_ledger_layout(ctx):
    """现行总账仍登记或引用归档卡时旁路提示瘦身；旧布局继续有效，不追溯阻断。"""
    archived = {cid for cid, rel in ctx.paths.items() if Path(rel).parts[:2] == ("docs", "archive")}
    for track in ("change", "task"):
        idx_rel = "docs/devel/%s/index.json" % track
        topics = (ctx.load_json(idx_rel) or {}).get("topics")
        refs = sum(1 for t in (topics.values() if isinstance(topics, dict) else [])
                   if isinstance(t, dict)
                   for key in TOPIC_KEYS.values() if isinstance(t.get(key), list)
                   for cid in t[key] if isinstance(cid, str) and cid in archived)
        entries = len(ctx.legacy_routes[track])
        if entries or refs:
            ctx.advisory("LEDGER_ARCHIVED_ENTRIES", None, idx_rel,
                         "现行总账仍登记 %d 张归档卡、%d 处主题引用归档卡；可按归档 README「现行总账瘦身」"
                         "迁入 docs/archive/<批次>/index.json（旧布局仍有效）" % (entries, refs))


# ---- 采集活跃卡 ----
def collect_cards(ctx):
    ctx.all_ids = {}
    ctx.entries = {}  # 卡号 -> 总账登记条目，供发版预检回退读取 version
    cards = []  # (rel, dict, cid)
    seen_paths = set()
    routed = set()  # 总账引用过的归档路径，物理扫描不重复报告

    def register(rel, card, cid, active):
        if rel in seen_paths:
            return
        seen_paths.add(rel)
        if cid in ctx.all_ids:
            ctx.hard("ID_DUPLICATE", cid, rel, "卡号重复；不可用后一张卡覆盖前一张卡进行依赖判定")
        else:
            ctx.all_ids[cid] = card
            ctx.paths[cid] = rel
        if active:
            cards.append((rel, card, cid))

    def route(idx_rel, track, cid, ent, batch=None):
        """核对一条登记并解析所指卡片；batch 为批次总账所在目录，其登记只能指向本批次轨道。"""
        ctx.ledger_ids.add(cid)
        if not isinstance(ent, dict):
            ctx.hard("JSON_TYPE", cid, idx_rel, "卡片登记条目必须为对象")
            return
        f = ent.get("file")
        if not isinstance(f, str) or not f.strip():
            ctx.hard("INDEX_FILE_MISSING", cid, idx_rel, "索引缺少非空 file 路径")
            return
        try:
            rel = str((ctx.root / f).resolve().relative_to(ctx.root))
        except ValueError:
            ctx.hard("INDEX_FILE_INVALID", cid, idx_rel, "索引 file 必须位于目标项目内: %s" % f)
            return
        archived = Path(rel).parts[:2] == ("docs", "archive")
        if archived:
            routed.add(rel)
            if batch is None:
                ctx.legacy_routes[track].add(cid)
        if batch is not None:
            if Path(rel).parent != Path(batch, track):
                ctx.hard("INDEX_FILE_INVALID", cid, idx_rel,
                         "批次总账 file 必须指向本批次 %s/%s/: %s" % (batch, track, f))
                return
        elif ((archived and (len(Path(rel).parts) < 5 or Path(rel).parent.name != track)) or
                (not archived and str(Path(rel).parent) != "docs/devel/" + track)):
            ctx.hard("INDEX_FILE_INVALID", cid, idx_rel,
                     "索引 file 必须指向所属活跃卡池或归档轨道: %s" % f)
            return
        if not ctx.exists(rel):
            ctx.hard("INDEX_FILE_DEAD", cid, idx_rel, "索引 file 路径失效: %s" % f)
            return
        card = ctx.load_json(rel)
        if card is None:
            return
        actual_id = card.get("id", Path(rel).stem)
        if not check_card_shape(ctx, card, actual_id, rel, full=not archived):
            return
        check_status(ctx, card, actual_id, rel, track)
        if archived:
            check_archived_terminal(ctx, card, actual_id, rel, track)
        if actual_id != cid:
            ctx.hard("INDEX_ID_DRIFT", cid, idx_rel,
                     "索引 %s 指向了身份为 %s 的卡片: %s" % (cid, actual_id, f))
            return
        if ent.get("status") != card.get("status"):
            ctx.hard("INDEX_STATUS_DRIFT", cid, idx_rel,
                     "索引状态 %r 与卡片 %r 不一致" % (ent.get("status"), card.get("status")))
        ctx.entries.setdefault(cid, ent)
        register(rel, card, cid, active=not archived)

    for sub in ("docs/devel/change", "docs/devel/task"):
        track = "task" if sub.endswith("/task") else "change"
        idx_rel = sub + "/index.json"
        if not ctx.exists(idx_rel):
            ctx.hard("INDEX_MISSING", None, idx_rel, "缺少卡片总账索引")
        idx = ctx.load_json(idx_rel) or {}
        check_duplicate_keys(ctx, idx_rel)
        reg = ledger_cards(idx, track)
        if not isinstance(reg, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "卡片登记表必须为对象")
            reg = {}
        # 总账是路由真理源：先核对每个登记，再解析归档卡供依赖判定。
        for cid, ent in reg.items():
            route(idx_rel, track, cid, ent)

        # 保留物理扫描，发现未登记、错误路由，以及与归档卡撞号的活跃卡。
        d = ctx.root / sub
        if not d.exists():
            continue
        for jf in sorted(d.glob("*.json")):
            if jf.name in ("index.json", "template.json"):
                continue
            rel = str(jf.relative_to(ctx.root))
            if rel in seen_paths:
                continue
            card = ctx.load_json(rel)
            if card is None:
                continue
            cid = card.get("id", jf.stem)
            if not check_card_shape(ctx, card, cid, rel):
                continue
            check_status(ctx, card, cid, rel, track)
            register(rel, card, cid, active=True)
            # P2 中枢对齐
            ent = reg.get(cid)
            if ent is None:
                ctx.hard("INDEX_MISSING_CARD", cid, rel, "卡片未登记到 %s" % idx_rel)
            elif isinstance(ent, dict):
                if ent.get("status") != card.get("status"):
                    ctx.hard("INDEX_STATUS_DRIFT", cid, idx_rel,
                             "索引状态 %r 与卡片 %r 不一致" % (ent.get("status"), card.get("status")))
                f = ent.get("file")
                if isinstance(f, str) and (ctx.root / f).resolve() != jf.resolve():
                    ctx.hard("INDEX_FILE_DRIFT", cid, idx_rel,
                             "索引 file 未指向该活跃卡: %s（实际 %s）" % (f, rel))

    # 归档批次总账与现行总账适用同一组路由检查，冻结路由由此参与撞号与依赖判定。
    for idx_rel in batch_manifests(ctx):
        data = ctx.load_json(idx_rel) or {}
        check_duplicate_keys(ctx, idx_rel)
        batch = str(Path(idx_rel).parent)
        for track, key in BATCH_KEYS.items():
            reg = data.get(key, {})
            if not isinstance(reg, dict):
                ctx.hard("JSON_TYPE", None, idx_rel, "%s 必须为对象" % key)
                continue
            for cid, ent in reg.items():
                route(idx_rel, track, cid, ent, batch)
        topics = data.get("topics", {})
        if not isinstance(topics, dict) or not all(
                isinstance(t, dict) and all(isinstance(t.get(k, []), list) and
                                            all(isinstance(i, str) for i in t.get(k, []))
                                            for k in TOPIC_KEYS.values())
                for t in topics.values()):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics 必须为 {主题: {changes: [卡号], tasks: [卡号]}}")
    scan_archive(ctx, routed)
    check_ledger_layout(ctx)
    return cards


def check_advisories(ctx, cards):
    """新增覆盖先旁路观察；不提高已有项目的硬门槛。"""
    task_cards = {}
    for rel, card, cid in cards:
        if not (card.get("target", {}) or {}).get("design_topic"):
            ctx.advisory("DESIGN_TOPIC_MISSING", cid, rel,
                         "未声明 target.design_topic；现有门禁通过不代表已检查主题挂接")
        if card.get("status") in TERMINAL:
            checks = checks_of(card)
            if not checks or any(c.get("result") is not True for c in checks):
                ctx.advisory("CHECKS_NOT_ALL_TRUE", cid, rel,
                             "验收项为空或未全部为 true；结构门禁不能替代业务验收")
        if "/devel/task/" in rel:
            task_cards[cid] = (rel, card)
            if card.get("status") in TERMINAL:
                # T 卡同样遵守“人工核验代签”；旧卡没有代签字段，只旁路提示，不追溯提高门槛。
                acc = card.get("acceptance") or {}
                if not str(acc.get("user_quote") or "").strip() or not str(acc.get("signoff") or "").strip():
                    ctx.advisory("TASK_SIGNOFF_MISSING", cid, rel,
                                 "completed 任务卡缺少 acceptance.user_quote 或 signoff"
                                 "（须在会话中取得人类明确确认后代签）")
                if any(t.get("done") is not True for t in card.get("tasks") or []):
                    ctx.advisory("TASKS_NOT_ALL_DONE", cid, rel,
                                 "completed 任务卡仍有 tasks[].done 不为 true 的能力单元")
            # 开工条件：前置任务均已 completed；缺失前置已由 DEP_DANGLING 硬阻断。
            if card.get("status") == "in_progress":
                for dep in card.get("depends_on", []) or []:
                    dc = ctx.all_ids.get(dep)
                    if dc is not None and dc.get("status") != "completed":
                        ctx.advisory("DEP_NOT_READY", cid, rel,
                                     "前置任务 %s 状态为 %r，本卡已 in_progress（应先完成前置再开工）"
                                     % (dep, dc.get("status")))
        else:
            # 驳回作废此前的确认：驳回卡不应保留原话，返工后的终态也不能沿用 gate 记录过的驳回前原话。
            quote = str((card.get("verification") or {}).get("user_quote") or "").strip()
            gate = card.get("gate") or {}
            signed = gate.get("signed_rejection_count")
            if quote and card.get("status") == "rejected":
                ctx.advisory("SIGNOFF_STALE", cid, rel,
                             "rejected 卡仍保留驳回前的 user_quote；应清空 user_quote/signoff，"
                             "返工后重新取得人工确认")
            elif (quote and card.get("status") in TERMINAL and isinstance(signed, int)
                  and len(card.get("rejections") or []) > signed and quote == gate.get("signed_quote")):
                ctx.advisory("SIGNOFF_STALE", cid, rel,
                             "user_quote 仍是驳回前已记录的确认原话；返工后须取得新的人工确认")

    visited, active, path = set(), set(), []

    def visit(cid):
        if cid in active:
            cycle = path[path.index(cid):] + [cid]
            ctx.advisory("DEP_CYCLE", cid, task_cards[cid][0],
                         "依赖出现环路: %s（建议修正；本版不新增硬阻断）" % " -> ".join(cycle))
            return
        if cid in visited:
            return
        active.add(cid)
        path.append(cid)
        for dep in task_cards[cid][1].get("depends_on", []) or []:
            if dep in task_cards:
                visit(dep)
        path.pop()
        active.remove(cid)
        visited.add(cid)

    for cid in sorted(task_cards):
        visit(cid)


def propose_state(ctx, cards, cid, status):
    """校验拟转入状态；原始卡片/索引保持不变，消除先置终态才能校验的循环。"""
    matches = [(i, rel, card) for i, (rel, card, found) in enumerate(cards) if found == cid]
    if len(matches) != 1:
        ctx.hard("TRANSITION_CARD", cid, "-", "目标卡必须唯一且存在于活跃卡池")
        return
    i, rel, card = matches[0]
    track = "change" if "/devel/change/" in rel else "task"
    if status not in TRANSITIONS[track]:
        ctx.hard("TRANSITION_STATE", cid, rel, "该轨不支持目标状态 %s" % status)
        return
    candidate = dict(card)
    candidate["status"] = status
    cards[i] = (rel, candidate, cid)
    ctx.all_ids[cid] = candidate
    ctx.proposed_id = cid


# ---- 发版预检 ----
def check_release(ctx, cards, release):
    """本批次活跃卡必须已到达本轨终态；归档区由 ARCHIVE_NON_TERMINAL 覆盖。

    卡片 version 缺失时回退读取总账登记；仍无法归属的未收口卡交人工划定批次。
    批次早于本次发布、却仍留在活跃区的终态卡不会被按版本精确匹配的归档带走，旁路提示人工处置。
    """
    target = norm_version(release)
    for rel, card, cid in cards:
        track = "change" if "/devel/change/" in rel else "task"
        version = norm_version(card.get("version")) or norm_version(
            (ctx.entries.get(cid) or {}).get("version"))
        if card.get("status") == TRACK_TERMINAL[track]:
            key, target_key = version_key(version), version_key(target)
            if version != target and key and target_key and key < target_key:
                ctx.advisory("RELEASE_STRANDED", cid, rel,
                             "终态卡批次 %s 早于本次发布 %s，仍滞留活跃区；确认是否随本批次归档"
                             "（卡片 version 保持原值）" % (version, release))
            continue
        if not version:
            ctx.soft("RELEASE_SCOPE_UNKNOWN", cid, rel,
                     "未收口卡未填写 version，无法判定是否属于 %s 批次（先补批次或显式延后）" % release)
        elif version == target:
            ctx.hard("RELEASE_NOT_TERMINAL", cid, rel,
                     "发布批次 %s 内的卡处于 %r（C 卡须 closed，T 卡须 completed）"
                     % (release, card.get("status")))
    in_batch = [cid for cid, card in ctx.all_ids.items()
                if target in (norm_version(card.get("version")),
                              norm_version((ctx.entries.get(cid) or {}).get("version")))]
    if not in_batch:
        ctx.advisory("RELEASE_BATCH_EMPTY", None, "-",
                     "未找到 version 为 %s 的卡片；核对版本拼写或确认本次发布确无卡片" % release)


# ---- 路由查询 ----
def card_stems(root, track):
    return {p.stem for pattern in ("docs/devel/%s/*.json" % track, "docs/archive/**/%s/*.json" % track)
            for p in root.glob(pattern)}


def next_id(ctx, track):
    """下一卡号：当前工作区、本机其他工作树与本地/远端跟踪分支中已出现的最大卡号 +1。

    只看得到本机可见的分支与工作树，仍不是原子预占；漏网的撞号由合入前校验的 ID_DUPLICATE 兜底。
    """
    prefix = ID_PREFIX[track]
    found = {}  # 卡号 -> 出现位置

    def note(ids, where):
        for i in ids:
            if CARD_ID_RE.fullmatch(i) and i[0] == prefix and where not in found.setdefault(i, []):
                found[i].append(where)

    note(set(ctx.all_ids) | ctx.ledger_ids | card_stems(ctx.root, track), HERE)
    scanned = {"branches": 0, "worktrees": 0}
    tips = {}
    for line in (ctx.git_out("for-each-ref", "--format=%(objectname)\t%(refname)",
                             "refs/heads", "refs/remotes") or "").splitlines():
        obj, _, ref = line.partition("\t")
        tips.setdefault(obj, ref)
    for obj, ref in sorted(tips.items(), key=lambda t: t[1]):
        out = ctx.git_out("ls-tree", "-r", "-z", "--name-only", obj, "--",
                          "docs/devel/" + track, "docs/archive")
        if out is not None:
            scanned["branches"] += 1
            note({Path(f).stem for f in out.split("\0") if f and Path(f).parent.name == track}, ref)
    # 其他工作树中尚未提交的卡片同样占号；项目可位于仓库子目录。
    sub = (ctx.git_out("rev-parse", "--show-prefix") or "").strip()
    for line in (ctx.git_out("worktree", "list", "--porcelain") or "").splitlines():
        if line.startswith("worktree "):
            root = (Path(line[len("worktree "):]) / sub).resolve()
            if root != ctx.root and root.is_dir():
                scanned["worktrees"] += 1
                note(card_stems(root, track), "工作树 %s" % root)

    top = max(found, key=lambda i: int(i[1:]), default=None)
    width = max([ID_WIDTH[track]] + [len(i) - 1 for i in found])
    nid = "%s%0*d" % (prefix, width, int(top[1:]) + 1 if top else 1)
    return nid, {"max": top, "found_in": found.get(top, []), "scanned": scanned}


def topic_history(ctx, cards, name):
    """主题历史：现行总账与批次总账的主题登记、登记条目 topic 及活跃卡 design_topic 的并集。"""
    members, docs = set(), []

    def take(topics, regs):
        entry = topics.get(name) if isinstance(topics, dict) else None
        if isinstance(entry, dict):
            doc = entry.get("design_doc")
            if isinstance(doc, str) and doc and doc not in docs:
                docs.append(doc)
            for key in TOPIC_KEYS.values():
                if isinstance(entry.get(key), list):
                    members.update(i for i in entry[key] if isinstance(i, str))
        for reg in regs:
            if isinstance(reg, dict):
                members.update(cid for cid, ent in reg.items()
                               if isinstance(ent, dict) and ent.get("topic") == name)

    for track in ("change", "task"):
        idx = ctx.load_json("docs/devel/%s/index.json" % track) or {}
        take(idx.get("topics"), [ledger_cards(idx, track)])
    for rel in batch_manifests(ctx):
        data = ctx.load_json(rel) or {}
        take(data.get("topics"), [data.get(key) for key in BATCH_KEYS.values()])
    members.update(cid for _, card, cid in cards
                   if (card.get("target") or {}).get("design_topic") == name)

    rows = []
    for cid in sorted(members, key=lambda i: (i[:1], int(i[1:]) if i[1:].isdigit() else 0, i)):
        card, ent = ctx.all_ids.get(cid) or {}, ctx.entries.get(cid) or {}
        rows.append({"id": cid, "status": card.get("status") or ent.get("status"),
                     "version": card.get("version") or ent.get("version"),
                     "title": card.get("title") or ent.get("title"), "file": ctx.paths.get(cid)})
    if not rows and not docs:
        ctx.advisory("TOPIC_EMPTY", None, "-", "未找到主题 %s 的登记或卡片；核对主题拼写" % name)
    lines = ["### 主题 %s · %s" % (name, " / ".join(docs) or "—"), "",
             "| 卡号 | 状态 | 批次 | 标题 | 路径 |", "|---|---|---|---|---|"]
    lines += ["| %s | %s | %s | %s | %s |" % (cell(r["id"]), cell(r["status"] or "缺失"),
                                             cell(r["version"]), cell(r["title"]), cell(r["file"]))
              for r in rows] or ["| （无卡片） | — | — | — | — |"]
    return {"name": name, "design_docs": docs, "cards": rows}, "\n".join(lines)


# ---- 主题查询范围（--topic --scope）----
def scoped_id_key(cid):
    return (cid[:1], int(cid[1:]) if cid[1:].isdigit() else 0, cid)


def ledger_rel(ctx, value):
    """总账 file 归一化为项目内相对路径；绝对路径、越界、反斜杠与空值返回 None。"""
    if not isinstance(value, str) or not value.strip() or "\\" in value:
        return None
    if Path(value).is_absolute():
        return None
    try:
        return str((ctx.root / value).resolve().relative_to(ctx.root))
    except ValueError:
        return None


def _topic_doc(ctx, tinfo, rel, name, docs):
    if not isinstance(tinfo, dict):
        return
    doc = tinfo.get("design_doc")
    if doc is None:
        return
    if not isinstance(doc, str):
        ctx.hard("JSON_TYPE", None, rel, "topics[%s].design_doc 必须为字符串" % name)
    elif doc and doc not in docs:
        docs.append(doc)


def _topic_members(tinfo, reg, name, key):
    members = set()
    if isinstance(tinfo, dict):
        for item in tinfo.get(key) or []:
            if isinstance(item, str):
                members.add(item)
    for cid, ent in reg.items():
        if isinstance(ent, dict) and ent.get("topic") == name:
            members.add(cid)
    return members


def _scoped_render(data):
    history = data["scope"] == "history"
    head = "### 主题 %s · %s · %s" % (
        data["name"], "历史卡" if history else "活跃卡",
        " / ".join(data["design_docs"]) or "—")
    if history:
        lines = [head, "", "| 卡号 | 状态 | 版本 | 归档批次 | 标题 | 路径 |",
                 "|---|---|---|---|---|---|"]
        lines += ["| %s | %s | %s | %s | %s | %s |" % (
            cell(r["id"]), cell(r.get("status")), cell(r.get("version")), cell(r.get("batch")),
            cell(r.get("title")), cell(r["file"])) for r in data["cards"]]
        empty = "| （无卡片） | — | — | — | — | — |"
    else:
        lines = [head, "", "| 卡号 | 状态 | 批次 | 标题 | 路径 |", "|---|---|---|---|---|"]
        lines += ["| %s | %s | %s | %s | %s |" % (
            cell(r["id"]), cell(r.get("status")), cell(r.get("version")),
            cell(r.get("title")), cell(r["file"])) for r in data["cards"]]
        empty = "| （无卡片） | — | — | — | — |"
    if not data["cards"]:
        lines.append(empty)
    return "\n".join(lines)


def _scoped_payload(ctx, name, scope, docs, rows):
    cards = sorted(rows, key=lambda r: scoped_id_key(r["id"]))
    if not cards and not docs:
        ctx.advisory("TOPIC_EMPTY", None, "-", "未找到主题 %s 的登记或卡片；核对主题拼写" % name)
    data = {"name": name, "scope": scope, "design_docs": docs, "cards": cards}
    return data, _scoped_render(data)


def query_active_topic(ctx, name):
    """活跃卡查询：只读两份现行总账及活跃卡实体，不发现、遍历或读取归档区。"""
    rows, docs, by_id = [], [], {}
    for track in ("change", "task"):
        idx_rel = "docs/devel/%s/index.json" % track
        if not ctx.exists(idx_rel):
            ctx.hard("INDEX_MISSING", None, idx_rel, "缺少卡片总账索引")
            continue
        idx = ctx.load_json(idx_rel)
        if not isinstance(idx, dict):
            continue
        check_duplicate_keys(ctx, idx_rel)
        topics = idx.get("topics")
        if topics is None:
            topics = {}
        if not isinstance(topics, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics 必须为对象")
            topics = {}
        tinfo = topics.get(name)
        if tinfo is not None and not isinstance(tinfo, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics[%s] 必须为对象" % name)
        _topic_doc(ctx, tinfo, idx_rel, name, docs)
        reg = ledger_cards(idx, track)
        if not isinstance(reg, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "卡片登记表必须为对象")
            continue
        for cid in sorted(_topic_members(tinfo, reg, name, TOPIC_KEYS[track]), key=scoped_id_key):
            ent = reg.get(cid)
            if not isinstance(ent, dict):
                ctx.hard("INDEX_MISSING_CARD", cid, idx_rel, "卡片未登记到 %s" % idx_rel)
                continue
            f = ent.get("file")
            if not isinstance(f, str) or not f.strip():
                ctx.hard("INDEX_FILE_MISSING", cid, idx_rel, "索引缺少非空 file 路径")
                continue
            rel = ledger_rel(ctx, f)
            if rel is None:
                ctx.hard("INDEX_FILE_INVALID", cid, idx_rel, "索引 file 必须位于目标项目内: %s" % f)
                continue
            parts = Path(rel).parts
            if parts[:2] == ("docs", "archive"):
                continue  # 旧总账保留的归档登记不属于活跃结果
            if len(parts) != 4 or parts[:2] != ("docs", "devel") or parts[2] != track:
                ctx.hard("INDEX_FILE_INVALID", cid, idx_rel,
                         "索引 file 必须指向所属活跃卡池: %s" % f)
                continue
            if not ctx.exists(rel):
                ctx.hard("INDEX_FILE_DEAD", cid, idx_rel, "索引 file 路径失效: %s" % f)
                continue
            card = ctx.load_json(rel)
            if not isinstance(card, dict):
                continue
            actual = card.get("id", Path(rel).stem)
            if actual != cid:
                ctx.hard("INDEX_ID_DRIFT", cid, idx_rel,
                         "索引 %s 指向了身份为 %s 的卡片: %s" % (cid, actual, f))
                continue
            if ent.get("status") != card.get("status"):
                ctx.hard("INDEX_STATUS_DRIFT", cid, idx_rel,
                         "索引状态 %r 与卡片 %r 不一致" % (ent.get("status"), card.get("status")))
            prev = by_id.get(cid)
            if prev is not None:
                if prev["file"] != rel:
                    ctx.hard("ID_DUPLICATE", cid, idx_rel,
                             "同一卡号指向不同活跃路径: %s 与 %s" % (prev["file"], rel))
                continue
            row = {"id": cid, "status": card.get("status"), "version": card.get("version"),
                   "title": card.get("title"), "file": rel}
            by_id[cid] = row
            rows.append(row)
    return _scoped_payload(ctx, name, "active", docs, rows)


def query_history_topic(ctx, name):
    """历史卡查询：只读批次总账与旧布局归档登记，不读取归档卡正文。"""
    rows, docs, seen = [], [], {}

    def add_row(cid, ent, track, batch, batch_dir, idx_rel):
        f = ent.get("file")
        if not isinstance(f, str) or not f.strip():
            ctx.hard("INDEX_FILE_MISSING", cid, idx_rel, "索引缺少非空 file 路径")
            return
        rel = ledger_rel(ctx, f)
        if rel is None:
            ctx.hard("INDEX_FILE_INVALID", cid, idx_rel, "索引 file 必须位于目标项目内: %s" % f)
            return
        parts = Path(rel).parts
        if (len(parts) != 5 or parts[:2] != ("docs", "archive")
                or parts[2] != batch_dir or parts[3] != track):
            ctx.hard("INDEX_FILE_INVALID", cid, idx_rel,
                     "索引 file 必须指向本批次 %s/%s/: %s" % (batch_dir, track, f))
            return
        if not ctx.exists(rel):
            ctx.hard("INDEX_FILE_DEAD", cid, idx_rel, "索引 file 路径失效: %s" % f)
            return
        prev = seen.get(cid)
        if prev is not None:
            if prev != rel:
                ctx.hard("ID_DUPLICATE", cid, idx_rel,
                         "同一卡号指向不同归档路径: %s 与 %s" % (prev, rel))
            return
        seen[cid] = rel
        rows.append({"id": cid, "status": ent.get("status"), "version": ent.get("version"),
                     "title": ent.get("title"), "batch": batch, "file": rel})

    for idx_rel in batch_manifests(ctx):
        data = ctx.load_json(idx_rel)
        if not isinstance(data, dict):
            continue
        check_duplicate_keys(ctx, idx_rel)
        batch_dir = Path(idx_rel).parent.name
        release = data.get("release")
        batch = release if isinstance(release, str) and release.strip() else batch_dir
        topics = data.get("topics")
        if topics is None:
            topics = {}
        if not isinstance(topics, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics 必须为对象")
            topics = {}
        tinfo = topics.get(name)
        if tinfo is not None and not isinstance(tinfo, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics[%s] 必须为对象" % name)
        _topic_doc(ctx, tinfo, idx_rel, name, docs)
        for track, key in BATCH_KEYS.items():
            reg = data.get(key)
            if reg is None:
                reg = {}
            if not isinstance(reg, dict):
                ctx.hard("JSON_TYPE", None, idx_rel, "%s 必须为对象" % key)
                continue
            for cid in sorted(_topic_members(tinfo, reg, name, TOPIC_KEYS[track]),
                              key=scoped_id_key):
                ent = reg.get(cid)
                if not isinstance(ent, dict):
                    ctx.hard("INDEX_MISSING_CARD", cid, idx_rel, "卡片未登记到 %s" % idx_rel)
                    continue
                add_row(cid, ent, track, batch, batch_dir, idx_rel)

    for track in ("change", "task"):
        idx_rel = "docs/devel/%s/index.json" % track
        if not ctx.exists(idx_rel):
            ctx.hard("INDEX_MISSING", None, idx_rel, "缺少卡片总账索引")
            continue
        idx = ctx.load_json(idx_rel)
        if not isinstance(idx, dict):
            continue
        check_duplicate_keys(ctx, idx_rel)
        topics = idx.get("topics")
        if topics is None:
            topics = {}
        if not isinstance(topics, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics 必须为对象")
            topics = {}
        tinfo = topics.get(name)
        if tinfo is not None and not isinstance(tinfo, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "topics[%s] 必须为对象" % name)
        _topic_doc(ctx, tinfo, idx_rel, name, docs)
        reg = ledger_cards(idx, track)
        if not isinstance(reg, dict):
            ctx.hard("JSON_TYPE", None, idx_rel, "卡片登记表必须为对象")
            continue
        for cid in sorted(_topic_members(tinfo, reg, name, TOPIC_KEYS[track]), key=scoped_id_key):
            ent = reg.get(cid)
            if not isinstance(ent, dict):
                ctx.hard("INDEX_MISSING_CARD", cid, idx_rel, "卡片未登记到 %s" % idx_rel)
                continue
            f = ent.get("file")
            rel = ledger_rel(ctx, f) if isinstance(f, str) else None
            if rel is None:
                ctx.hard("INDEX_FILE_INVALID", cid, idx_rel, "索引 file 必须位于目标项目内: %s" % f)
                continue
            parts = Path(rel).parts
            if parts[:2] != ("docs", "archive"):
                continue  # 活跃卡不属于历史结果
            if len(parts) != 5 or parts[3] != track:
                ctx.hard("INDEX_FILE_INVALID", cid, idx_rel,
                         "索引 file 必须指向归档轨道: %s" % f)
                continue
            add_row(cid, ent, track, parts[2], parts[2], idx_rel)
    return _scoped_payload(ctx, name, "history", docs, rows)


def scoped_topic_query(ctx, name, scope):
    return query_active_topic(ctx, name) if scope == "active" else query_history_topic(ctx, name)


# ---- 建卡只读计划（A6）----
SCAFFOLD_TRACK_KEY = {"change": "cards", "task": "tasks"}
SCAFFOLD_TOPIC_KEY = {"change": "changes", "task": "tasks"}
SCAFFOLD_TEMPLATE = {"change": "change_template", "task": "task_template"}
SCAFFOLD_REQUIRED = (("design_topic", "设计主题"), ("title", "标题"),
                     ("card_version", "发布批次"), ("branch", "执行分支"))


def scaffold_design_issue(ctx, doc, topic):
    if is_readme(doc):
        return "README 不能作为设计正文"
    if not ctx.exists(doc):
        return "文件不存在"
    rel = ledger_rel(ctx, doc)
    if rel is None:
        return "须使用 docs/devel/design/ 下的 Markdown 正文相对路径"
    path = Path(rel)
    if is_readme(path):
        return "README 不能作为设计正文"
    if path.parts[:3] != ("docs", "devel", "design") or path.suffix.lower() != ".md":
        return "须使用 docs/devel/design/ 下的 Markdown 正文相对路径"
    if topic not in ctx.topics_in(rel):
        return "缺少 @%s 锚标" % topic
    return None


def scaffold_plan(ctx, args):
    """只读建卡计划：给出确定性写入差异与缺失输入；不写文件。

    卡号遵循 --next-id 的取号规则。Agent 核对计划后按建卡 SOP 落盘并复核。
    """
    track = args.track or "change"
    card_id, basis = next_id(ctx, track)
    template = STANDARD_FILES[SCAFFOLD_TEMPLATE[track]]
    index_rel = "docs/devel/%s/index.json" % track
    card_rel = "docs/devel/%s/%s.json" % (track, card_id)
    missing = [label for name, label in SCAFFOLD_REQUIRED if not getattr(args, name)]

    design_doc, anchor_ok = args.design_doc, None
    if args.design_topic:
        if design_doc:
            issue = scaffold_design_issue(ctx, design_doc, args.design_topic)
            anchor_ok = issue is None
            if issue:
                missing.append("design_doc（%s）" % issue)
        else:
            for path in sorted((ctx.root / "docs/devel/design").glob("*.md")):
                rel = str(path.relative_to(ctx.root))
                if scaffold_design_issue(ctx, rel, args.design_topic) is None:
                    design_doc, anchor_ok = rel, True
                    break
            if design_doc is None:
                missing.append("design_doc（主题 %s 未在现行设计正文中命中）" % args.design_topic)

    tpl = ctx.load_json(template)
    if not isinstance(tpl, dict):
        missing.append("模板（%s 不存在或不可解析）" % template)
        tpl = {}
    card = copy.deepcopy(tpl)
    card["id"] = card_id
    card["status"] = card.get("status") or ("draft" if track == "change" else "pending")
    if args.title:
        card["title"] = args.title
    if args.card_version:
        card["version"] = args.card_version
    if args.branch:
        card["branch"] = args.branch
    if args.design_topic:
        target = card.get("target")
        if not isinstance(target, dict):
            target = card["target"] = {}
        target["design_topic"] = args.design_topic
        if design_doc:
            target["design_doc"] = design_doc
    if track == "change" and isinstance(card.get("design"), dict):
        if args.design_topic:
            card["design"]["topic"] = args.design_topic
        if design_doc:
            card["design"]["doc"] = design_doc
    if track == "task" and args.milestone:
        card["milestone"] = args.milestone

    index = ctx.load_json(index_rel)
    key = SCAFFOLD_TRACK_KEY[track]
    if isinstance(index, dict) and key not in index and "cards" in index:
        key = "cards"  # 兼容旧布局的 cards 键
    writes = [
        {"path": card_rel, "action": "create", "content": card},
        {"path": index_rel, "action": "upsert", "collection": key,
         "entry": {card_id: {"status": card.get("status"), "file": card_rel}}},
    ]
    topics = None
    if args.design_topic:
        topics = {"path": index_rel, "action": "append", "topic": args.design_topic,
                  "key": SCAFFOLD_TOPIC_KEY[track], "card": card_id}
    todo = None
    if args.todo:
        todo_path = "docs/devel/todo/%s.md" % ("now" if track == "change" else "future")
        present = args.todo in (ctx.read_text(todo_path) or "")
        todo = {"path": todo_path, "action": "remove", "match": args.todo, "present": present}
        if not present:
            missing.append("todo（未在 %s 匹配到给定文本）" % todo_path)

    data = {"action": "new-card", "track": track, "card_id": card_id,
            "next_id_basis": basis, "template": template,
            "design": {"doc": design_doc, "topic": args.design_topic, "anchor_ok": anchor_ok},
            "writes": writes, "topics": topics, "todo": todo,
            "milestone": args.milestone if track == "task" else None,
            "missing": missing, "executable": not missing}

    basis_text = ("当前最大 %s 位于 %s" % (basis["max"], "、".join(basis["found_in"]))
                  if basis.get("max") else "未发现既有卡号")
    lines = ["scaffold new-card  track=%s  card=%s  executable=%s"
             % (track, card_id, "yes" if data["executable"] else "no"),
             "取号：%s（%s；本机可见分支 %d / 工作树 %d，不构成原子预占）"
             % (card_id, basis_text, basis["scanned"]["branches"], basis["scanned"]["worktrees"]),
             "模板：%s" % template,
             "设计：%s @%s %s" % (design_doc or "未确定", args.design_topic or "未指定",
                                "✓" if anchor_ok else "✗" if anchor_ok is False else "—"),
             "写入计划（未落盘）："]
    lines += ["  %s %s" % (w["action"], w["path"]) for w in writes]
    if topics:
        lines.append("  append %s topics.%s.%s += %s"
                     % (topics["path"], topics["topic"], topics["key"], card_id))
    if todo:
        lines.append("  remove %s: %s（%s）" % (todo["path"], todo["match"],
                                               "已匹配" if todo["present"] else "未匹配"))
    if track == "task":
        lines.append("  里程碑：%s" % (args.milestone or "未指定"))
    lines.append("缺少输入：%s" % ("、".join(missing) or "无"))
    lines.append("说明：计划只读。核对建议卡号与拟变更后，按建卡 SOP 落盘并复核。")
    return data, "\n".join(lines)


# ---- 初始化 DoD ----
def run_init(ctx):
    def require_file(f, allow_legacy=False):
        if allow_legacy and not ctx.exists(f) and ctx.exists(LEGACY_FILES.get(f, f)):
            f = LEGACY_FILES[f]
        if not ctx.exists(f):
            ctx.hard("BASE_FILE_MISSING", None, f, "缺少基础治理文件或已登记规范")
        elif f.endswith(".json"):
            ctx.load_json(f)

    for f in BASE_FILES + TOOL_FILES:
        require_file(f, allow_legacy=True)
    docs_index = ctx.load_json("docs/index.json") or {}
    devel_index = ctx.load_json("docs/devel/index.json") or {}
    if "standards" in docs_index:
        routes = docs_index["standards"]
        if not isinstance(routes, dict):
            ctx.hard("STANDARD_ROUTE", None, "docs/index.json", "standards 必须为对象")
            routes = {}
        for key, rel in STANDARD_FILES.items():
            if routes.get(key) != rel:
                ctx.hard("STANDARD_ROUTE", None, "docs/index.json", "规范路径不匹配: %s" % key)
            require_file(rel)
    else:
        for key in ("task_template", "change_template"):
            require_file(STANDARD_FILES[key], allow_legacy=True)
        legacy_coding = LEGACY_FILES[STANDARD_FILES["coding"]]
        if devel_index.get("coding_standards") == legacy_coding:
            require_file(legacy_coding)
    # Even unregistered policy documents must be readable; never rewrite their contents.
    for rel in (STANDARD_FILES["coding"], LEGACY_FILES[STANDARD_FILES["coding"]]):
        if ctx.exists(rel):
            ctx.load_json(rel)
    if ctx.exists(PLACEHOLDER):
        ctx.hard("PLACEHOLDER_DESIGN_EXISTS", None, PLACEHOLDER, "存在禁用占位设计文档")
    check_legacy_templates(ctx)
    check_version(ctx, required=True)
    check_tool_version(ctx, docs_index.get("adflow_version"))
    check_placeholders(ctx)


# ---- --record：把本次真实结果回写进卡片 gate 块 ----
def record_gates(ctx, cards, selected=None):
    # 全局/其他卡违规同样阻断本次完整门禁，不把局部无错误伪装成整体通过。
    _, _, code = summarize(ctx)
    for rel, card, cid in cards:
        if selected is not None and cid != selected:
            continue
        p = ctx.root / rel
        # 重新读取实际卡片，候选状态只用于校验，不能随 gate 回写落盘。
        actual = json.loads(p.read_text(encoding="utf-8"))
        prev = actual.get("gate") if isinstance(actual.get("gate"), dict) else {}
        gate = {"tool": "adflow-verify", "version": VERSION,
                "ran_at": date.today().isoformat(), "exit_code": code}
        if cid == ctx.proposed_id:
            # 同时记下预检时的真实状态，回执据此显示 from → to，不靠推断。
            gate["from_status"] = actual.get("status")
            gate["target_status"] = card["status"]
        # 代签指纹：记下本次依据的确认原话与当时的驳回次数，供驳回后识别沿用旧原话。
        # 已判定过期时保留旧指纹，SIGNOFF_STALE 持续可见，直到写入新的确认原话。
        signature = {k: prev[k] for k in ("signed_quote", "signed_rejection_count") if k in prev}
        quote = str((actual.get("verification") or {}).get("user_quote") or "").strip()
        stale = any(f["code"] == "SIGNOFF_STALE" and f["card"] == cid for f in ctx.findings)
        if "/devel/change/" in rel and quote and not stale:
            signature = {"signed_quote": quote,
                         "signed_rejection_count": len(actual.get("rejections") or [])}
        gate.update(signature)
        actual["gate"] = gate
        p.write_text(json.dumps(actual, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


# ---- --receipt：按固定格式输出卡片节点回执 ----
RECEIPT_TODO = {
    "未覆盖": "〈执行者填写：未验证的运行态、人工验收缺口或残余风险；没有写“无”〉",
    "需要你": "〈执行者填写：需要人类确认、授权或决策的事项；没有写“无”〉",
}


def cell(value):
    """单行文本：折叠换行、转义表格竖线，空值显示为 —。"""
    text = " ".join(str(value).split()) if value not in (None, "") else ""
    return text.replace("|", "\\|") or "—"


def mark(result):
    return "✓" if result is True else ("✗" if result is False else "待定")


def issue_summary(ctx, cid):
    """按严重度聚合问题码；与本卡相关的码加 [本卡] 标注。ADVISORY 段始终输出。"""
    parts = []
    for sev in ("ERROR", "WARN", "ADVISORY"):
        counts, own = {}, set()
        for f in ctx.findings:
            if f["sev"] == sev:
                counts[f["code"]] = counts.get(f["code"], 0) + 1
                if f["card"] == cid:
                    own.add(f["code"])
        items = []
        for code, n in sorted(counts.items()):
            tag = ("[本卡]" if n == 1 else "[含本卡]") if code in own else ""
            items.append("%s%s%s" % (code, "×%d" % n if n > 1 else "", tag))
        if items or sev == "ADVISORY":
            parts.append("%s %s" % (sev, ", ".join(items) or "无"))
    return " · ".join(parts)


def render_receipt(ctx, card, cid, rel, track, code):
    """事实行全部取自卡片与本次复核；执行者只替换「未覆盖」「需要你」两行。"""
    gate = card.get("gate") if isinstance(card.get("gate"), dict) else {}
    status = card.get("status")
    head = status
    if gate.get("from_status") and gate.get("target_status") == status:
        head = "%s → %s" % (gate["from_status"], status)
    target = card.get("target") or {}
    doc = target.get("design_doc")
    proof = card.get("verification" if track == "change" else "acceptance")
    proof = proof if isinstance(proof, dict) else {}
    sync = card.get("sync") if isinstance(card.get("sync"), dict) else {}

    lines = ["### %s · %s · %s" % (cid, cell(card.get("title")), cell(head)),
             "批次 %s · 分支 %s · 设计 %s @%s" % (
                 cell(card.get("version")), cell(card.get("branch")),
                 cell(Path(doc).name if isinstance(doc, str) and doc else None),
                 cell(target.get("design_topic"))),
             "", "| 验收项 | 结果 | 证据 |", "|---|---|---|"]
    checks = checks_of(card)
    lines += ["| %s | %s | %s |" % (cell(c.get("item")), mark(c.get("result")), cell(c.get("evidence")))
              for c in checks] or ["| （未定义验收项） | — | — |"]
    lines.append("")

    gate_bits = ["复核 Exit %d" % code]
    if gate.get("exit_code") is not None:
        gate_bits.append("gate 记录 Exit %s（%s）" % (gate.get("exit_code"), cell(gate.get("ran_at"))))
    gate_bits += ["run_id %s" % cell(proof.get("run_id")), issue_summary(ctx, cid)]
    lines.append("- 门禁：" + " · ".join(gate_bits))

    # 收口前尚未到期的同步项显示“待…”，收口后仍缺失才显示为缺口。
    done = status in CLOSED
    commit = str(sync.get("commit") or "")
    if re.fullmatch(r"[0-9a-f]{8,40}", commit):
        commit = commit[:7]
    sync_bits = ["commit %s" % (cell(commit) if commit else "缺失" if done else "待回填")]
    quote = str(proof.get("user_quote") or "").strip()
    if status == "rejected":
        human = "已驳回，返工后重新请求确认"
    elif quote:
        human = "「%s」— %s" % (cell(quote), cell(proof.get("signoff")))
    else:
        human = "待人工确认"
    if track == "change":
        logged = mentions(ctx.read_text("CHANGELOG.md"), cid)
        sync_bits.append("CHANGELOG %s" % ("✓" if logged else "未登记" if done else "待登记"))
        design = card.get("design") if isinstance(card.get("design"), dict) else {}
        sync_bits.append("设计回写 %s" % ("不涉及" if design.get("modified") is False else
                                        "✓" if sync.get("design_pinned") is True else
                                        "未回写" if done else "待回写"))
        changes = [c.get("after") for c in card.get("changes") or [] if isinstance(c, dict) and c.get("after")]
        delta = "；".join(cell(a) for a in changes) or "（卡片未填写 changes）"
    else:
        deps = []
        for dep in card.get("depends_on") or []:
            dc = ctx.all_ids.get(dep)
            state = (dc or {}).get("status")
            deps.append("%s %s" % (dep, "✓" if state == "completed" else cell(state or "缺失")))
        sync_bits.append("依赖 %s" % (", ".join(deps) or "无"))
        tasks = [t for t in card.get("tasks") or [] if isinstance(t, dict)]
        delta = "；".join("%s %s %s" % (cell(t.get("id")), cell(t.get("title")), mark(t.get("done")))
                         for t in tasks) or "（卡片未填写 tasks）"
    lines.append("- 同步：" + " · ".join(sync_bits))
    lines.append("- 人工：" + human)
    rejections = [r for r in card.get("rejections") or [] if isinstance(r, dict)]
    if rejections:
        last = rejections[-1]
        lines.append("- 驳回：共 %d 次，最近 %s：%s" % (len(rejections), cell(last.get("date")),
                                               cell(last.get("reason"))))
    lines.append("- 改动：" + delta)
    lines += ["- %s：%s" % item for item in RECEIPT_TODO.items()]
    return "\n".join(lines)


# ---- 报告 ----
def summarize(ctx):
    errs = [f for f in ctx.findings if f["sev"] == "ERROR"]
    warns = [f for f in ctx.findings if f["sev"] == "WARN"]
    code = 4 if errs else (6 if warns else 0)
    return errs, warns, code


def code_counts(findings):
    """按诊断码汇总最终 findings 的级别计数；供 --json summary.codes 使用。"""
    out = {}
    for f in findings:
        bucket = out.setdefault(f["code"], {})
        bucket[f["sev"]] = bucket.get(f["sev"], 0) + 1
    return {code: dict(sorted(out[code].items())) for code in sorted(out)}


def report(ctx, mode, as_json, warn_only, release=None, payload=None):
    """payload=(JSON 字段, 文本, 提示)：回执与路由查询在文本模式只输出文本本身，便于原样转交或取用。"""
    errs, warns, code = summarize(ctx)
    if warn_only:
        for f in ctx.findings:
            if f["sev"] == "ERROR":
                f["sev"] = "WARN"
        errs, warns, code = summarize(ctx)
    advisories = [f for f in ctx.findings if f["sev"] == "ADVISORY"]
    if as_json:
        out = {"tool": "adflow-verify", "version": VERSION, "mode": mode,
               "target": str(ctx.root), "exit_code": code,
               "summary": {"errors": len(errs), "warnings": len(warns),
                           "advisories": len(advisories), "codes": code_counts(ctx.findings)},
               "findings": ctx.findings}
        if release:
            out["release"] = release
        if payload:
            out.update(payload[0])
        print(json.dumps(out, ensure_ascii=False, indent=2))
    elif payload:
        # 问题明细用 --json 查看；回执自带复核退出码，查询结果另在 stderr 提示非零复核。
        print(payload[1])
        for note in payload[2]:
            print("adflow-verify: " + note, file=sys.stderr)
        if code and "receipt" not in payload[0]:
            print("adflow-verify: 普通复核 Exit %d，问题明细见 --json" % code, file=sys.stderr)
    else:
        print("adflow-verify v%s  mode=%s%s  target=%s"
              % (VERSION, mode, "  release=%s" % release if release else "", ctx.root))
        for f in ctx.findings:
            loc = f["path"] if f["card"] in (None, "-") else "%s [%s]" % (f["path"], f["card"])
            print("  [%s] %-24s %s: %s" % (f["sev"], f["code"], loc, f["msg"]))
            if f.get("hint"):
                print("      ↳ 修复: %s" % f["hint"])
        print("summary: %d error(s), %d warning(s), %d advisory item(s)" %
              (len(errs), len(warns), len(advisories)))
        print("exit code: %d" % code)
    return code


def main(argv=None):
    ap = argparse.ArgumentParser(description="ad-flow 流程纪律可执行校验层（方案 W）")
    ap.add_argument("target_dir", nargs="?", default=".", help="目标工程根目录，默认当前目录")
    ap.add_argument("--json", action="store_true", help="JSON 输出，供 CI/Agent 消费")
    ap.add_argument("--warn-only", action="store_true", help="全部降级为告警，不阻断（试点期）")
    ap.add_argument("--mode", choices=["process", "init"], default="process",
                    help="process=流程门禁(默认)；init=初始化 DoD")
    ap.add_argument("--record", action="store_true", help="把本次各卡真实结果回写进卡片 gate 块")
    ap.add_argument("--card", help="限定 --record 的卡号；搭配 --to 预检该卡拟转入状态")
    ap.add_argument("--to", choices=["verified", "closed", "completed"], help="仅在内存预检目标状态")
    ap.add_argument("--release", metavar="VERSION",
                    help="发版/归档前只读预检：该批次活跃卡须全部 closed/completed")
    ap.add_argument("--receipt", action="store_true",
                    help="状态同步后只读复核，并按固定格式输出 --card 指定卡的节点回执")
    ap.add_argument("--next-id", choices=["change", "task"],
                    help="只读查询：跨现行总账与归档批次输出该轨下一个卡号")
    ap.add_argument("--topic", metavar="NAME",
                    help="只读查询：列出主题在现行总账与归档批次中的全部卡片")
    ap.add_argument("--scope", choices=["active", "history"],
                    help="与 --topic 搭配：active 只读现行总账；history 只读批次总账与旧布局归档登记")
    ap.add_argument("--list-checks", action="store_true",
                    help="只读查询：列出全部诊断码、默认严重级别、释义与修复提示（不依赖目标项目）")
    ap.add_argument("--scaffold", choices=["new-card"],
                    help="只读建卡计划（需搭配 --plan；不落盘，写入流程未实现）")
    ap.add_argument("--plan", action="store_true", help="与 --scaffold new-card 搭配：只输出计划")
    ap.add_argument("--track", choices=["change", "task"], help="scaffold 计划的目标轨道，缺省 change")
    ap.add_argument("--design-topic", metavar="NAME", help="scaffold 计划挂接的设计主题")
    ap.add_argument("--title", help="scaffold 计划中的卡片标题")
    ap.add_argument("--card-version", metavar="VERSION", help="scaffold 计划中的发布批次 version")
    ap.add_argument("--branch", help="scaffold 计划中的执行分支")
    ap.add_argument("--design-doc", metavar="PATH", help="scaffold 计划挂接的设计文档；缺省按主题查找")
    ap.add_argument("--todo", metavar="TEXT", help="scaffold 计划拟从待办池删除的事项文本")
    ap.add_argument("--milestone", metavar="NAME", help="任务卡 scaffold 计划中的里程碑")
    args = ap.parse_args(argv)
    scaffold_args = (args.track, args.design_topic, args.title, args.card_version,
                     args.branch, args.design_doc, args.todo, args.milestone)
    if args.scaffold:
        if not args.plan:
            ap.error("--scaffold 需要 --plan（当前只提供只读计划，写入流程未实现）")
        if (args.next_id or args.topic is not None or args.card or args.to or args.record
                or args.receipt or args.warn_only or args.release is not None
                or args.mode == "init" or args.scope):
            ap.error("--scaffold 为只读计划查询，不可与 --next-id/--topic/--scope/--card/--to/"
                     "--record/--receipt/--release/--warn-only/--mode init/--list-checks 合用")
    elif args.plan:
        ap.error("--plan 需要 --scaffold new-card")
    elif any(scaffold_args):
        ap.error("--track/--design-topic/--title/--card-version/--branch/--design-doc/--todo/"
                 "--milestone 仅在 --scaffold 下使用")
    if args.scope and args.topic is None:
        ap.error("--scope 需要 --topic")
    if args.list_checks:
        if (args.next_id or args.topic is not None or args.card or args.to or args.record
                or args.receipt or args.warn_only or args.release is not None
                or args.mode == "init" or args.scope):
            ap.error("--list-checks 为静态目录查询，不可与 --next-id/--topic/--scope/--card/--to/"
                     "--record/--receipt/--release/--warn-only/--mode init 合用")
        catalog = check_catalog()
        if args.json:
            print(json.dumps({"tool": "adflow-verify", "version": VERSION,
                              "checks": catalog}, ensure_ascii=False, indent=2))
        else:
            print("adflow-verify v%s  checks=%d" % (VERSION, len(catalog)))
            for item in catalog:
                print("%-24s %-9s %s" % (item["code"], item["severity"], item["meaning"]))
                print("    ↳ 修复: %s" % item["hint"])
        return 0
    if args.next_id or args.topic is not None:
        if args.next_id and args.topic is not None:
            ap.error("--next-id 与 --topic 一次只能查询一项")
        if (args.card or args.to or args.record or args.receipt or args.warn_only
                or args.release is not None or args.mode == "init"):
            ap.error("--next-id/--topic 为只读查询，不可与 --card/--to/--record/--receipt/"
                     "--release/--warn-only/--mode init 合用")
        if args.topic is not None and not TOPIC_NAME_RE.fullmatch(args.topic):
            ap.error("--topic 需要设计锚标中的主题名，如 MarketService")
    if args.to and not args.card:
        ap.error("--to 需要 --card")
    if args.mode == "init" and (args.card or args.to or args.record or args.receipt
                                or args.release is not None):
        ap.error("初始化检查不支持 --card/--to/--record/--receipt/--release")
    if args.warn_only and args.record:
        ap.error("--warn-only 不可与 --record 合用；试点降级不得写入正式 gate")
    if args.receipt:
        if not args.card:
            ap.error("--receipt 需要 --card")
        if args.to or args.record or args.warn_only:
            ap.error("--receipt 在状态同步后只读复核，不可与 --to/--record/--warn-only 合用")
    if args.release is not None:
        if not norm_version(args.release):
            ap.error("--release 需要非空版本号，如 v0.1.0")
        if args.card or args.record:
            ap.error("--release 为只读批次预检，不可与 --card/--to/--record 合用")

    ctx = Ctx(args.target_dir)
    payload = None
    if args.mode == "init":
        run_init(ctx)
    elif args.topic is not None and args.scope:
        data, text = scoped_topic_query(ctx, args.topic, args.scope)
        payload = ({"topic": data}, text, [])
        return report(ctx, "query", args.json, False, None, payload)
    else:
        cards = collect_cards(ctx)
        if args.record:
            ctx.record_ids = {cid for _, _, cid in cards if args.card is None or cid == args.card}
        if args.card and not any(cid == args.card for _, _, cid in cards):
            ctx.hard("TRANSITION_CARD", args.card, "-", "目标卡不存在于活跃卡池")
        if args.to:
            propose_state(ctx, cards, args.card, args.to)
        for rel, card, cid in cards:
            track = "change" if "/devel/change/" in rel else "task"
            check_card(ctx, card, cid, rel, track)
        check_globals(ctx)
        check_advisories(ctx, cards)
        if args.release is not None:
            check_release(ctx, cards, args.release)
        if args.record and not any(f["code"] in {"TRANSITION_CARD", "TRANSITION_STATE", "ID_DUPLICATE"}
                                   for f in ctx.findings):
            record_gates(ctx, cards, args.card)
        if args.receipt:
            matches = [(rel, card) for rel, card, cid in cards if cid == args.card]
            if len(matches) == 1:
                rel, card = matches[0]
                track = "change" if "/devel/change/" in rel else "task"
                receipt = render_receipt(ctx, card, args.card, rel, track, summarize(ctx)[2])
                payload = ({"receipt": receipt}, receipt, [])
        if args.next_id:
            nid, basis = next_id(ctx, args.next_id)
            notes = [] if not basis["max"] or HERE in basis["found_in"] else [
                "最大卡号 %s 位于 %s，不在当前工作区" % (basis["max"], "、".join(basis["found_in"]))]
            payload = ({"next_id": nid, "next_id_basis": basis}, nid, notes)
        elif args.topic is not None:
            data, text = topic_history(ctx, cards, args.topic)
            payload = ({"topic": data}, text, [])
        elif args.scaffold:
            data, text = scaffold_plan(ctx, args)
            payload = ({"scaffold": data}, text, [])

    code = report(ctx, args.mode, args.json, args.warn_only, args.release, payload)
    return code


if __name__ == "__main__":
    sys.exit(main())
