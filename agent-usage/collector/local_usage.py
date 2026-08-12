"""本机会话扫描、token 聚合与成本计算 (阶段 D: 从 collect_usage.py 拆出).

读取本机 Agent 会话 JSONL (Kimi Work/Kimi Code CLI/Claude Code/Codex),
聚合 token 用量, 计算成本. 日期桶边界 (TODAY/CUTOFF_TS/DAY_LIST) 和
时区通过 runtime 模块访问, 由 _configure_runtime 每次运行重置.
不执行网络请求.
"""

import collections
import datetime
import glob
import json
import os
import sqlite3

import runtime
from pricing import estimate_cost


def new_bucket():
    return {"input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "total": 0}


def make_agent(agent_id, name):
    return {
        "id": agent_id,
        "name": name,
        "status": "ok",
        "note": "",
        "quota": None,
        "today": new_bucket(),
        "daily": [],
        "models": {},
        "todayModels": [],
        "projects": [],
        "hours": [0] * 24,
        "todayCostUsd": None,
        "_by_day": collections.defaultdict(new_bucket),
        "_models_today": collections.defaultdict(new_bucket),
        "_projects_today": collections.defaultdict(int),
        "_hours": [0] * 24,
    }


def record_usage(agent, ts_seconds, model, inp, out, cache_read, cache_creation, project=None):
    day = runtime.day_of(ts_seconds)
    if day < runtime.DAY_LIST[0] or day > runtime.TODAY:
        return
    total = inp + out + cache_read + cache_creation
    b = agent["_by_day"][day]
    b["input"] += inp
    b["output"] += out
    b["cacheRead"] += cache_read
    b["cacheCreation"] += cache_creation
    b["total"] += total
    if day == runtime.TODAY:
        mb = agent["_models_today"][model or "unknown"]
        mb["input"] += inp
        mb["output"] += out
        mb["cacheRead"] += cache_read
        mb["cacheCreation"] += cache_creation
        mb["total"] += total
        agent["_hours"][runtime.hour_of(ts_seconds)] += total
        if project:
            agent["_projects_today"][project] += total


def finalize(agent, pricing):
    empty = new_bucket()

    def day_entry(d):
        b = agent["_by_day"].get(d, empty)
        return {
            "date": d,
            "input": b["input"] + b["cacheRead"] + b["cacheCreation"],
            "output": b["output"],
            "total": b["total"],
        }

    agent["daily"] = [day_entry(d) for d in runtime.DAY_LIST]
    agent["today"] = agent["_by_day"].get(runtime.TODAY, new_bucket())

    today_models = []
    total_cost = 0.0
    cost_known = False
    for model, b in sorted(agent["_models_today"].items(), key=lambda kv: -kv[1]["total"]):
        if model == "<synthetic>" or b["total"] <= 0:
            continue
        c = estimate_cost(model, b, pricing) if pricing else None
        if c is not None:
            total_cost += c
            cost_known = True
        today_models.append(
            {
                "model": model,
                "total": b["total"],
                "input": b["input"] + b["cacheRead"] + b["cacheCreation"],
                "output": b["output"],
                "costUsd": round(c, 4) if c is not None else None,
            }
        )
    agent["todayModels"] = today_models[:5]
    agent["models"] = {m["model"]: m["total"] for m in today_models}
    agent["todayCostUsd"] = round(total_cost, 4) if cost_known else None
    agent["projects"] = [
        {"name": k, "total": v}
        for k, v in sorted(agent["_projects_today"].items(), key=lambda kv: -kv[1])[:3]
    ]
    agent["hours"] = agent["_hours"]
    for k in ("_by_day", "_models_today", "_projects_today", "_hours", "_model_for_cost"):
        agent.pop(k, None)
    return agent


# ---------------------------------------------------------------- scanners

def iter_recent_jsonl(root, pattern="**/*.jsonl"):
    if not os.path.isdir(root):
        return
    for path in glob.glob(os.path.join(root, pattern), recursive=True):
        try:
            if os.path.getmtime(path) < runtime.CUTOFF_TS:
                continue
        except OSError:
            continue
        yield path


def scan_kimi(agent, root, project_from_path=None):
    found = False
    for path in iter_recent_jsonl(root):
        found = True
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"usage.record"' not in line:
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    if r.get("type") != "usage.record":
                        continue
                    u = r.get("usage") or {}
                    ts = r.get("time")
                    if not isinstance(ts, (int, float)):
                        continue
                    record_usage(
                        agent,
                        ts / 1000.0,
                        r.get("model"),
                        int(u.get("inputOther") or 0),
                        int(u.get("output") or 0),
                        int(u.get("inputCacheRead") or 0),
                        int(u.get("inputCacheCreation") or 0),
                        project=project_from_path(path) if project_from_path else None,
                    )
        except OSError:
            continue
    return found


def scan_claude(agent, claude_projects):
    found = False
    # 同一 message id 可能被多次写入: Claude Code (>= 2.1.228) 在流式开始时先写
    # usage=0 的骨架, 完成后追加完整记录. 若保留首次出现会把骨架当成真实用量,
    # input/output 被大量丢弃; 因此按 message id 累积各字段最大值, 统计结束后
    # 一次性记录 (ts 取最后一次写入 = 完成时刻).
    best = {}  # mid -> [inp, out, cr, cc, ts, model, proj]
    for path in iter_recent_jsonl(claude_projects):
        found = True
        proj = os.path.basename(os.path.dirname(path))
        if "-project-" in proj:
            proj = proj.split("-project-")[-1]
        elif proj.startswith("-Users-"):
            proj = proj.split("-")[-1]
        if "/subagents/" in path:
            proj += " ·子代理"
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"usage"' not in line or '"assistant"' not in line:
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    if r.get("type") != "assistant":
                        continue
                    msg = r.get("message") or {}
                    u = msg.get("usage") or {}
                    mid = msg.get("id")
                    ts = runtime.parse_iso(r.get("timestamp") or "")
                    if ts is None:
                        continue
                    inp = int(u.get("input_tokens") or 0)
                    out = int(u.get("output_tokens") or 0)
                    cr = int(u.get("cache_read_input_tokens") or 0)
                    cc = int(u.get("cache_creation_input_tokens") or 0)
                    if not mid:
                        record_usage(
                            agent,
                            ts,
                            msg.get("model"),
                            inp,
                            out,
                            cr,
                            cc,
                            project=proj,
                        )
                        continue
                    entry = best.get(mid)
                    if entry is None:
                        best[mid] = [inp, out, cr, cc, ts, msg.get("model"), proj]
                    else:
                        entry[0] = max(entry[0], inp)
                        entry[1] = max(entry[1], out)
                        entry[2] = max(entry[2], cr)
                        entry[3] = max(entry[3], cc)
                        entry[4] = ts
                        entry[5] = msg.get("model")
                        entry[6] = proj
        except OSError:
            continue
    for inp, out, cr, cc, ts, model, proj in best.values():
        record_usage(agent, ts, model, inp, out, cr, cc, project=proj)
    return found


def scan_codex(agent, session_dirs):
    """扫描 Codex rollout 会话, 返回 (found, quota_candidate).

    quota_candidate 为 {"ts": float, "quota": dict} 或 None; agent["quota"]
    的写入上移到调用方, 便于跨来源 (CLI/Orca) 取 ts 最大者.
    文件按 mtime 降序遍历: quota 快照只需最新一份, 已在更新文件拿到 quota
    后, mtime 早于 CUTOFF_TS 的旧文件直接短路, 不再整文件读取; 用量统计
    逻辑不变 (旧文件本就不计入 14 日窗口).
    """
    found = False
    latest_quota = None
    latest_quota_ts = -1.0
    files = []
    for d in session_dirs:
        files.extend(
            glob.glob(os.path.join(d, "**/rollout-*.jsonl"), recursive=True)
        )
    timed = []
    for path in set(files):
        try:
            timed.append((os.path.getmtime(path), path))
        except OSError:
            continue
    timed.sort(reverse=True)
    for mtime, path in timed:
        recent = mtime >= runtime.CUTOFF_TS
        if recent:
            found = True
        elif latest_quota is not None:
            # quota 只需最新一份: 已捕获后更旧的文件不再整文件扫描
            break
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    # 超大行 (工具输出/消息内容, 实测 18 个大行均不含
                    # token_count) json.loads 会分配大块内存且碎片不还给 OS,
                    # 导致 RSS 虚高. token_count 行结构简单, 不会超 1MB.
                    if len(line) > 1_000_000:
                        continue
                    if '"token_count"' not in line:
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    payload = r.get("payload") or {}
                    if payload.get("type") != "token_count":
                        continue
                    ts = runtime.parse_iso(r.get("timestamp") or "")
                    rl = payload.get("rate_limits")
                    if rl and ts and ts > latest_quota_ts:
                        latest_quota_ts = ts
                        latest_quota = rl
                    if not recent or ts is None:
                        continue
                    info = payload.get("info") or {}
                    u = info.get("last_token_usage") or {}
                    if not u:
                        continue
                    record_usage(
                        agent,
                        ts,
                        "codex",
                        int(u.get("input_tokens") or 0) - int(u.get("cached_input_tokens") or 0),
                        int(u.get("output_tokens") or 0),
                        int(u.get("cached_input_tokens") or 0),
                        0,
                    )
        except OSError:
            continue
    if not latest_quota:
        return found, None
    windows = []
    for key, label in (("primary", "5小时窗口"), ("secondary", "每周窗口")):
        w = latest_quota.get(key)
        if w:
            windows.append(
                {
                    "label": label,
                    "usedPercent": float(w.get("used_percent") or 0),
                    "windowMinutes": w.get("window_minutes"),
                    "resetsAt": w.get("resets_at"),
                }
            )
    quota = {
        "plan": latest_quota.get("plan_type"),
        "windows": windows,
        "capturedAt": datetime.datetime.fromtimestamp(
            latest_quota_ts, runtime._RUNTIME_TZ
        ).isoformat(timespec="seconds"),
    }
    return found, {"ts": latest_quota_ts, "quota": quota}


def scan_grok(agent, root):
    """扫描 Grok Build 会话目录.

    Grok 的 chat_history.jsonl 只存储对话内容, 不含 token 计数
    (token 用量由 cc-switch 代理拦截 API 响应获得, 不写入会话文件).
    本扫描器按消息内容长度估算 token: 每条消息取 content 文本长度 / 4
    (近似 4 字符 = 1 token), user 消息计入输入, assistant 消息计入输出.

    会话目录结构 (参考 cc-switch grokbuild.rs):
      root/sessions/<encoded_project>/<session_id>/chat_history.jsonl
      root/sessions/<encoded_project>/<session_id>/summary.json
    也兼容 root/archived_sessions/ 路径.

    时间戳: chat_history.jsonl 的单条消息不带 timestamp, 使用文件 mtime
    作为会话的近似时间; 若 mtime 落在 14 日窗口内则计入用量.
    """
    found = False
    for sub in ("sessions", "archived_sessions"):
        sub_root = os.path.join(root, sub)
        if not os.path.isdir(sub_root):
            continue
        for path in iter_recent_jsonl(sub_root):
            found = True
            project = None
            # 路径形如 .../sessions/<encoded_project>/<session_id>/chat_history.jsonl
            parts = path.split(os.sep)
            if len(parts) >= 3:
                encoded = parts[-3]
                from urllib.parse import unquote
                decoded = unquote(encoded)
                project = os.path.basename(decoded) if decoded != encoded else encoded
            # 用文件 mtime 作为会话的近似时间 (秒)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if '"type"' not in line:
                            continue
                        try:
                            r = json.loads(line)
                        except Exception:
                            continue
                        msg_type = r.get("type")
                        if msg_type not in ("user", "assistant"):
                            continue
                        content = _extract_grok_content(r.get("content"))
                        if not content:
                            continue
                        estimated_tokens = max(1, len(content) // 4)
                        if msg_type == "user":
                            record_usage(
                                agent, mtime, "grok",
                                estimated_tokens, 0, 0, 0,
                                project=project,
                            )
                        else:
                            record_usage(
                                agent, mtime, "grok",
                                0, estimated_tokens, 0, 0,
                                project=project,
                            )
            except OSError:
                continue
    return found


def _extract_grok_content(content):
    """从 Grok chat_history.jsonl 的 content 字段提取纯文本.

    content 可能是字符串或列表 (列表元素含 type/text 键).
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    parts.append(text)
            elif isinstance(item, str):
                parts.append(item)
        return " ".join(parts)
    return ""


def scan_opencode(agent, opencode_db):
    """扫描 opencode 会话用量 (只读 SQLite, 不写不迁移).

    读 `~/.local/share/opencode/opencode.db` 的 message 表 (与 Codex/Orca
    扫描同构, mode=ro): 每条 assistant 消息有独立的 time.created (毫秒)
    与 tokens (input/output/reasoning/cache), 按消息时刻精确分桶 —
    session 表的 time_created 只是会话创建时间, 会把全天用量误归到凌晨.
    schema 不兼容必须产生可诊断状态, 不得静默伪装成空结果.
    返回是否发现任何会话; db 缺失返回 False (not_found).
    """
    if not os.path.exists(opencode_db):
        return False
    try:
        with sqlite3.connect("file:%s?mode=ro" % opencode_db, uri=True) as db:
            # found 语义: db 中存在任何消息 (即使都在窗口外, 也说明数据源可用)
            any_message = db.execute(
                "SELECT 1 FROM message LIMIT 1"
            ).fetchone()
            rows = db.execute(
                "SELECT data FROM message "
                "WHERE data LIKE '%tokens%' "
                "ORDER BY json_extract(data, '$.time.created')"
            ).fetchall()
    except sqlite3.Error as e:
        # schema 不兼容: 可诊断状态, 不伪装空结果
        agent["status"] = "error"
        msg = str(e)
        if "no such table" in msg or "no such column" in msg:
            agent["note"] = "本机 opencode 数据库 schema 不兼容"
        else:
            agent["note"] = "本机 opencode 数据库暂不可读: " + msg[:60]
        return False
    if not any_message:
        return False
    # db 存在且含消息: 视为发现 (窗口外的消息不计入用量, 但数据源可用)
    found = True
    cutoff_ms = int(runtime.CUTOFF_TS * 1000)
    for (data,) in rows:
        try:
            msg = json.loads(data)
        except (ValueError, TypeError):
            continue
        if msg.get("role") != "assistant":
            continue
        tokens = msg.get("tokens") or {}
        if not tokens:
            continue
        created = (msg.get("time") or {}).get("created")
        if not isinstance(created, (int, float)) or created < cutoff_ms:
            continue
        cache = tokens.get("cache") or {}
        model = msg.get("modelID") or "opencode"
        found = True
        record_usage(
            agent,
            created / 1000.0,
            model,
            int(tokens.get("input") or 0),
            int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0),
            int(cache.get("read") or 0),
            int(cache.get("write") or 0),
        )
    return found
