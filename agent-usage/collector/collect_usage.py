#!/usr/bin/env python3
"""Aggregate local AI-agent token usage, cost estimates, and provider quotas.

Agents: Kimi Work (daimon), Kimi Code CLI, Claude Code, Codex (CLI and
Orca-hosted sessions merged into one agent); detection only for
Gemini/Antigravity, GitHub Copilot, Cursor.
Services (quota): read CC Switch's provider database and query the providers
it knows how to meter (Kimi For Coding, DeepSeek balance, Volcengine Coding
Plan via signed OpenAPI). Cost estimates use CC Switch's model_pricing table.

Entry point: run(ctx) -> {"artifact": {...}}
"""

import base64
import collections
import datetime
import glob
import hashlib
import hmac
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from zoneinfo import ZoneInfo

HOME = os.path.expanduser("~")
DAIMON_KIMI_SESSIONS = os.path.join(
    HOME,
    "Library/Application Support/kimi-desktop/daimon-share/daimon/"
    "runtime/kimi-code/home/sessions",
)
KIMI_CLI_SESSIONS = os.path.join(HOME, ".kimi-code/sessions")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude/projects")
CODEX_SESSIONS = os.path.join(HOME, ".codex/sessions")
ORCA_HOME = os.path.join(HOME, "Library/Application Support/orca")
ORCA_CODEX_SESSIONS = os.path.join(ORCA_HOME, "codex-runtime-home/home/sessions")
ORCA_CODEX_ACCOUNTS = os.path.join(ORCA_HOME, "codex-accounts")
CC_SWITCH_DB = os.path.join(HOME, ".cc-switch/cc-switch.db")
CODEX_OAUTH_AUTH = os.path.join(HOME, ".cc-switch/codex_oauth_auth.json")
CODEX_AUTH = os.path.join(HOME, ".codex/auth.json")
CODEX_OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
AGY_OAUTH_TOKEN = os.path.join(HOME, ".gemini/antigravity-cli/antigravity-oauth-token")
AGY_SUMMARIES_DB = os.path.join(HOME, ".gemini/antigravity-cli/conversation_summaries.db")
KIMI_WEB_TOKENS = os.path.join(HOME, ".config/kimi-dashboard/kimi-web-tokens.json")
# agy >= 1.1.8 把 OAuth 令牌存进登录 Keychain (go-keyring), 不再写令牌文件
AGY_KEYCHAIN_SERVICE = "gemini"
AGY_KEYCHAIN_ACCOUNT = "antigravity"
# Antigravity 桌面 OAuth client: installed-app 凭证, 公开内置于 agy/IDE,
# 无保密要求 (PKCE 提供安全); 凭证由运行环境注入, 不入库
AGY_CLIENT_ID = os.getenv("AGY_CLIENT_ID", "")
AGY_CLIENT_SECRET = os.getenv("AGY_CLIENT_SECRET", "")
AGY_QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"

DAYS = 14
HTTP_TIMEOUT = 8

now = None
TODAY = None
CUTOFF_TS = None
DAY_LIST = []
_RUNTIME_TZ = None
_RUNTIME_HTTP = {}
_RUNTIME_CREDENTIALS = {}
_RUNTIME_CREDENTIAL_UPDATES = []
# App 模式 quota 401 收集的定向重试挑战; Bridge 每次运行重置, 测试直接断言
_RUNTIME_CREDENTIAL_CHALLENGES = []
_RUNTIME_CAPABILITIES = None
_APP_MODE = False
_CREDENTIAL_UPDATE_LOCK = threading.Lock()


def _path_override(overrides, name, default):
    value = overrides.get(name, default)
    return os.path.abspath(os.path.expanduser(value))


def _configure_runtime(ctx):
    """Configure per-run boundaries without performing I/O.

    Supported test/App overrides:
    - home / paths: isolate all local file and SQLite reads.
    - now / timezone: make date buckets deterministic.
    - http: inject get_json, post_json, or urlopen callables.
    - credentials: provide in-memory provider credentials.
    - capabilities: capability allowlist; only present in Bridge App mode.
    """
    global HOME, DAIMON_KIMI_SESSIONS, KIMI_CLI_SESSIONS, CLAUDE_PROJECTS
    global CODEX_SESSIONS, ORCA_HOME, ORCA_CODEX_SESSIONS, ORCA_CODEX_ACCOUNTS
    global CC_SWITCH_DB, CODEX_OAUTH_AUTH, CODEX_AUTH, AGY_OAUTH_TOKEN
    global AGY_SUMMARIES_DB, KIMI_WEB_TOKENS
    global DAYS, HTTP_TIMEOUT, now, TODAY, CUTOFF_TS, DAY_LIST
    global _RUNTIME_TZ, _RUNTIME_HTTP, _RUNTIME_CREDENTIALS
    global _RUNTIME_CREDENTIAL_UPDATES, _RUNTIME_CAPABILITIES, _APP_MODE
    global _RUNTIME_CREDENTIAL_CHALLENGES
    global CODEX_TOKEN_URL, CODEX_USAGE_URL

    ctx = ctx or {}
    HOME = os.path.abspath(os.path.expanduser(ctx.get("home") or "~"))
    paths = ctx.get("paths") or {}
    DAIMON_KIMI_SESSIONS = _path_override(
        paths,
        "daimon_kimi_sessions",
        os.path.join(
            HOME,
            "Library/Application Support/kimi-desktop/daimon-share/daimon/"
            "runtime/kimi-code/home/sessions",
        ),
    )
    KIMI_CLI_SESSIONS = _path_override(
        paths, "kimi_cli_sessions", os.path.join(HOME, ".kimi-code/sessions")
    )
    CLAUDE_PROJECTS = _path_override(
        paths, "claude_projects", os.path.join(HOME, ".claude/projects")
    )
    CODEX_SESSIONS = _path_override(
        paths, "codex_sessions", os.path.join(HOME, ".codex/sessions")
    )
    ORCA_HOME = _path_override(
        paths, "orca_home", os.path.join(HOME, "Library/Application Support/orca")
    )
    ORCA_CODEX_SESSIONS = _path_override(
        paths,
        "orca_codex_sessions",
        os.path.join(ORCA_HOME, "codex-runtime-home/home/sessions"),
    )
    ORCA_CODEX_ACCOUNTS = _path_override(
        paths, "orca_codex_accounts", os.path.join(ORCA_HOME, "codex-accounts")
    )
    CC_SWITCH_DB = _path_override(
        paths, "cc_switch_db", os.path.join(HOME, ".cc-switch/cc-switch.db")
    )
    CODEX_OAUTH_AUTH = _path_override(
        paths,
        "codex_oauth_auth",
        os.path.join(HOME, ".cc-switch/codex_oauth_auth.json"),
    )
    CODEX_AUTH = _path_override(
        paths, "codex_auth", os.path.join(HOME, ".codex/auth.json")
    )
    AGY_OAUTH_TOKEN = _path_override(
        paths,
        "antigravity_oauth_token",
        os.path.join(HOME, ".gemini/antigravity-cli/antigravity-oauth-token"),
    )
    AGY_SUMMARIES_DB = _path_override(
        paths,
        "antigravity_summaries_db",
        os.path.join(HOME, ".gemini/antigravity-cli/conversation_summaries.db"),
    )
    KIMI_WEB_TOKENS = _path_override(
        paths,
        "kimi_web_tokens",
        os.path.join(HOME, ".config/kimi-dashboard/kimi-web-tokens.json"),
    )
    # App/测试可覆盖出站 URL (本地 fake server 用 loopback 地址);
    # 默认值保持生产端点不变.
    CODEX_TOKEN_URL = str(
        ctx.get("codex_token_url") or CODEX_TOKEN_URL
    )
    CODEX_USAGE_URL = str(
        ctx.get("codex_usage_url") or CODEX_USAGE_URL
    )

    timezone_value = ctx.get("timezone")
    if isinstance(timezone_value, str):
        _RUNTIME_TZ = ZoneInfo(timezone_value)
    elif isinstance(timezone_value, datetime.tzinfo):
        _RUNTIME_TZ = timezone_value
    else:
        _RUNTIME_TZ = datetime.datetime.now().astimezone().tzinfo

    now_value = ctx.get("now")
    if callable(now_value):
        now_value = now_value()
    if isinstance(now_value, str):
        now_value = datetime.datetime.fromisoformat(now_value.replace("Z", "+00:00"))
    if now_value is None:
        now_value = datetime.datetime.now(_RUNTIME_TZ)
    if not isinstance(now_value, datetime.datetime):
        raise TypeError("ctx.now must be a datetime, ISO-8601 string, or callable")
    if now_value.tzinfo is None:
        now_value = now_value.replace(tzinfo=_RUNTIME_TZ)
    now = now_value.astimezone(_RUNTIME_TZ)

    DAYS = int(ctx.get("days", 14))
    if DAYS < 1:
        raise ValueError("ctx.days must be at least 1")
    HTTP_TIMEOUT = float(ctx.get("http_timeout", 8))
    TODAY = now.strftime("%Y-%m-%d")
    CUTOFF_TS = (now - datetime.timedelta(days=DAYS + 1)).timestamp()
    DAY_LIST = [
        (now - datetime.timedelta(days=i)).strftime("%Y-%m-%d")
        for i in range(DAYS - 1, -1, -1)
    ]
    _RUNTIME_HTTP = dict(ctx.get("http") or {})
    _RUNTIME_CREDENTIALS = dict(ctx.get("credentials") or {})
    _RUNTIME_CREDENTIAL_UPDATES = []
    _RUNTIME_CREDENTIAL_CHALLENGES = []
    _APP_MODE = bool(ctx.get("app_mode"))
    # 只有 ctx 显式携带 capabilities 时才启用门禁 (Bridge App 模式总会携带);
    # CLI 直跑不带该键, 保持现状行为完全不变
    if "capabilities" in ctx:
        _RUNTIME_CAPABILITIES = set(ctx.get("capabilities") or [])
    else:
        _RUNTIME_CAPABILITIES = None


def _capability_allowed(name):
    """能力门禁: 未启用 (无 capabilities 键) 时全部放行."""
    return _RUNTIME_CAPABILITIES is None or name in _RUNTIME_CAPABILITIES


def _runtime_credential(name, default=None):
    return _RUNTIME_CREDENTIALS.get(name, default)


def _record_credential_update(provider, account_id, credentials):
    """Keep rotated credentials outside the display artifact.

    App mode returns these candidates to the native owner. CLI mode continues
    its legacy file behavior and does not expose credentials on stdout.
    """
    if not _APP_MODE or not credentials:
        return
    values = {
        key: value
        for key, value in credentials.items()
        if value is not None and key in {"access_token", "refresh_token", "id_token", "expiry"}
    }
    if not values:
        return
    # services 采集并行后, 多个账号可能同时 append, 需要锁保护
    with _CREDENTIAL_UPDATE_LOCK:
        _RUNTIME_CREDENTIAL_UPDATES.append(
            {
                "provider": provider,
                "accountId": account_id or "default",
                "kind": "oauthTokens",
                "operation": "replace",
                "credentials": values,
            }
        )


def _urlopen(request, **kwargs):
    opener = _RUNTIME_HTTP.get("urlopen") or urllib.request.urlopen
    return opener(request, **kwargs)


def day_of(ts_seconds):
    return datetime.datetime.fromtimestamp(ts_seconds, _RUNTIME_TZ).strftime("%Y-%m-%d")


def hour_of(ts_seconds):
    return datetime.datetime.fromtimestamp(ts_seconds, _RUNTIME_TZ).hour


def parse_iso(ts):
    try:
        value = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if value.tzinfo is None:
            value = value.replace(tzinfo=_RUNTIME_TZ)
        return value.timestamp()
    except Exception:
        return None


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
    day = day_of(ts_seconds)
    if day < DAY_LIST[0] or day > TODAY:
        return
    total = inp + out + cache_read + cache_creation
    b = agent["_by_day"][day]
    b["input"] += inp
    b["output"] += out
    b["cacheRead"] += cache_read
    b["cacheCreation"] += cache_creation
    b["total"] += total
    if day == TODAY:
        mb = agent["_models_today"][model or "unknown"]
        mb["input"] += inp
        mb["output"] += out
        mb["cacheRead"] += cache_read
        mb["cacheCreation"] += cache_creation
        mb["total"] += total
        agent["_hours"][hour_of(ts_seconds)] += total
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

    agent["daily"] = [day_entry(d) for d in DAY_LIST]
    agent["today"] = agent["_by_day"].get(TODAY, new_bucket())

    def cost_of(b):
        return estimate_cost(agent.get("_model_for_cost", ""), b, pricing) if pricing else None

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


# ---------------------------------------------------------------- pricing

# 内置价目表（2026-07 快照，来自各厂商公开定价；usd / 1M tokens：
# input, output, cache_read, cache_creation）。成本估算不再依赖 CC Switch，
# 仅当遇到内置表没有的新模型时才回落读取 CC 的 model_pricing 作为补充。
BUILTIN_PRICING = {
    "claude-3-5-haiku-20241022": (0.80, 4, 0.08, 1),
    "claude-3-5-sonnet-20241022": (3, 15, 0.30, 3.75),
    "claude-fable-5": (10, 50, 1.00, 12.50),
    "claude-haiku-4-5-20251001": (1, 5, 0.10, 1.25),
    "claude-mythos-5": (10, 50, 1.00, 12.50),
    "claude-opus-4-1-20250805": (15, 75, 1.50, 18.75),
    "claude-opus-4-20250514": (15, 75, 1.50, 18.75),
    "claude-opus-4-5-20251101": (5, 25, 0.50, 6.25),
    "claude-opus-4-6-20260206": (5, 25, 0.50, 6.25),
    "claude-opus-4-7": (5, 25, 0.50, 6.25),
    "claude-opus-4-8": (5, 25, 0.50, 6.25),
    "claude-sonnet-4-20250514": (3, 15, 0.30, 3.75),
    "claude-sonnet-4-5-20250929": (3, 15, 0.30, 3.75),
    "claude-sonnet-4-6-20260217": (3, 15, 0.30, 3.75),
    "claude-sonnet-5": (3, 15, 0.30, 3.75),
    "codestral-2508": (0.30, 0.90, 0.03, 0),
    "codex-mini": (0.75, 3, 0.025, 0),
    "command-a": (2.50, 10, 0, 0),
    "command-r": (0.15, 0.60, 0, 0),
    "command-r-plus": (2.50, 10, 0, 0),
    "deepseek-chat": (0.27, 1.10, 0.07, 0),
    "deepseek-reasoner": (0.55, 2.19, 0.14, 0),
    "deepseek-v3": (0.28, 1.11, 0.028, 0),
    "deepseek-v3.1": (0.55, 1.67, 0.055, 0),
    "deepseek-v3.2": (0.28, 0.42, 0.028, 0),
    "deepseek-v4-flash": (0.14, 0.28, 0.0028, 0),
    "deepseek-v4-pro": (0.435, 0.87, 0.003625, 0),
    "devstral-2-2512": (0.40, 2, 0.04, 0),
    "devstral-medium": (0.40, 2, 0.04, 0),
    "devstral-small-1.1": (0.07, 0.28, 0.01, 0),
    "devstral-small-2-2512": (0.10, 0.30, 0.01, 0),
    "doubao-seed-2-0-code": (0.47, 2.37, 0.09, 0),
    "doubao-seed-2-0-code-preview-latest": (0.47, 2.37, 0.09, 0),
    "doubao-seed-2-0-lite": (0.08, 0.50, 0.017, 0),
    "doubao-seed-2-0-mini": (0.03, 0.31, 0.0056, 0),
    "doubao-seed-2-0-pro": (0.47, 2.37, 0.09, 0),
    "doubao-seed-2-1-pro": (0.84, 4.2, 0.17, 0),
    "doubao-seed-2-1-turbo": (0.42, 2.1, 0.08, 0),
    "doubao-seed-code": (0.17, 1.11, 0.02, 0),
    "gemini-2.0-flash": (0.10, 0.40, 0.025, 0),
    "gemini-2.5-flash": (0.3, 2.5, 0.03, 0),
    "gemini-2.5-flash-lite": (0.10, 0.40, 0.01, 0),
    "gemini-2.5-pro": (1.25, 10, 0.125, 0),
    "gemini-3-flash-preview": (0.5, 3, 0.05, 0),
    "gemini-3-pro-preview": (2, 12, 0.2, 0),
    "gemini-3.1-flash-lite": (0.25, 1.50, 0.025, 0),
    "gemini-3.1-flash-lite-preview": (0.25, 1.50, 0.025, 0),
    "gemini-3.1-pro-preview": (2, 12, 0.20, 0),
    "gemini-3.5-flash": (1.50, 9.00, 0.15, 0),
    "glm-4.6": (0.6, 2.2, 0.11, 0),
    "glm-4.7": (0.6, 2.2, 0.11, 0),
    "glm-5": (1, 3.2, 0.2, 0),
    "glm-5.1": (1.4, 4.4, 0.26, 0),
    "glm-5.2": (1.4, 4.4, 0.26, 0),
    "gpt-4.1": (2, 8, 0.50, 0),
    "gpt-4.1-mini": (0.40, 1.60, 0.10, 0),
    "gpt-4.1-nano": (0.10, 0.40, 0.025, 0),
    "gpt-5": (1.25, 10, 0.125, 0),
    "gpt-5-codex": (1.25, 10, 0.125, 0),
    "gpt-5-codex-high": (1.25, 10, 0.125, 0),
    "gpt-5-codex-low": (1.25, 10, 0.125, 0),
    "gpt-5-codex-medium": (1.25, 10, 0.125, 0),
    "gpt-5-codex-mini": (1.25, 10, 0.125, 0),
    "gpt-5-codex-mini-high": (1.25, 10, 0.125, 0),
    "gpt-5-codex-mini-medium": (1.25, 10, 0.125, 0),
    "gpt-5-high": (1.25, 10, 0.125, 0),
    "gpt-5-low": (1.25, 10, 0.125, 0),
    "gpt-5-medium": (1.25, 10, 0.125, 0),
    "gpt-5-mini": (0.25, 2, 0.025, 0),
    "gpt-5-minimal": (1.25, 10, 0.125, 0),
    "gpt-5-nano": (0.05, 0.40, 0.005, 0),
    "gpt-5.1": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-max": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-max-high": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-max-xhigh": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-mini": (1.25, 10, 0.125, 0),
    "gpt-5.1-high": (1.25, 10, 0.125, 0),
    "gpt-5.1-low": (1.25, 10, 0.125, 0),
    "gpt-5.1-medium": (1.25, 10, 0.125, 0),
    "gpt-5.1-minimal": (1.25, 10, 0.125, 0),
    "gpt-5.2": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-high": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-low": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-medium": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-xhigh": (1.75, 14, 0.175, 0),
    "gpt-5.2-high": (1.75, 14, 0.175, 0),
    "gpt-5.2-low": (1.75, 14, 0.175, 0),
    "gpt-5.2-medium": (1.75, 14, 0.175, 0),
    "gpt-5.2-xhigh": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-high": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-low": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-medium": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-xhigh": (1.75, 14, 0.175, 0),
    "gpt-5.4": (2.50, 15, 0.25, 0),
    "gpt-5.4-mini": (0.75, 4.50, 0.075, 0),
    "gpt-5.4-nano": (0.20, 1.25, 0.02, 0),
    "gpt-5.5": (5, 30, 0.50, 0),
    "gpt-5.5-high": (5, 30, 0.50, 0),
    "gpt-5.5-low": (5, 30, 0.50, 0),
    "gpt-5.5-medium": (5, 30, 0.50, 0),
    "gpt-5.5-minimal": (5, 30, 0.50, 0),
    "gpt-5.5-xhigh": (5, 30, 0.50, 0),
    "gpt-5.6": (5, 30, 0.50, 6.25),
    "gpt-5.6-high": (5, 30, 0.50, 6.25),
    "gpt-5.6-low": (5, 30, 0.50, 6.25),
    "gpt-5.6-luna": (1, 6, 0.10, 1.25),
    "gpt-5.6-medium": (5, 30, 0.50, 6.25),
    "gpt-5.6-minimal": (5, 30, 0.50, 6.25),
    "gpt-5.6-sol": (5, 30, 0.50, 6.25),
    "gpt-5.6-terra": (2.50, 15, 0.25, 3.125),
    "gpt-5.6-xhigh": (5, 30, 0.50, 6.25),
    "grok-3": (3, 15, 0.75, 0),
    "grok-3-mini": (0.25, 0.50, 0.075, 0),
    "grok-4": (3, 15, 0.75, 0),
    "grok-4-1-fast-non-reasoning": (0.20, 0.50, 0.05, 0),
    "grok-4-1-fast-reasoning": (0.20, 0.50, 0.05, 0),
    "grok-4.20-0309-non-reasoning": (1.25, 2.50, 0.20, 0),
    "grok-4.20-0309-reasoning": (1.25, 2.50, 0.20, 0),
    "grok-4.3": (1.25, 2.50, 0.20, 0),
    "grok-build-0.1": (1, 2, 0.20, 0),
    "grok-code-fast-1": (1, 2, 0.20, 0),
    "hunyuan-hy3": (0.14, 0.56, 0.035, 0),
    "hy3": (0.14, 0.56, 0.035, 0),
    "kimi-k2-0905": (0.55, 2.20, 0.10, 0),
    "kimi-k2-thinking": (0.55, 2.20, 0.10, 0),
    "kimi-k2-turbo": (1.11, 8.06, 0.14, 0),
    "kimi-k2.5": (0.60, 3.00, 0.10, 0),
    "kimi-k2.6": (0.95, 4.00, 0.16, 0),
    "kimi-k2.7-code": (0.95, 4.00, 0.19, 0),
    "magistral-medium": (2, 5, 0, 0),
    "magistral-small": (0.50, 1.50, 0, 0),
    "mimo-v2-flash": (0.09, 0.29, 0.009, 0),
    "mimo-v2-pro": (0.435, 0.87, 0.0036, 0),
    "mimo-v2.5": (0.14, 0.29, 0.0028, 0),
    "mimo-v2.5-pro": (0.435, 0.87, 0.0036, 0),
    "minimax-m2": (0.27, 0.95, 0.03, 0),
    "minimax-m2.1": (0.27, 0.95, 0.03, 0),
    "minimax-m2.1-lightning": (0.27, 2.33, 0.03, 0),
    "minimax-m2.5": (0.15, 0.95, 0.03, 0),
    "minimax-m2.5-lightning": (0.30, 2.40, 0.03, 0),
    "minimax-m2.7": (0.30, 1.20, 0.06, 0.375),
    "minimax-m2.7-highspeed": (0.60, 2.40, 0.06, 0.375),
    "minimax-m3": (0.60, 2.40, 0.12, 0),
    "mistral-large-3-2512": (0.50, 1.50, 0.05, 0),
    "mistral-medium-3.1": (0.40, 2, 0.04, 0),
    "mistral-medium-3.5": (1.50, 7.50, 0, 0),
    "mistral-small-3.2-24b": (0.075, 0.20, 0.01, 0),
    "mistral-small-4": (0.10, 0.30, 0.01, 0),
    "o1": (15, 60, 7.50, 0),
    "o1-mini": (0.55, 2.20, 0.55, 0),
    "o3": (2, 8, 0.50, 0),
    "o3-mini": (0.55, 2.20, 0.55, 0),
    "o3-pro": (20, 80, 0, 0),
    "o4-mini": (1.10, 4.40, 0.275, 0),
    "qwen3-235b-a22b": (0.70, 8.40, 0, 0),
    "qwen3-32b": (0.16, 0.64, 0, 0),
    "qwen3-coder-480b": (0.65, 3.25, 0, 0),
    "qwen3-coder-480b-a35b-instruct": (0.65, 3.25, 0, 0),
    "qwen3-coder-flash": (0.195, 0.975, 0.039, 0),
    "qwen3-coder-next": (0.12, 0.75, 0, 0),
    "qwen3-coder-plus": (0.65, 3.25, 0.13, 0),
    "qwen3-max": (0.78, 3.90, 0, 0),
    "qwen3.5-plus": (0.26, 1.56, 0.052, 0),
    "qwen3.6-plus": (0.325, 1.95, 0.065, 0),
    "qwen3.7-max": (2.50, 7.50, 0.25, 0),
    "qwen3.7-plus": (0.40, 1.60, 0.08, 0),
    "qwq-32b": (0.20, 0.60, 0, 0),
    "qwq-plus": (0.80, 2.40, 0, 0),
    "step-3.5-flash": (0.10, 0.30, 0.02, 0),
    "step-3.5-flash-2603": (0.10, 0.30, 0.02, 0),
    "step-3.7-flash": (0.19, 1.13, 0.04, 0),
}


def load_pricing():
    """内置价目优先；CC Switch 的 model_pricing 只补充内置表没有的新模型。"""
    pricing = dict(BUILTIN_PRICING)
    if not os.path.exists(CC_SWITCH_DB):
        return pricing
    try:
        with sqlite3.connect("file:%s?mode=ro" % CC_SWITCH_DB, uri=True) as db:
            rows = db.execute(
                "SELECT model_id, input_cost_per_million, output_cost_per_million,"
                " cache_read_cost_per_million, cache_creation_cost_per_million"
                " FROM model_pricing"
            ).fetchall()
        for mid, ci, co, cr, cc in rows:
            mid = (mid or "").lower()
            if not mid or mid in pricing:
                continue
            try:
                pricing[mid] = (float(ci), float(co), float(cr), float(cc))
            except (TypeError, ValueError):
                continue
    except Exception:
        pass
    return pricing


def estimate_cost(model, bucket, pricing):
    if not pricing or not model:
        return None
    key = model.lower().split("[")[0].split("/")[-1].strip()
    prices = pricing.get(model.lower()) or pricing.get(key)
    if prices is None:
        for pid, p in pricing.items():
            if key and (key in pid or pid in key):
                prices = p
                break
    if prices is None:
        return None
    ci, co, cr, cc = prices
    return (
        bucket["input"] * ci
        + bucket["output"] * co
        + bucket["cacheRead"] * cr
        + bucket["cacheCreation"] * cc
    ) / 1e6


# ---------------------------------------------------------------- scanners

def iter_recent_jsonl(root, pattern="**/*.jsonl"):
    if not os.path.isdir(root):
        return
    for path in glob.glob(os.path.join(root, pattern), recursive=True):
        try:
            if os.path.getmtime(path) < CUTOFF_TS:
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


def scan_claude(agent):
    found = False
    seen_msg = set()
    for path in iter_recent_jsonl(CLAUDE_PROJECTS):
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
                    ts = parse_iso(r.get("timestamp") or "")
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


def scan_codex(agent, session_dirs=None):
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
    for d in session_dirs or [CODEX_SESSIONS]:
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
        recent = mtime >= CUTOFF_TS
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
                    ts = parse_iso(r.get("timestamp") or "")
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
            latest_quota_ts, _RUNTIME_TZ
        ).isoformat(timespec="seconds"),
    }
    return found, {"ts": latest_quota_ts, "quota": quota}


# ---------------------------------------------------------------- cc-switch services

def http_get_json(url, headers):
    override = _RUNTIME_HTTP.get("get_json")
    if override:
        return override(url, headers)
    req = urllib.request.Request(url, headers=headers)
    with _urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def epoch_from_iso(ts):
    t = parse_iso(ts or "")
    return int(t) if t else None


KIMI_STATS_URL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
KIMI_SUB_URL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription"
KIMI_REFRESH_URL = "https://www.kimi.com/api/auth/token/refresh"


def http_post_json(url, payload, headers):
    override = _RUNTIME_HTTP.get("post_json")
    if override:
        return override(url, payload, headers)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with _urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _kimi_web_refresh(tokens):
    """Refresh Kimi credentials and return an App-owned update candidate."""
    try:
        d = http_post_json(
            KIMI_REFRESH_URL,
            {"refresh_token": tokens.get("refresh_token", "")},
            {"Content-Type": "application/json"},
        )
        new = {
            "access_token": d.get("access_token") or "",
            "refresh_token": d.get("refresh_token") or tokens.get("refresh_token", ""),
        }
        if new["access_token"]:
            _record_credential_update("kimi", "default", new)
            if "kimi_web_tokens" in _RUNTIME_CREDENTIALS or _APP_MODE:
                return new
            with open(KIMI_WEB_TOKENS, "w") as f:
                json.dump(new, f)
            os.chmod(KIMI_WEB_TOKENS, 0o600)
            return new
    except Exception:
        pass
    return None


def service_kimi_coding(env):
    """Kimi For Coding 额度：统一走网页端 GetSubscriptionStats 一处取数，
    单次返回 5h 频控 / 7 天额度 / 月度共享池 / 赠送额度 / 加油包 全部窗口。
    登录态为本机浏览器的 kimi.com 令牌（access 到期自动 refresh）。"""
    injected_tokens = _runtime_credential("kimi_web_tokens")
    if injected_tokens is not None:
        tokens = dict(injected_tokens)
    else:
        if _APP_MODE:
            return None
        if not os.path.exists(KIMI_WEB_TOKENS):
            return None
        try:
            with open(KIMI_WEB_TOKENS) as f:
                tokens = json.load(f)
        except Exception:
            return None

    d = None
    for _ in range(2):
        try:
            d = http_post_json(
                KIMI_STATS_URL, {},
                {"Authorization": "Bearer " + tokens.get("access_token", ""),
                 "Content-Type": "application/json"},
            )
            break
        except Exception:
            tokens = _kimi_web_refresh(tokens) or {}
            if not tokens:
                return None
    if d is None:
        return None

    windows = []
    r5 = d.get("ratelimitCode5h") or {}
    windows.append(
        {
            "label": "5小时窗口",
            "usedPercent": float(r5.get("ratio") or 0) * 100,
            "windowMinutes": 300,
            "resetsAt": epoch_from_iso(r5.get("resetTime")),
        }
    )
    r7 = d.get("ratelimitCode7d") or {}
    windows.append(
        {
            "label": "7天窗口",
            "usedPercent": float(r7.get("ratio") or 0) * 100,
            "windowMinutes": 7 * 24 * 60,
            "resetsAt": epoch_from_iso(r7.get("resetTime")),
        }
    )
    sb = d.get("subscriptionBalance") or {}
    if sb:
        windows.append(
            {
                "label": "每月窗口",
                "usedPercent": float(sb.get("amountUsedRatio") or 0) * 100,
                "windowMinutes": None,
                "resetsAt": epoch_from_iso(sb.get("expireTime")),
            }
        )

    plan = None
    try:
        sub = http_post_json(
            KIMI_SUB_URL, {},
            {"Authorization": "Bearer " + tokens.get("access_token", ""),
             "Content-Type": "application/json"},
        )
        m = re.search(r"(Andante|Moderato|Allegretto|Allegro)", json.dumps(sub))
        plan = m.group(1) if m else None
    except Exception:
        pass

    # 赠送额度：单独占一行的量条
    gifts = d.get("giftBalances") or []
    if gifts:
        g = gifts[0]
        windows.append(
            {
                "label": "赠送额度",
                "usedPercent": float(g.get("amountUsedRatio") or 0) * 100,
                "windowMinutes": None,
                "resetsAt": epoch_from_iso(g.get("expireTime")),
                "ownRow": True,
            }
        )

    extras = []
    wallets = d.get("boosterWallets") or []
    if wallets:
        status = str(wallets[0].get("status") or "")
        if "DISABLED" in status:
            extras.append("加量包未启用")
        else:
            cents = ((wallets[0].get("moneyLeft") or {}).get("priceInCents")) or "0"
            extras.append("加量包余额 ¥%.2f" % (int(cents) / 100.0))
    return {"kind": "windows", "plan": plan, "windows": windows, "extra": " · ".join(extras) or None}


def service_deepseek(env):
    key = env.get("ANTHROPIC_AUTH_TOKEN") or ""
    if not key:
        return None
    d = http_get_json(
        "https://api.deepseek.com/user/balance",
        {"Authorization": "Bearer " + key, "Accept": "application/json"},
    )
    infos = d.get("balance_infos") or []
    if not infos:
        return None
    info = infos[0]
    return {
        "kind": "balance",
        "plan": None,
        "windows": [],
        "balance": float(info.get("total_balance") or 0),
        "currency": info.get("currency") or "CNY",
    }


def _volc_decode_secret(raw):
    candidates = [raw]
    cur = raw
    for _ in range(2):
        try:
            dec = base64.b64decode(cur).decode("utf-8")
        except Exception:
            break
        candidates.append(dec)
        cur = dec
    return candidates


def _volc_sign(method, host, query, payload, ak, sk, region="cn-beijing", service="ark"):
    x_date = now.astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    short_date = x_date[:8]
    payload_hash = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    headers = {
        "host": host,
        "x-date": x_date,
        "x-content-sha256": payload_hash,
        "content-type": "application/json; charset=utf-8",
    }
    signed = "host;x-date;x-content-sha256;content-type"
    canonical_headers = "".join("%s:%s\n" % (k, headers[k]) for k in signed.split(";"))
    canonical_query = urllib.parse.urlencode(sorted(query.items()))
    canonical = "\n".join(
        [method, "/", canonical_query, canonical_headers, signed, payload_hash]
    )
    scope = "%s/%s/%s/request" % (short_date, region, service)
    to_sign = "\n".join(
        ["HMAC-SHA256", x_date, scope, hashlib.sha256(canonical.encode()).hexdigest()]
    )
    k_date = hmac.new(sk.encode(), short_date.encode(), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode(), hashlib.sha256).digest()
    k_signing = hmac.new(k_service, b"request", hashlib.sha256).digest()
    signature = hmac.new(k_signing, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (
        "HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
        % (ak, scope, signed, signature)
    )
    return headers


def service_volcengine(env, meta):
    us = meta.get("usage_script") or {}
    ak = us.get("accessKeyId") or meta.get("accessKeyId") or ""
    sk_raw = us.get("secretAccessKey") or meta.get("secretAccessKey") or ""
    if not ak or not sk_raw:
        return None
    host = "open.volcengineapi.com"
    last_err = None
    for sk in _volc_decode_secret(sk_raw):
        for action in ("GetCodingPlanUsage", "GetAFPUsage"):
            try:
                query = {"Action": action, "Version": "2024-01-01"}
                headers = _volc_sign("GET", host, query, "", ak, sk)
                headers.pop("host", None)
                url = "https://%s/?%s" % (host, urllib.parse.urlencode(query))
                d = http_get_json(url, headers)
                result = d.get("Result") or d.get("result") or d
                return _volc_parse(result)
            except Exception as e:  # try next candidate/action
                last_err = e
                continue
    raise last_err or RuntimeError("volcengine query failed")


def _volc_parse(result):
    windows = []
    label_map = {"session": "5小时窗口", "weekly": "每周窗口", "monthly": "每月窗口"}
    quota_usage = result.get("QuotaUsage") if isinstance(result, dict) else None
    if isinstance(quota_usage, list):
        for item in quota_usage:
            level = str(item.get("Level") or "").lower()
            label = label_map.get(level, level or "窗口")
            pct = item.get("Percent")
            if pct is None:
                continue
            reset_ts = item.get("ResetTimestamp")
            # 火山 GetCodingPlanUsage 对未开始的窗口 (如未使用的 5 小时窗口) 返回
            # ResetTimestamp=-1, 透传会被下游解析成 1970 误判「已到期」, 非正数一律置 None
            if isinstance(reset_ts, (int, float)) and reset_ts <= 0:
                reset_ts = None
            windows.append(
                {
                    "label": label,
                    "usedPercent": max(0.0, min(100.0, float(pct))),
                    "windowMinutes": None,
                    "resetsAt": reset_ts,
                }
            )
        # Status (如 running) 是订阅生命周期状态, 不是套餐信息, 不上卡片
        plan = None
        return {"kind": "windows", "plan": plan, "windows": windows}

    def pick(node, names):
        if not isinstance(node, dict):
            return None
        for n in names:
            for k, v in node.items():
                if k.lower() == n.lower():
                    return v
        return None

    def window_from(node, label):
        if not isinstance(node, dict):
            return
        limit = pick(node, ["Limit", "Total", "Quota", "TotalQuota"])
        used = pick(node, ["Used", "Usage", "UsedQuota"])
        remain = pick(node, ["Remaining", "Remain"])
        reset = pick(node, ["ResetTime", "QuotaResetTime"])
        try:
            if limit and used is not None:
                pct = float(used) / float(limit) * 100
            elif limit and remain is not None:
                pct = (1 - float(remain) / float(limit)) * 100
            else:
                return
        except (TypeError, ValueError, ZeroDivisionError):
            return
        windows.append(
            {
                "label": label,
                "usedPercent": max(0.0, min(100.0, pct)),
                "windowMinutes": None,
                "resetsAt": epoch_from_iso(reset) if isinstance(reset, str) else reset,
            }
        )

    window_from(pick(result, ["AFPFiveHour", "FiveHour"]), "5小时窗口")
    window_from(pick(result, ["AFPWeekly", "Weekly"]), "每周窗口")
    window_from(pick(result, ["AFPMonthly", "Monthly"]), "每月窗口")
    if not windows and isinstance(result, dict):
        # flat structure: search one level deep for anything quota-like
        for k, v in result.items():
            lk = k.lower()
            if "fivehour" in lk or "5hour" in lk:
                window_from(v, "5小时窗口")
            elif "weekly" in lk or "week" in lk:
                window_from(v, "每周窗口")
            elif "monthly" in lk or "month" in lk:
                window_from(v, "每月窗口")
    plan = None
    for k in ("PlanType", "Plan", "PlanName"):
        if isinstance(result, dict) and result.get(k):
            plan = str(result[k])
            break
    return {"kind": "windows", "plan": plan, "windows": windows}


# ---------------------------------------------------------------- codex multi-account

def _codex_window_label(seconds):
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return "窗口"
    if s <= 6 * 3600:
        return "5小时窗口"
    if s <= 8 * 24 * 3600:
        return "每周窗口"
    return "每月窗口"


def _codex_refresh(refresh_token):
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "client_id": CODEX_OAUTH_CLIENT_ID,
            "refresh_token": refresh_token,
        }
    ).encode()
    req = urllib.request.Request(
        CODEX_TOKEN_URL,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with _urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def _codex_query_single_account(acc_id, access_token, display_name, style):
    """查询单账号 wham/usage 额度, 两种调用方共用同一查询主体.

    style="app": 消费注入的短期 access token, 错误分类生成固定文案
    (401 -> accessRejected challenge; 403 -> 权限/套餐错误; 其余 -> 暂时
    失败), 不解析响应体进 note. style="legacy": 保留 CLI 兼容行为, 错误
    文案带原始消息.
    """
    svc = {
        "id": "codex_" + (acc_id or "unknown")[:8],
        "name": "Codex · " + (display_name or "账号"),
        "app": "codex",
        "isCurrent": False,
        "status": "ok",
        "kind": None,
        "plan": None,
        "windows": [],
        "balance": None,
        "currency": None,
        "capturedAt": now.isoformat(timespec="seconds"),
        "note": "",
    }
    try:
        d = http_get_json(
            CODEX_USAGE_URL,
            {
                "Authorization": "Bearer " + (access_token or ""),
                "chatgpt-account-id": acc_id or "",
                "User-Agent": "codex-cli/1.0",
                "Accept": "application/json",
            },
        )
        windows = []
        rl = d.get("rate_limit") or {}
        for key in ("primary_window", "secondary_window"):
            w = rl.get(key)
            if not w:
                continue
            secs = w.get("limit_window_seconds")
            windows.append(
                {
                    "label": _codex_window_label(secs),
                    "usedPercent": max(0.0, min(100.0, float(w.get("used_percent") or 0))),
                    "windowMinutes": int(secs) // 60 if secs else None,
                    "resetsAt": w.get("reset_at"),
                }
            )
        extra = None
        cr = d.get("credits") or {}
        if cr.get("unlimited"):
            extra = "Credits 不限量"
        elif cr.get("has_credits"):
            extra = "Credits 余额 " + str(cr.get("balance"))
        svc.update(
            {
                "kind": "windows",
                "plan": d.get("plan_type") or None,
                "windows": windows,
                "extra": extra,
            }
        )
        if not windows:
            svc["status"] = "empty"
            svc["note"] = "接口已通但未返回额度窗口"
    except Exception as e:
        code = getattr(e, "code", None)
        if style == "app":
            message = str(e)
            if code == 401 or "HTTP 401" in message:
                svc["status"] = "error"
                svc["note"] = "登录态已失效, 请重新登录该账号"
                with _CREDENTIAL_UPDATE_LOCK:
                    _RUNTIME_CREDENTIAL_CHALLENGES.append(
                        {
                            "provider": "codex",
                            "accountId": acc_id,
                            "reason": "accessRejected",
                        }
                    )
            elif code == 403 or "HTTP 403" in message:
                svc["status"] = "error"
                svc["note"] = "当前账号无权访问该额度接口"
            else:
                svc["status"] = "error"
                svc["note"] = "额度查询暂时失败, 请稍后重试"
        else:
            svc["status"] = "error"
            msg = str(e)
            svc["note"] = ("查询失败: " + msg[:60]) if msg else "查询失败"
    return svc


def service_codex_accounts():
    """查询 Codex OAuth 多账号的实时额度.

    App access-only 路径: 只消费注入的 `codex_quota_accounts` (每账号仅
    display_name + 短期 access_token), 直接请求 wham/usage; 无刷新, 无
    磁盘读取, 无 rotation update, 401 记录定向 challenge.
    CLI legacy 路径: 未注入时保留原行为 (读 CC Switch / Codex CLI 认证
    文件, candidates 轮换重试, CLI 文件写回).
    """
    injected_accounts = _runtime_credential("codex_quota_accounts")
    if injected_accounts is not None:
        accounts = json.loads(json.dumps(injected_accounts))
        with ThreadPoolExecutor(max_workers=min(4, len(accounts))) as pool:
            services = [
                svc
                for svc in pool.map(
                    lambda item: _codex_query_single_account(
                        item[0],
                        (item[1] or {}).get("access_token"),
                        (item[1] or {}).get("display_name"),
                        "app",
                    ),
                    accounts.items(),
                )
            ]
        return services

    injected_oauth = _runtime_credential("codex_oauth_auth")
    if injected_oauth is not None:
        data = json.loads(json.dumps(injected_oauth))
    else:
        if _APP_MODE:
            return []
        if not os.path.exists(CODEX_OAUTH_AUTH):
            return []
        try:
            with open(CODEX_OAUTH_AUTH, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            return []
    accounts = data.get("accounts") or {}
    if not accounts:
        return []
    active_id = None
    cli_auth = None
    cli_tokens = {}
    injected_cli_auth = _runtime_credential("codex_auth")
    if injected_cli_auth is not None:
        cli_auth = json.loads(json.dumps(injected_cli_auth))
        cli_tokens = cli_auth.get("tokens") or {}
        active_id = cli_tokens.get("account_id")
    elif not _APP_MODE:
        # CLI 兼容模式读本机 CLI 侧认证; App 模式凭证只经注入, 不读盘
        try:
            with open(CODEX_AUTH, encoding="utf-8") as fh:
                cli_auth = json.load(fh)
            cli_tokens = cli_auth.get("tokens") or {}
            active_id = cli_tokens.get("account_id")
        except Exception:
            pass
    def query_account(item):
        """单账号查询: 账号内 candidates 顺序重试保持串行 (refresh token
        一次性轮换语义不变); 返回 (svc, 凭证是否变化, CLI 侧是否轮换),
        CLI 模式文件写回由主线程在 join 后统一执行."""
        acc_id, acc = item
        acc_changed = False
        acc_cli_rotated = False
        email = acc.get("email") or (acc_id[:8] if acc_id else "未知账号")
        try:
            # OpenAI refresh_token 用一次即轮换，且 Codex CLI 与 CC Switch 各存一份。
            # 当前账号优先用 CLI 侧（~/.codex/auth.json，通常最新），失败再试 CC 侧。
            candidates = []
            if acc_id == active_id and cli_tokens.get("refresh_token"):
                candidates.append(cli_tokens["refresh_token"])
            cc_rt = acc.get("refresh_token") or ""
            if cc_rt and cc_rt not in candidates:
                candidates.append(cc_rt)
            tokens = None
            for rt in candidates:
                try:
                    tokens = _codex_refresh(rt)
                    break
                except Exception:
                    continue
            if tokens is None:
                raise RuntimeError("登录态已失效，请重新登录该账号")
            if tokens.get("refresh_token"):
                acc["refresh_token"] = tokens["refresh_token"]
                acc_changed = True
            for k in ("access_token", "id_token"):
                if tokens.get(k):
                    acc[k] = tokens[k]
            _record_credential_update("codex", acc_id, tokens)
            # 轮换后的新令牌同步写回 CLI 侧，避免下次 CLI 自己刷新时令牌被作废
            if acc_id == active_id and cli_auth is not None and tokens.get("refresh_token"):
                for k in ("access_token", "id_token", "refresh_token"):
                    if tokens.get(k):
                        cli_tokens[k] = tokens[k]
                acc_cli_rotated = True
            access_token = tokens.get("access_token") or acc.get("access_token") or ""
            svc = _codex_query_single_account(
                acc_id, access_token, email.split("@")[0], "legacy"
            )
        except Exception as e:
            svc = {
                "id": "codex_" + (acc_id or "unknown")[:8],
                "name": "Codex · " + email.split("@")[0],
                "app": "codex",
                "isCurrent": acc_id == active_id,
                "status": "error",
                "kind": None,
                "plan": None,
                "windows": [],
                "balance": None,
                "currency": None,
                "capturedAt": now.isoformat(timespec="seconds"),
                "note": ("查询失败: " + str(e)[:60]) if str(e) else "查询失败",
            }
        return svc, acc_changed, acc_cli_rotated

    # 跨账号并行 (每账号一个 future, map 保持账号顺序); 各 worker 只写
    # 自己账号的 acc 与 (仅活跃账号的) cli_tokens, 无共享可变状态冲突
    services = []
    changed = False
    cli_rotated = False
    with ThreadPoolExecutor(max_workers=min(4, len(accounts))) as pool:
        for svc, acc_changed, acc_cli_rotated in pool.map(
            query_account, accounts.items()
        ):
            services.append(svc)
            changed = changed or acc_changed
            cli_rotated = cli_rotated or acc_cli_rotated
    if changed and injected_oauth is None and not _APP_MODE:
        try:
            shutil.copy2(CODEX_OAUTH_AUTH, CODEX_OAUTH_AUTH + ".bak-kimi")
            with open(CODEX_OAUTH_AUTH, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
            os.chmod(CODEX_OAUTH_AUTH, 0o600)
        except Exception:
            pass
    if (
        cli_rotated
        and cli_auth is not None
        and injected_cli_auth is None
        and not _APP_MODE
    ):
        try:
            cli_auth["tokens"] = cli_tokens
            shutil.copy2(CODEX_AUTH, CODEX_AUTH + ".bak-kimi")
            with open(CODEX_AUTH, "w", encoding="utf-8") as fh:
                json.dump(cli_auth, fh, ensure_ascii=False, indent=2)
            os.chmod(CODEX_AUTH, 0o600)
        except Exception:
            pass
    return services


# ---------------------------------------------------------------- antigravity (agy)

def _security_find_generic_password(service, account):
    """包装 security CLI 读取登录 Keychain 通用密码, 便于测试替换; 未找到返回 None."""
    try:
        proc = subprocess.run(
            ["/usr/bin/security", "find-generic-password",
             "-s", service, "-a", account, "-w"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _load_agy_oauth():
    """读取 agy OAuth 凭证, 返回 (data, source); source 为 "file" 或 "keychain".

    agy < 1.1.8 写令牌文件; >= 1.1.8 改用登录 Keychain (go-keyring,
    值带 "go-keyring-base64:" 前缀的 base64 JSON). 均无凭证返回 (None, None).
    """
    if os.path.exists(AGY_OAUTH_TOKEN):
        with open(AGY_OAUTH_TOKEN, encoding="utf-8") as fh:
            return json.load(fh), "file"
    raw = _security_find_generic_password(AGY_KEYCHAIN_SERVICE, AGY_KEYCHAIN_ACCOUNT)
    if not raw:
        return None, None
    prefix = "go-keyring-base64:"
    if raw.startswith(prefix):
        try:
            raw = base64.b64decode(raw[len(prefix):]).decode("utf-8", "replace")
        except Exception:
            return None, None
    try:
        return json.loads(raw), "keychain"
    except Exception:
        return None, None


def service_antigravity():
    """读取 agy (Antigravity CLI) 的 Google OAuth 凭证，查询分组额度。

    CLI 兼容模式会写回刷新后的 access token (仅文件来源; Keychain 来源只读,
    不回写第三方钥匙串). App 模式只返回候选更新.
    agy 不在本地记录 token 用量，只提供额度与活动计数。
    """
    injected_auth = _runtime_credential("antigravity_oauth")
    source = None
    if injected_auth is not None:
        data = json.loads(json.dumps(injected_auth))
    else:
        if _APP_MODE:
            return []
        try:
            data, source = _load_agy_oauth()
        except Exception:
            return []
        if data is None:
            return []
    svc = {
        "id": "antigravity",
        "name": "Antigravity",
        "app": "antigravity",
        "isCurrent": False,
        "status": "ok",
        "kind": None,
        "plan": None,
        "windows": [],
        "balance": None,
        "currency": None,
        "capturedAt": now.isoformat(timespec="seconds"),
        "note": "",
    }
    try:
        tok = data.get("token") or {}
        body = urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "client_id": AGY_CLIENT_ID,
                "client_secret": AGY_CLIENT_SECRET,
                "refresh_token": tok.get("refresh_token") or "",
            }
        ).encode()
        req = urllib.request.Request(
            "https://oauth2.googleapis.com/token",
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with _urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            refreshed = json.loads(resp.read().decode("utf-8", "replace"))
        access_token = refreshed.get("access_token") or tok.get("access_token") or ""
        if refreshed.get("access_token"):
            tok["access_token"] = refreshed["access_token"]
            if refreshed.get("expires_in"):
                tok["expiry"] = (
                    now + datetime.timedelta(seconds=int(refreshed["expires_in"]) - 60)
                ).isoformat()
            _record_credential_update("antigravity", "default", tok)
            if source == "file":
                # 仅文件来源写回刷新后的令牌; Keychain 来源只读, 不动第三方钥匙串
                try:
                    shutil.copy2(AGY_OAUTH_TOKEN, AGY_OAUTH_TOKEN + ".bak-kimi")
                    with open(AGY_OAUTH_TOKEN, "w", encoding="utf-8") as fh:
                        json.dump(data, fh, ensure_ascii=False, indent=2)
                    os.chmod(AGY_OAUTH_TOKEN, 0o600)
                except Exception:
                    pass
        req = urllib.request.Request(
            AGY_QUOTA_URL,
            data=b"{}",
            method="POST",
            headers={
                "Authorization": "Bearer " + access_token,
                "Content-Type": "application/json",
                "User-Agent": "antigravity/1.1.6 darwin/arm64",
            },
        )
        with _urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            q = json.loads(resp.read().decode("utf-8", "replace"))
        # 跨模型分组聚合: 不同模型池各自有 quota bucket, 按窗口类型合并,
        # 取用量最高的池作为约束 (额度够不够由最紧张的池决定),
        # 重置时间跟随该池; 不再按模型单独展示剩余用量.
        merged = {}
        for g in q.get("groups") or []:
            for b in g.get("buckets") or []:
                frac = b.get("remainingFraction")
                if frac is None:
                    continue
                win = b.get("window") or ""
                used = max(0.0, min(100.0, (1 - float(frac)) * 100))
                cur = merged.get(win)
                if cur is None or used > cur["usedPercent"]:
                    merged[win] = {
                        "usedPercent": used,
                        "resetsAt": epoch_from_iso(b.get("resetTime")),
                    }
        window_order = {"5h": 0, "weekly": 1, "monthly": 2}
        window_labels = {"5h": "5小时窗口", "weekly": "每周窗口", "monthly": "每月窗口"}
        windows = []
        for win in sorted(merged, key=lambda w: window_order.get(w, 99)):
            entry = merged[win]
            windows.append(
                {
                    "label": window_labels.get(win, win or "窗口"),
                    "usedPercent": entry["usedPercent"],
                    "windowMinutes": 300 if win == "5h" else None,
                    "resetsAt": entry["resetsAt"],
                }
            )
        extra = None
        summaries_error = False
        if os.path.exists(AGY_SUMMARIES_DB):
            try:
                with sqlite3.connect(
                    "file:%s?mode=ro" % AGY_SUMMARIES_DB, uri=True
                ) as db:
                    row = db.execute(
                        "SELECT COUNT(*), COALESCE(SUM(step_count),0) "
                        "FROM conversation_summaries "
                        "WHERE date(last_modified_time) = date(?)",
                        (TODAY,),
                    ).fetchone()
                if row and row[0]:
                    extra = "今日 %d 个会话 · %d 步" % (row[0], row[1])
                else:
                    extra = "agy 不在本地记录 token 用量"
            except sqlite3.Error as e:
                # 只有缺表/缺列才是 schema 不兼容; 占用等其他错误如实展示
                summaries_error = True
                msg = str(e)
                if "no such table" in msg or "no such column" in msg:
                    extra = "本机会话库 schema 不兼容"
                else:
                    extra = "本机会话库暂不可读: " + msg[:40]
        svc.update({"kind": "windows", "plan": None, "windows": windows, "extra": extra})
        if summaries_error:
            svc["status"] = "partial"
            svc["note"] = "额度可用, " + extra
        if not windows:
            svc["status"] = "empty"
            svc["note"] = "接口已通但未返回额度窗口"
    except Exception as e:
        svc["status"] = "error"
        msg = str(e)
        svc["note"] = ("查询失败: " + msg[:60]) if msg else "查询失败"
    return [svc]


def _quota_service_entry(service_id, name, app):
    """App 模式合成条目模板: 字段与 CC 驱动条目同构; 无 CC 概念, isCurrent 置 False."""
    return {
        "id": service_id,
        "name": name,
        "app": app,
        "isCurrent": False,
        "status": "ok",
        "kind": None,
        "plan": None,
        "windows": [],
        "balance": None,
        "currency": None,
        "capturedAt": now.isoformat(timespec="seconds"),
        "note": "",
    }


def _finalize_quota_service(svc, query):
    """执行额度查询并折叠结果/错误, 与 CC 驱动路径共用同一套 status/note 语义."""
    try:
        result = query()
        if result:
            svc.update(result)
            if svc["kind"] == "windows" and not svc["windows"]:
                svc["status"] = "empty"
                svc["note"] = "接口已通但未返回额度窗口"
        else:
            svc["status"] = "empty"
            svc["note"] = "未取到额度数据"
    except Exception as e:
        svc["status"] = "error"
        msg = str(e)
        svc["note"] = ("查询失败: " + msg[:60]) if msg else "查询失败"
    return svc


def _collect_app_services():
    """App 模式: 由注入凭证驱动合成额度条目, 完全不读取 CC Switch 数据库.

    - kimi_web_tokens -> Kimi (service_kimi_coding 注入分支)
    - provider_env.deepseek.ANTHROPIC_AUTH_TOKEN -> DeepSeek
    - provider_meta.volcengine.usage_script.ak/sk -> 火山引擎
    """
    services = []
    provider_env = _runtime_credential("provider_env") or {}
    provider_meta = _runtime_credential("provider_meta") or {}

    if _runtime_credential("kimi_web_tokens") is not None:
        svc = _quota_service_entry("kimi_coding", "Kimi", "kimi")
        services.append(
            _finalize_quota_service(svc, lambda: service_kimi_coding({}))
        )

    deepseek_env = provider_env.get("deepseek") or {}
    if deepseek_env.get("ANTHROPIC_AUTH_TOKEN"):
        svc = _quota_service_entry("deepseek", "DeepSeek", "deepseek")
        services.append(
            _finalize_quota_service(
                svc, lambda: service_deepseek(dict(deepseek_env))
            )
        )

    volc_meta = provider_meta.get("volcengine") or {}
    volc_script = volc_meta.get("usage_script") or {}
    if volc_script.get("accessKeyId") and volc_script.get("secretAccessKey"):
        svc = _quota_service_entry("volcengine", "火山引擎（Coding Plan）", "volcengine")
        services.append(
            _finalize_quota_service(
                svc, lambda: service_volcengine({}, dict(volc_meta))
            )
        )

    return services


def collect_services():
    if _APP_MODE:
        return _collect_app_services()
    services = []
    if not os.path.exists(CC_SWITCH_DB):
        return services
    try:
        with sqlite3.connect("file:%s?mode=ro" % CC_SWITCH_DB, uri=True) as db:
            rows = db.execute(
                "SELECT id, name, app_type, settings_config, meta, is_current "
                "FROM providers"
            ).fetchall()
    except sqlite3.Error:
        return [
            {
                "id": "cc_switch_schema",
                "name": "CC Switch",
                "app": "cc-switch",
                "isCurrent": False,
                "status": "error",
                "kind": None,
                "plan": None,
                "windows": [],
                "balance": None,
                "currency": None,
                "capturedAt": now.isoformat(timespec="seconds"),
                "note": "只读数据库 schema 不兼容",
            }
        ]

    handlers = {
        "Kimi For Coding": ("kimi_coding", service_kimi_coding),
        "DeepSeek": ("deepseek", service_deepseek),
        "火山Codingplan": ("volcengine", None),  # needs meta
    }
    # 看板展示名（cc-switch 里的 provider 名不动，仅改显示）
    display_names = {
        "Kimi For Coding": "Kimi",
        "火山Codingplan": "火山引擎（Coding Plan）",
    }
    for pid, name, app_type, settings_config, meta_json, is_current in rows:
        if name not in handlers:
            continue
        svc = {
            "id": handlers[name][0],
            "name": display_names.get(name, name),
            "app": app_type,
            "isCurrent": bool(is_current),
            "status": "ok",
            "kind": None,
            "plan": None,
            "windows": [],
            "balance": None,
            "currency": None,
            "capturedAt": now.isoformat(timespec="seconds"),
            "note": "",
        }
        try:
            env = (json.loads(settings_config or "{}")).get("env") or {}
            meta = json.loads(meta_json or "{}")
            provider_env = _runtime_credential("provider_env", {})
            env.update(provider_env.get(svc["id"], {}))
            provider_meta = _runtime_credential("provider_meta", {})
            meta.update(provider_meta.get(svc["id"], {}))
            if name == "火山Codingplan":
                result = service_volcengine(env, meta)
            else:
                result = handlers[name][1](env)
            if result:
                svc.update(result)
                if svc["kind"] == "windows" and not svc["windows"]:
                    svc["status"] = "empty"
                    svc["note"] = "接口已通但未返回额度窗口"
            else:
                svc["status"] = "empty"
                svc["note"] = "未取到额度数据"
        except Exception as e:
            svc["status"] = "error"
            msg = str(e)
            svc["note"] = ("查询失败: " + msg[:60]) if msg else "查询失败"
        services.append(svc)
    return services


# ---------------------------------------------------------------- main

def _mark_sessions_denied(agent):
    agent["status"] = "unavailable"
    agent["note"] = "未授权 localSessions 能力, 已跳过本机会话扫描"


def _quota_denied_service(service_id, name, app):
    return {
        "id": service_id,
        "name": name,
        "app": app,
        "isCurrent": False,
        "status": "partial",
        "kind": None,
        "plan": None,
        "windows": [],
        "balance": None,
        "currency": None,
        "capturedAt": now.isoformat(timespec="seconds"),
        "note": "未授权 externalQuotas 能力, 已跳过云端额度查询",
    }


def _quota_denied_services():
    return [
        _quota_denied_service("cc_switch_providers", "CC Switch 云端额度", "cc-switch"),
        _quota_denied_service("antigravity", "Antigravity", "antigravity"),
        _quota_denied_service("codex_accounts", "Codex 账号额度", "codex"),
    ]


def collect_codex_quota_retry_only(ctx):
    """App 定向重试: 只构造 Codex service 部分 artifact.

    不扫描本地会话, 不加载定价, 不调用其他 provider. 保留 agent-usage
    契约结构 (agents/services/totalCostUsd), agents 为空数组.
    """
    _configure_runtime(ctx)
    codex_svcs = service_codex_accounts()
    return {
        "generatedAt": now.isoformat(timespec="seconds"),
        "agents": [],
        "services": codex_svcs,
        "totalCostUsd": None,
    }


def collect(ctx=None):
    _configure_runtime(ctx)
    # 未授权 localPricing 时降级为空定价, 成本估算全部为 None
    pricing = load_pricing() if _capability_allowed("localPricing") else {}
    sessions_allowed = _capability_allowed("localSessions")

    def kimi_cli_project(path):
        # .../sessions/wd_<name>_<hash>/conv-xxx/agents/main/wire.jsonl
        parts = path.split(os.sep)
        for p in parts:
            if p.startswith("wd_"):
                return p[3:].rsplit("_", 1)[0].replace("-", "/") or p
        return None

    # Orca 用自己的 CODEX_HOME 托管运行 Codex, 会话不在 ~/.codex 下;
    # 扫描时灌进同一个 codex agent, record_usage 桶自动合并
    def orca_account_label():
        try:
            orca_auth = _runtime_credential("orca_codex_auth")
            if orca_auth is not None:
                acc_id = (orca_auth.get("tokens") or {}).get("account_id")
            elif _APP_MODE:
                return None
            else:
                with open(
                    os.path.join(
                        ORCA_HOME, "codex-runtime-home/home/auth.json"
                    ),
                    encoding="utf-8",
                ) as fh:
                    acc_id = (json.load(fh).get("tokens") or {}).get("account_id")
            oauth_data = _runtime_credential("codex_oauth_auth")
            if oauth_data is None and acc_id and os.path.exists(CODEX_OAUTH_AUTH):
                with open(CODEX_OAUTH_AUTH, encoding="utf-8") as fh:
                    oauth_data = json.load(fh)
            if acc_id and oauth_data:
                acc = (oauth_data.get("accounts") or {}).get(acc_id) or {}
                email = acc.get("email")
                if email:
                    return email.split("@")[0]
            return acc_id[:8] if acc_id else None
        except Exception:
            return None

    def build_kimi_work():
        agent = make_agent("kimi-work", "Kimi Work")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_kimi(agent, DAIMON_KIMI_SESSIONS):
            agent["note"] = "额度见下方 Kimi 服务"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing)

    def build_kimi_cli():
        agent = make_agent("kimi-code-cli", "Kimi Code CLI")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_kimi(agent, KIMI_CLI_SESSIONS, project_from_path=kimi_cli_project):
            agent["note"] = "额度见下方 Kimi 服务"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing)

    def build_claude():
        agent = make_agent("claude-code", "Claude Code")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_claude(agent):
            agent["note"] = "当前经 CC Switch 路由，额度见下方对应服务"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing)

    def build_codex():
        agent = make_agent("codex", "Codex")
        quota_candidate = None
        found_cli = False
        found_orca = False
        if sessions_allowed:
            found_cli, candidate = scan_codex(agent)
            if candidate:
                quota_candidate = candidate
            # Orca 托管会话灌进同一 agent; quota 取两侧候选中 ts 最大者
            if os.path.isdir(ORCA_HOME):
                orca_dirs = [ORCA_CODEX_SESSIONS] + glob.glob(
                    os.path.join(ORCA_CODEX_ACCOUNTS, "*/home/sessions")
                )
                found_orca, candidate = scan_codex(agent, orca_dirs)
                if candidate and (
                    quota_candidate is None
                    or candidate["ts"] > quota_candidate["ts"]
                ):
                    quota_candidate = candidate
        agent["quota"] = quota_candidate["quota"] if quota_candidate else None
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif found_cli or found_orca:
            agent["note"] = "额度见下方 Codex 账号（实时查询）"
            if found_orca:
                label = orca_account_label()
                agent["note"] += " · 含 Orca 托管会话" + (
                    " · 账号 " + label if label else ""
                )
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing)

    # 4 个本地扫描互不共享状态 (各自累积独立 agent, 全局窗口配置只读),
    # 并行执行; join 后按固定顺序组装, artifact 结构不变
    builders = [build_kimi_work, build_kimi_cli, build_claude, build_codex]
    with ThreadPoolExecutor(max_workers=4) as pool:
        agents = list(pool.map(lambda build: build(), builders))

    if _capability_allowed("externalQuotas"):
        # 三路服务采集互不依赖 (CC 库为 mode=ro 独立连接), 并行后按原顺序拼接
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [
                pool.submit(collect_services),
                pool.submit(service_antigravity),
                pool.submit(service_codex_accounts),
            ]
            cc_services = futures[0].result()
            agy_services = futures[1].result()
            codex_svcs = futures[2].result()
        services = cc_services + agy_services + codex_svcs
        if any(s["status"] == "ok" and s["windows"] for s in codex_svcs):
            # 实时接口数据更准：隐藏 Codex agent 行上过期的会话快照额度
            for a in agents:
                if a["id"] == "codex":
                    a["quota"] = None
    else:
        # 未授权 externalQuotas: 不读 CC Switch settings_config/meta,
        # 不读 OAuth 文件, 不发 HTTP, 返回明确的未授权 warning 条目
        services = _quota_denied_services()

    total_cost = sum(a["todayCostUsd"] or 0 for a in agents)
    return {
        "generatedAt": now.isoformat(timespec="seconds"),
        "agents": agents,
        "services": services,
        "totalCostUsd": round(total_cost, 4) if total_cost > 0 else None,
    }


def run(ctx):
    return {"artifact": collect(ctx)}


def run_app(ctx):
    app_ctx = dict(ctx or {})
    app_ctx["app_mode"] = True
    if app_ctx.get("codex_quota_retry_only"):
        artifact = collect_codex_quota_retry_only(app_ctx)
    else:
        artifact = collect(app_ctx)
    return {
        "artifact": artifact,
        "credentialUpdates": json.loads(
            json.dumps(_RUNTIME_CREDENTIAL_UPDATES)
        ),
        "credentialChallenges": json.loads(
            json.dumps(_RUNTIME_CREDENTIAL_CHALLENGES)
        ),
    }


def main(argv=None, run_func=run):
    import argparse
    ap = argparse.ArgumentParser(description="采集本机 AI agent 用量与服务额度")
    ap.add_argument("--out", help="把结果 JSON 原子写入指定文件（缺省打印到 stdout）")
    args = ap.parse_args(argv)
    text = json.dumps(run_func({}), ensure_ascii=False, indent=2)
    if args.out:
        out = os.path.expanduser(args.out)
        parent = os.path.dirname(out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, out)  # 原子替换，避免读取方拿到半截文件
        print("written:", out)
    else:
        print(text)


if __name__ == "__main__":
    main()
