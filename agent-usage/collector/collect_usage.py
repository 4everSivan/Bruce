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

# 阶段 D: pricing 模块拆分. 本文件被 bridge/tests 用 importlib 从文件路径
# 加载 (__package__ 为空), 需把同目录加入 sys.path 才能 import 同级模块.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pricing import BUILTIN_PRICING, estimate_cost, load_pricing  # noqa: E402
import runtime
from runtime import day_of, hour_of, parse_iso, epoch_from_iso  # noqa: E402
import quota_services
import quota_official
import local_usage
from local_usage import finalize, make_agent, new_bucket, record_usage, scan_claude, scan_codex, scan_kimi  # noqa: E402
import codex_compat

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
    global _RUNTIME_CREDENTIALS
    global _RUNTIME_CONTEXT
    global _RUNTIME_CREDENTIAL_UPDATES, _RUNTIME_CAPABILITIES, _APP_MODE
    global _RUNTIME_CREDENTIAL_CHALLENGES
    global CODEX_TOKEN_URL, CODEX_USAGE_URL

    ctx = ctx or {}
    # 运行时上下文全量快照 (含 codex_quota_account_order 等协议映射键);
    # 每次运行重建, 禁止进程复用时残留 (任务 6, ORD-09).
    _RUNTIME_CONTEXT = dict(ctx)
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
    # Codex 出站 URL 覆盖: 仅接受进程内 runtime_overrides 注入 (本地 fake
    # server 测试用 loopback 地址), 不经 Bridge 协议序列化; 正式请求无法覆盖.
    if ctx.get("codex_usage_url"):
        CODEX_USAGE_URL = str(ctx["codex_usage_url"])
    if ctx.get("codex_token_url"):
        CODEX_TOKEN_URL = str(ctx["codex_token_url"])

    timezone_value = ctx.get("timezone")
    if isinstance(timezone_value, str):
        runtime._RUNTIME_TZ = ZoneInfo(timezone_value)
    elif isinstance(timezone_value, datetime.tzinfo):
        runtime._RUNTIME_TZ = timezone_value
    else:
        runtime._RUNTIME_TZ = datetime.datetime.now().astimezone().tzinfo

    now_value = ctx.get("now")
    if callable(now_value):
        now_value = now_value()
    if isinstance(now_value, str):
        now_value = datetime.datetime.fromisoformat(now_value.replace("Z", "+00:00"))
    if now_value is None:
        now_value = datetime.datetime.now(runtime._RUNTIME_TZ)
    if not isinstance(now_value, datetime.datetime):
        raise TypeError("ctx.now must be a datetime, ISO-8601 string, or callable")
    if now_value.tzinfo is None:
        now_value = now_value.replace(tzinfo=runtime._RUNTIME_TZ)
    now = now_value.astimezone(runtime._RUNTIME_TZ)

    DAYS = int(ctx.get("days", 14))
    if DAYS < 1:
        raise ValueError("ctx.days must be at least 1")
    HTTP_TIMEOUT = float(ctx.get("http_timeout", 8))
    runtime.set_date_buckets(
        now.strftime("%Y-%m-%d"),
        (now - datetime.timedelta(days=DAYS + 1)).timestamp(),
        [
            (now - datetime.timedelta(days=i)).strftime("%Y-%m-%d")
            for i in range(DAYS - 1, -1, -1)
        ],
    )
    runtime.set_http_overrides(dict(ctx.get("http") or {}))
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


def _runtime_context(name, default=None):
    """读取运行时顶层 context 键 (协议映射键, 如 codex_quota_account_order)."""
    return _RUNTIME_CONTEXT.get(name, default)


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
    return runtime.urlopen(request, **kwargs)



# ---------------------------------------------------------------- cc-switch services

def http_get_json(url, headers):
    return runtime.http_get_json(url, headers, HTTP_TIMEOUT)


KIMI_STATS_URL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
KIMI_SUB_URL = "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription"
KIMI_REFRESH_URL = "https://www.kimi.com/api/auth/token/refresh"


def http_post_json(url, payload, headers):
    return runtime.http_post_json(url, payload, headers, HTTP_TIMEOUT)


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


def record_codex_challenge(acc_id):
    """App 模式 401: 记录 accessRejected 定向重试挑战 (线程安全)."""
    with _CREDENTIAL_UPDATE_LOCK:
        _RUNTIME_CREDENTIAL_CHALLENGES.append(
            {
                "provider": "codex",
                "accountId": acc_id,
                "reason": "accessRejected",
            }
        )


def _codex_refresh(refresh_token):
    """CLI legacy refresh 的薄包装 (委托 codex_compat). 测试 monkeypatch 此名."""
    return codex_compat.refresh(
        refresh_token, CODEX_TOKEN_URL, CODEX_OAUTH_CLIENT_ID, _urlopen, HTTP_TIMEOUT
    )


# ---------------------------------------------------------------- codex multi-account


def service_codex_accounts():
    """查询 Codex OAuth 多账号的实时额度.

    App access-only 路径: 只消费注入的 `codex_quota_accounts` (每账号仅
    display_name + 短期 access_token), 直接请求 wham/usage; 无刷新, 无
    磁盘读取, 无 rotation update, 401 记录定向 challenge.
    按 `codex_quota_account_order` 调度并恢复输出顺序; 空 map 防御性
    返回空数组, 不创建零 worker 线程池.
    CLI legacy 路径: 未注入时保留原行为 (读 CC Switch / Codex CLI 认证
    文件, candidates 轮换重试, CLI 文件写回).
    """
    injected_accounts = _runtime_credential("codex_quota_accounts")
    if injected_accounts is not None:
        accounts = json.loads(json.dumps(injected_accounts))
        if not accounts:
            return []
        # 任务 6: order 由 Bridge 映射到运行时 context
        # (codex_quota_account_order), 不进入 credentials; CLI 直跑
        # 兼容旧 credentials 注入路径.
        order = _runtime_context("codex_quota_account_order")
        if order is None:
            order = _runtime_credential("codex_quota_account_order")
        order = order or []
        if isinstance(order, list) and order:
            # App 模式 order 与 map 必须严格一致 (Bridge validator 已保证);
            # 不一致表示请求组装错误, 返回可诊断协议错误, 不自行补账号掩盖.
            if _APP_MODE:
                order_set = set(order)
                account_keys = set(accounts.keys())
                if len(order_set) != len(order) or order_set != account_keys:
                    raise ValueError(
                        "codex_quota_account_order 与 codex_quota_accounts "
                        "不一致 (App 模式)"
                    )
            # 按 order 排序; order 之外的账号追加到末尾 (CLI 保持稳定)
            ordered_keys = [
                k for k in order if k in accounts
            ] + [
                k for k in accounts if k not in set(order)
            ]
        else:
            ordered_keys = list(accounts.keys())
        with ThreadPoolExecutor(max_workers=min(4, len(ordered_keys))) as pool:
            results = list(pool.map(
                lambda item: codex_compat.query_single_account(
                    item[0],
                    (item[1] or {}).get("access_token"),
                    (item[1] or {}).get("display_name"),
                    "app",
                    CODEX_USAGE_URL,
                    now,
                    http_get_json,
                    lambda acc_id: record_codex_challenge(acc_id),
                ),
                [(k, accounts[k]) for k in ordered_keys],
            ))
        return results

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
            svc = codex_compat.query_single_account(
                acc_id,
                access_token,
                "Codex · " + email.split("@")[0],
                "legacy",
                CODEX_USAGE_URL,
                now,
                http_get_json,
                lambda acc_id: None,
            )
        except Exception as e:
            svc = {
                "id": codex_compat.service_id(acc_id),
                "name": "Codex · " + email.split("@")[0],
                "app": "codex",
                "isCurrent": acc_id == active_id,
                "status": "error",
                "kind": None,
                "plan": None,
                "windows": [],
                "balance": None,
                "currency": None,
                "freshness": "unavailable",
                "failureKind": codex_compat.failure_kind(e),
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
        # 阶段 E (07 §6.2 选项 2): App 模式必须由运行环境注入 AGY_CLIENT 凭证.
        # 缺失时不伪造空凭证做 refresh, 返回可诊断状态 (CLI 直跑保留旧行为).
        if _APP_MODE and not AGY_CLIENT_ID:
            svc["status"] = "error"
            svc["note"] = "Antigravity 客户端凭证未配置, App 模式暂不支持该查询"
            svc["freshness"] = "unavailable"
            svc.pop("capturedAt", None)
            return [svc]
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
                        (runtime.TODAY,),
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
                svc, lambda: quota_services.service_deepseek(dict(deepseek_env), HTTP_TIMEOUT)
            )
        )

    volc_meta = provider_meta.get("volcengine") or {}
    volc_script = volc_meta.get("usage_script") or {}
    if volc_script.get("accessKeyId") and volc_script.get("secretAccessKey"):
        svc = _quota_service_entry("volcengine", "火山引擎（Coding Plan）", "volcengine")
        services.append(
            _finalize_quota_service(
                svc, lambda: quota_services.service_volcengine({}, dict(volc_meta), now, HTTP_TIMEOUT)
            )
        )

    if (provider_meta.get("claude") or {}).get("enabled"):
        svc = _quota_service_entry("claude", "Claude", "claude")
        services.append(_finalize_quota_service(svc, _claude_query_or_missing))

    if (provider_meta.get("grok") or {}).get("enabled"):
        svc = _quota_service_entry("grok", "Grok", "grok")
        services.append(_finalize_quota_service(svc, _grok_query_or_missing))

    return services


def _claude_query_or_missing():
    result = quota_official.service_claude(HOME, now, HTTP_TIMEOUT)
    if result is None:
        raise RuntimeError("未检测到 Claude 本机凭证 (Keychain 或 ~/.claude/.credentials.json)")
    return result


def _grok_query_or_missing():
    result = quota_official.service_grok(HOME, now, HTTP_TIMEOUT)
    if result is None:
        raise RuntimeError("未检测到 Grok 本机凭证 (~/.grok/auth.json)")
    return result


def _collect_official_services():
    """CLI 模式: 探测本机 Claude / Grok 凭证并查询官方订阅额度.

    与 CC Switch 同策略: 实时只读凭证, 不刷新, 不回写.
    无凭证的平台不出条目; 凭证过期给出可操作 error 条目.
    """
    services = []
    now_ts = now.timestamp()
    probes = (
        ("claude", "Claude", "claude", quota_official.read_claude_token,
         quota_official.service_claude),
        ("grok", "Grok", "grok", quota_official.read_grok_token,
         quota_official.service_grok),
    )
    for service_id, name, app, read_token, query in probes:
        try:
            token = read_token(HOME, now_ts)
        except Exception as e:
            svc = _quota_service_entry(service_id, name, app)
            svc["status"] = "error"
            svc["note"] = str(e)[:60] or "凭证不可用"
            services.append(svc)
            continue
        if token is None:
            continue
        svc = _quota_service_entry(service_id, name, app)
        services.append(
            _finalize_quota_service(svc, lambda q=query: q(HOME, now, HTTP_TIMEOUT))
        )
    return services


def collect_services():
    if _APP_MODE:
        return _collect_app_services()
    services = []
    if not os.path.exists(CC_SWITCH_DB):
        return services + _collect_official_services()
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
        ] + _collect_official_services()

    handlers = {
        "Kimi For Coding": ("kimi_coding", service_kimi_coding),
        "DeepSeek": ("deepseek", lambda env: quota_services.service_deepseek(env, HTTP_TIMEOUT)),
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
                result = quota_services.service_volcengine(env, meta, now, HTTP_TIMEOUT)
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
    return services + _collect_official_services()


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
    pricing = load_pricing(CC_SWITCH_DB) if _capability_allowed("localPricing") else {}
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
            if (
                oauth_data is None
                and acc_id
                and not _APP_MODE
                and os.path.exists(CODEX_OAUTH_AUTH)
            ):
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
        elif scan_claude(agent, CLAUDE_PROJECTS):
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
            found_cli, candidate = scan_codex(agent, [CODEX_SESSIONS])
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
