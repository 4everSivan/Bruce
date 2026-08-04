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
    seen_msg = set()
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
                    if mid:
                        if mid in seen_msg:
                            continue
                        seen_msg.add(mid)
                    record_usage(
                        agent,
                        ts,
                        msg.get("model"),
                        int(u.get("input_tokens") or 0),
                        int(u.get("output_tokens") or 0),
                        int(u.get("cache_read_input_tokens") or 0),
                        int(u.get("cache_creation_input_tokens") or 0),
                        project=proj,
                    )
        except OSError:
            continue
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
