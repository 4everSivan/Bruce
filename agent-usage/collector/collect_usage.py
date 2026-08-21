#!/usr/bin/env python3
"""Aggregate local AI-agent token usage, cost estimates, and provider quotas.

Agents: Kimi Work (daimon), Kimi Code CLI, Claude Code, Codex (CLI and
Orca-hosted sessions merged into one agent), Pi, ZCode; detection only for
Gemini/Antigravity, GitHub Copilot, Cursor.
Services (quota): read CC Switch's provider database and query the providers
it knows how to meter (Kimi For Coding, DeepSeek balance, Volcengine Coding
Plan via signed OpenAPI). Cost estimates use CC Switch's model_pricing table.

Entry point: run(ctx) -> {"artifact": {...}}
"""

import base64
import datetime
import glob
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from zoneinfo import ZoneInfo

# 阶段 D: pricing 模块拆分. 本文件被 bridge/tests 用 importlib 从文件路径
# 加载 (__package__ 为空), 需把同目录加入 sys.path 才能 import 同级模块.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pricing import load_pricing  # noqa: E402
import runtime
# Keep date helpers and quota_services as module-level compatibility exports:
# CLI callers and contract tests load collect_usage.py directly.
from runtime import RunContext, day_of, epoch_from_iso, hour_of, parse_iso  # noqa: E402
import quota_services
import quota_official
import local_usage
from local_usage import finalize, make_agent, record_usage, scan_claude, scan_codex, scan_grok, scan_kimi, scan_opencode, scan_pi, scan_zcode  # noqa: E402
import codex_compat
import service_catalog

# 订阅额度定向刷新的 Provider 标识 (与 Swift SubscriptionProviderID.rawValue 一致).
SUBSCRIPTION_PROVIDER_IDS = {
    "kimi",
    "deepseek",
    "volcengine",
    "codex",
    "antigravity",
    "claude",
    "grok",
    "opencodeGo",
}
# Provider 标识 -> collector service 的 app 字段, 用于结果收窄.
_PROVIDER_APP = {
    "kimi": "kimi",
    "deepseek": "deepseek",
    "volcengine": "volcengine",
    "claude": "claude",
    "grok": "grok",
    "opencodeGo": "opencode-go",
}

CODEX_OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
# Legacy inspection seam used by direct Collector tests; production reads
# `RunContext.paths["cc_switch_db"]` explicitly.
CC_SWITCH_DB = os.path.expanduser("~/.cc-switch/cc-switch.db")
# agy >= 1.1.8 把 OAuth 令牌存进登录 Keychain (go-keyring), 不再写令牌文件
AGY_KEYCHAIN_SERVICE = "gemini"
AGY_KEYCHAIN_ACCOUNT = "antigravity"
# Antigravity 桌面 OAuth client: installed-app 凭证, 公开内置于 agy/IDE,
# 无保密要求 (PKCE 提供安全); 凭证由运行环境注入, 不入库
AGY_CLIENT_ID = os.getenv("AGY_CLIENT_ID", "")
AGY_CLIENT_SECRET = os.getenv("AGY_CLIENT_SECRET", "")
AGY_QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"

_RUNTIME_CREDENTIAL_UPDATES = []
# App 模式 quota 401 收集的定向重试挑战; Bridge 每次运行重置, 测试直接断言
_RUNTIME_CREDENTIAL_CHALLENGES = []
_CREDENTIAL_UPDATE_LOCK = threading.Lock()
# 旧直接测试 seam. 生产入口使用局部 RunContext, 不依赖最近一次运行指针.
_ACTIVE_RUN_CONTEXT = None


def _path_override(overrides, name, default):
    value = overrides.get(name, default)
    return os.path.abspath(os.path.expanduser(value))


def _build_run_context(ctx):
    """从输入 dict 构造 RunContext (纯计算, 不做 I/O, 不写模块 global)."""
    ctx = dict(ctx or {})
    home = os.path.abspath(os.path.expanduser(ctx.get("home") or "~"))
    path_overrides = ctx.get("paths") or {}
    paths = {
        "daimon_kimi_sessions": _path_override(
            path_overrides,
            "daimon_kimi_sessions",
            os.path.join(
                home,
                "Library/Application Support/kimi-desktop/daimon-share/daimon/"
                "runtime/kimi-code/home/sessions",
            ),
        ),
        "kimi_cli_sessions": _path_override(
            path_overrides, "kimi_cli_sessions", os.path.join(home, ".kimi-code/sessions")
        ),
        "claude_projects": _path_override(
            path_overrides, "claude_projects", os.path.join(home, ".claude/projects")
        ),
        "grok_home": _path_override(
            path_overrides, "grok_home", os.path.join(home, ".grok")
        ),
        "codex_sessions": _path_override(
            path_overrides, "codex_sessions", os.path.join(home, ".codex/sessions")
        ),
        "orca_home": _path_override(
            path_overrides,
            "orca_home",
            os.path.join(home, "Library/Application Support/orca"),
        ),
    }
    paths["orca_codex_sessions"] = _path_override(
        path_overrides,
        "orca_codex_sessions",
        os.path.join(paths["orca_home"], "codex-runtime-home/home/sessions"),
    )
    paths["orca_codex_accounts"] = _path_override(
        path_overrides,
        "orca_codex_accounts",
        os.path.join(paths["orca_home"], "codex-accounts"),
    )
    paths["cc_switch_db"] = _path_override(
        path_overrides, "cc_switch_db", os.path.join(home, ".cc-switch/cc-switch.db")
    )
    paths["codex_oauth_auth"] = _path_override(
        path_overrides,
        "codex_oauth_auth",
        os.path.join(home, ".cc-switch/codex_oauth_auth.json"),
    )
    paths["codex_auth"] = _path_override(
        path_overrides, "codex_auth", os.path.join(home, ".codex/auth.json")
    )
    paths["antigravity_oauth_token"] = _path_override(
        path_overrides,
        "antigravity_oauth_token",
        os.path.join(home, ".gemini/antigravity-cli/antigravity-oauth-token"),
    )
    paths["antigravity_summaries_db"] = _path_override(
        path_overrides,
        "antigravity_summaries_db",
        os.path.join(home, ".gemini/antigravity-cli/conversation_summaries.db"),
    )
    paths["kimi_web_tokens"] = _path_override(
        path_overrides,
        "kimi_web_tokens",
        os.path.join(home, ".config/kimi-dashboard/kimi-web-tokens.json"),
    )
    # opencode 会话数据库 (agent 用量只读来源; 订阅额度仍走网页 API,
    # 不读本库). mode=ro 只读, 不写不迁移.
    paths["opencode_db"] = _path_override(
        path_overrides,
        "opencode_db",
        os.path.join(home, ".local/share/opencode/opencode.db"),
    )
    # Pi 会话目录 (~/.pi/agent/sessions/<编码目录>/*.jsonl)
    paths["pi_sessions"] = _path_override(
        path_overrides,
        "pi_sessions",
        os.path.join(home, ".pi/agent/sessions"),
    )
    # ZCode CLI 会话数据库 (~/.zcode/cli/db/db.sqlite), model_usage 表为
    # 每次模型请求的计量行. mode=ro 只读, 不写不迁移.
    paths["zcode_db"] = _path_override(
        path_overrides,
        "zcode_db",
        os.path.join(home, ".zcode/cli/db/db.sqlite"),
    )

    timezone_value = ctx.get("timezone")
    if isinstance(timezone_value, str):
        tz = ZoneInfo(timezone_value)
    elif isinstance(timezone_value, datetime.tzinfo):
        tz = timezone_value
    else:
        tz = datetime.datetime.now().astimezone().tzinfo

    now_value = ctx.get("now")
    if callable(now_value):
        now_value = now_value()
    if isinstance(now_value, str):
        now_value = datetime.datetime.fromisoformat(now_value.replace("Z", "+00:00"))
    if now_value is None:
        now_value = datetime.datetime.now(tz)
    if not isinstance(now_value, datetime.datetime):
        raise TypeError("ctx.now must be a datetime, ISO-8601 string, or callable")
    if now_value.tzinfo is None:
        now_value = now_value.replace(tzinfo=tz)
    now_value = now_value.astimezone(tz)

    days = int(ctx.get("days", 14))
    if days < 1:
        raise ValueError("ctx.days must be at least 1")
    http_timeout = float(ctx.get("http_timeout", 8))
    today = now_value.strftime("%Y-%m-%d")
    cutoff_ts = (now_value - datetime.timedelta(days=days + 1)).timestamp()
    day_list = [
        (now_value - datetime.timedelta(days=i)).strftime("%Y-%m-%d")
        for i in range(days - 1, -1, -1)
    ]

    # 只有 ctx 显式携带 capabilities 时才启用门禁 (Bridge App 模式总会携带);
    # CLI 直跑不带该键, 保持现状行为完全不变
    if "capabilities" in ctx:
        capabilities = set(ctx.get("capabilities") or [])
    else:
        capabilities = None

    return RunContext(
        app_mode=bool(ctx.get("app_mode")),
        home=home,
        now=now_value,
        credentials=dict(ctx.get("credentials") or {}),
        credential_updates=[],
        credential_challenges=[],
        paths=paths,
        timezone=tz,
        http=dict(ctx.get("http") or {}),
        days=days,
        http_timeout=http_timeout,
        capabilities=capabilities,
        raw=ctx,
        today=today,
        cutoff_ts=cutoff_ts,
        day_list=day_list,
        codex_usage_url=str(ctx["codex_usage_url"]) if ctx.get("codex_usage_url") else None,
        codex_token_url=str(ctx["codex_token_url"]) if ctx.get("codex_token_url") else None,
        metrics=ctx.get("_metrics"),
    )


def _apply_run_context(run_ctx):
    """仅更新旧直接测试 seam; 生产采集使用显式 RunContext."""
    global CC_SWITCH_DB
    global _RUNTIME_CREDENTIAL_UPDATES, _RUNTIME_CREDENTIAL_CHALLENGES
    global _ACTIVE_RUN_CONTEXT

    _ACTIVE_RUN_CONTEXT = run_ctx
    CC_SWITCH_DB = run_ctx.paths["cc_switch_db"]

    runtime.set_timezone(run_ctx.timezone)
    runtime.set_date_buckets(run_ctx.today, run_ctx.cutoff_ts, list(run_ctx.day_list))
    runtime.set_http_overrides(dict(run_ctx.http))
    # 与 RunContext 共享同一可变容器, 仅保留旧测试读取别名.
    _RUNTIME_CREDENTIAL_UPDATES = run_ctx.credential_updates
    _RUNTIME_CREDENTIAL_CHALLENGES = run_ctx.credential_challenges


def _configure_runtime(ctx):
    """Configure per-run boundaries without performing I/O.

    构造并返回 RunContext. 仅为旧直接测试同步少量兼容 seam;
    新代码必须持有返回值, 禁止新增对 global 的依赖.

    Supported test/App overrides:
    - home / paths: isolate all local file and SQLite reads.
    - now / timezone: make date buckets deterministic.
    - http: inject get_json, post_json, or urlopen callables.
    - credentials: provide in-memory provider credentials.
    - capabilities: capability allowlist; only present in Bridge App mode.
    """
    run_ctx = _build_run_context(ctx)
    _apply_run_context(run_ctx)
    return run_ctx


def _context_or_active(run_ctx=None):
    """显式上下文优先; 旧的直接 service 调用仅回退到测试兼容指针."""
    context = run_ctx or _ACTIVE_RUN_CONTEXT
    if context is None:
        raise RuntimeError("RunContext not configured; call _configure_runtime/collect first")
    return context


def _record_credential_update(provider, account_id, credentials, run_ctx=None):
    """Keep rotated credentials outside the display artifact.

    App mode returns these candidates to the native owner. CLI mode continues
    its legacy file behavior and does not expose credentials on stdout.
    """
    context = _context_or_active(run_ctx)
    if not context.app_mode or not credentials:
        return
    values = {
        key: value
        for key, value in credentials.items()
        if value is not None and key in {"access_token", "refresh_token", "id_token", "expiry"}
    }
    if not values:
        return
    if context.metrics is not None:
        context.metrics.increment("credential_refresh_count")
    # services 采集并行后, 多个账号可能同时 append, 需要锁保护
    with _CREDENTIAL_UPDATE_LOCK:
        context.credential_updates.append(
            {
                "provider": provider,
                "accountId": account_id or "default",
                "kind": "oauthTokens",
                "operation": "replace",
                "credentials": values,
            }
        )


def _urlopen(request, run_ctx=None, **kwargs):
    return runtime.urlopen(request, context=run_ctx, **kwargs)



# ---------------------------------------------------------------- cc-switch services

def http_get_json(url, headers, run_ctx=None):
    context = _context_or_active(run_ctx)
    return runtime.http_get_json(url, headers, context.http_timeout, context=context)


def _query_json_with_compat(url, headers, run_ctx):
    """Call the injectable test seam while accepting its legacy 2-arg shape."""
    try:
        return http_get_json(url, headers, run_ctx)
    except TypeError:
        return http_get_json(url, headers)


def _refresh_with_compat(refresh_token, run_ctx):
    """Call the injectable refresh seam while accepting its legacy 1-arg shape."""
    try:
        return _codex_refresh(refresh_token, run_ctx)
    except TypeError:
        return _codex_refresh(refresh_token)


KIMI_USAGE_URL = "https://api.kimi.com/coding/v1/usages"


def service_kimi_coding(env=None, api_key=None, context=None):
    """Kimi For Coding 额度: 走 Kimi For Coding API (GET api.kimi.com/coding/v1/usages).

    凭证为 Kimi For Coding 的 API key (长期有效), 与 CC Switch 一致; 不是网页端登录态.
    返回 5 小时窗口 (limits[].detail) + 周限额 (usage), 无赠送额度/每月窗口/加量包.

    api_key 参数用于多账号注入 (service_catalog 按账号传入);
    env 参数用于 CLI 场景 (CC Switch provider 行的 ANTHROPIC_AUTH_TOKEN).
    """
    if api_key is None:
        api_key = (env or {}).get("ANTHROPIC_AUTH_TOKEN") or ""
    if not api_key:
        return None
    try:
        d = http_get_json(
            KIMI_USAGE_URL,
            {"Authorization": "Bearer " + api_key, "Accept": "application/json"},
            run_ctx=context,
        )
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise RuntimeError("Kimi 凭证被拒绝 (HTTP %d), 请检查 API key" % e.code)
        raise RuntimeError("Kimi 额度请求失败 (HTTP %d)" % e.code)
    if not isinstance(d, dict):
        raise RuntimeError("Kimi 额度响应不是 JSON 对象")

    windows = []

    # 5 小时窗口: limits[].detail (duration 300 分钟)
    limits = d.get("limits") or []
    if isinstance(limits, list):
        for item in limits:
            if not isinstance(item, dict):
                continue
            detail = item.get("detail") or {}
            if not detail:
                continue
            try:
                limit = float(detail.get("limit") or 1.0)
                remaining = float(detail.get("remaining") or 0.0)
            except (TypeError, ValueError):
                continue
            used = max(0.0, limit - remaining)
            pct = (used / limit * 100.0) if limit > 0 else 0.0
            windows.append({
                "label": "5小时窗口",
                "usedPercent": pct,
                "windowMinutes": 300,
                "resetsAt": epoch_from_iso(detail.get("resetTime")),
            })

    # 周限额: usage
    usage = d.get("usage") or {}
    if isinstance(usage, dict) and usage:
        try:
            limit = float(usage.get("limit") or 1.0)
            remaining = float(usage.get("remaining") or 0.0)
        except (TypeError, ValueError):
            limit, remaining = 1.0, 0.0
        used = max(0.0, limit - remaining)
        pct = (used / limit * 100.0) if limit > 0 else 0.0
        windows.append({
            "label": "7天窗口",
            "usedPercent": pct,
            "windowMinutes": 7 * 24 * 60,
            "resetsAt": epoch_from_iso(usage.get("resetTime")),
        })

    return {"kind": "windows", "plan": None, "windows": windows, "extra": None}


def record_codex_challenge(acc_id, run_ctx=None):
    """App 模式 401: 记录 accessRejected 定向重试挑战 (线程安全)."""
    with _CREDENTIAL_UPDATE_LOCK:
        _context_or_active(run_ctx).credential_challenges.append(
            {
                "provider": "codex",
                "accountId": acc_id,
                "reason": "accessRejected",
            }
        )


def _codex_refresh(refresh_token, run_ctx=None):
    """CLI legacy refresh 的薄包装 (委托 codex_compat). 测试 monkeypatch 此名."""
    context = _context_or_active(run_ctx)
    return codex_compat.refresh(
        refresh_token,
        context.codex_token_url or CODEX_TOKEN_URL,
        CODEX_OAUTH_CLIENT_ID,
        lambda request, **kwargs: _urlopen(request, run_ctx=context, **kwargs),
        context.http_timeout,
    )


# ---------------------------------------------------------------- codex multi-account


def service_codex_accounts(run_ctx=None):
    """查询 Codex OAuth 多账号的实时额度.

    App access-only 路径: 只消费注入的 `codex_quota_accounts` (每账号仅
    display_name + 短期 access_token), 直接请求 wham/usage; 无刷新, 无
    磁盘读取, 无 rotation update, 401 记录定向 challenge.
    按 `codex_quota_account_order` 调度并恢复输出顺序; 空 map 防御性
    返回空数组, 不创建零 worker 线程池.
    CLI legacy 路径: 未注入时保留原行为 (读 CC Switch / Codex CLI 认证
    文件, candidates 轮换重试, CLI 文件写回).
    """
    run_ctx = _context_or_active(run_ctx)
    usage_url = run_ctx.codex_usage_url or CODEX_USAGE_URL
    oauth_path = run_ctx.paths["codex_oauth_auth"]
    cli_auth_path = run_ctx.paths["codex_auth"]
    injected_accounts = run_ctx.credential("codex_quota_accounts")
    if injected_accounts is not None:
        accounts = json.loads(json.dumps(injected_accounts))
        if not accounts:
            return []
        # 任务 6: order 由 Bridge 映射到运行时 context
        # (codex_quota_account_order), 不进入 credentials; CLI 直跑
        # 兼容旧 credentials 注入路径.
        order = run_ctx.context_get("codex_quota_account_order")
        if order is None:
            order = run_ctx.credential("codex_quota_account_order")
        order = order or []
        if isinstance(order, list) and order:
            # App 模式 order 与 map 必须严格一致 (Bridge validator 已保证);
            # 不一致表示请求组装错误, 返回可诊断协议错误, 不自行补账号掩盖.
            if run_ctx.app_mode:
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
                    usage_url,
                    run_ctx.now,
                    lambda url, headers: _query_json_with_compat(url, headers, run_ctx),
                    lambda acc_id: record_codex_challenge(acc_id, run_ctx),
                ),
                [(k, accounts[k]) for k in ordered_keys],
            ))
        return results

    injected_oauth = run_ctx.credential("codex_oauth_auth")
    if injected_oauth is not None:
        data = json.loads(json.dumps(injected_oauth))
    else:
        if run_ctx.app_mode:
            return []
        if not os.path.exists(oauth_path):
            return []
        try:
            with open(oauth_path, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            return []
    accounts = data.get("accounts") or {}
    if not accounts:
        return []
    active_id = None
    cli_auth = None
    cli_tokens = {}
    injected_cli_auth = run_ctx.credential("codex_auth")
    if injected_cli_auth is not None:
        cli_auth = json.loads(json.dumps(injected_cli_auth))
        cli_tokens = cli_auth.get("tokens") or {}
        active_id = cli_tokens.get("account_id")
    elif not run_ctx.app_mode:
        # CLI 兼容模式读本机 CLI 侧认证; App 模式凭证只经注入, 不读盘
        try:
            with open(cli_auth_path, encoding="utf-8") as fh:
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
                    tokens = _refresh_with_compat(rt, run_ctx)
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
            _record_credential_update("codex", acc_id, tokens, run_ctx)
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
                usage_url,
                run_ctx.now,
                lambda url, headers: _query_json_with_compat(url, headers, run_ctx),
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
    if changed and injected_oauth is None and not run_ctx.app_mode:
        try:
            shutil.copy2(oauth_path, oauth_path + ".bak-kimi")
            with open(oauth_path, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
            os.chmod(oauth_path, 0o600)
        except Exception:
            pass
    if (
        cli_rotated
        and cli_auth is not None
        and injected_cli_auth is None
        and not run_ctx.app_mode
    ):
        try:
            cli_auth["tokens"] = cli_tokens
            shutil.copy2(cli_auth_path, cli_auth_path + ".bak-kimi")
            with open(cli_auth_path, "w", encoding="utf-8") as fh:
                json.dump(cli_auth, fh, ensure_ascii=False, indent=2)
            os.chmod(cli_auth_path, 0o600)
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


def _load_agy_oauth(path=None):
    """读取 agy OAuth 凭证, 返回 (data, source); source 为 "file" 或 "keychain".

    agy < 1.1.8 写令牌文件; >= 1.1.8 改用登录 Keychain (go-keyring,
    值带 "go-keyring-base64:" 前缀的 base64 JSON). 均无凭证返回 (None, None).
    """
    if path is None:
        path = _context_or_active().paths["antigravity_oauth_token"]
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
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


def service_antigravity(run_ctx=None):
    """读取 agy (Antigravity CLI) 的 Google OAuth 凭证，查询分组额度。

    CLI 兼容模式会写回刷新后的 access token (仅文件来源; Keychain 来源只读,
    不回写第三方钥匙串). App 模式只返回候选更新.
    agy 不在本地记录 token 用量，只提供额度与活动计数。
    """
    run_ctx = _context_or_active(run_ctx)
    oauth_path = run_ctx.paths["antigravity_oauth_token"]
    summaries_path = run_ctx.paths["antigravity_summaries_db"]
    injected_auth = run_ctx.credential("antigravity_oauth")
    # App 模式多账号: 从 antigravity_quota_accounts 读取第一个账号的 oauth.
    if injected_auth is None:
        agy_accounts = run_ctx.credential("antigravity_quota_accounts")
        if isinstance(agy_accounts, dict) and agy_accounts:
            first = list(agy_accounts.values())[0]
            injected_auth = (first or {}).get("oauth")
    source = None
    if injected_auth is not None:
        data = json.loads(json.dumps(injected_auth))
    else:
        if run_ctx.app_mode:
            return []
        try:
            data, source = _load_agy_oauth(oauth_path)
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
        "capturedAt": run_ctx.now.isoformat(timespec="seconds"),
        "note": "",
    }
    try:
        tok = data.get("token") or {}
        # 阶段 E (07 §6.2 选项 2): App 模式必须由运行环境注入 AGY_CLIENT 凭证.
        # 缺失时不伪造空凭证做 refresh, 返回可诊断状态 (CLI 直跑保留旧行为).
        if run_ctx.app_mode and not AGY_CLIENT_ID:
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
        with _urlopen(req, run_ctx=run_ctx, timeout=run_ctx.http_timeout) as resp:
            refreshed = json.loads(resp.read().decode("utf-8", "replace"))
        access_token = refreshed.get("access_token") or tok.get("access_token") or ""
        if refreshed.get("access_token"):
            tok["access_token"] = refreshed["access_token"]
            if refreshed.get("expires_in"):
                tok["expiry"] = (
                    run_ctx.now + datetime.timedelta(seconds=int(refreshed["expires_in"]) - 60)
                ).isoformat()
            _record_credential_update("antigravity", "default", tok, run_ctx)
            if source == "file":
                # 仅文件来源写回刷新后的令牌; Keychain 来源只读, 不动第三方钥匙串
                try:
                    shutil.copy2(oauth_path, oauth_path + ".bak-kimi")
                    with open(oauth_path, "w", encoding="utf-8") as fh:
                        json.dump(data, fh, ensure_ascii=False, indent=2)
                    os.chmod(oauth_path, 0o600)
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
        with _urlopen(req, run_ctx=run_ctx, timeout=run_ctx.http_timeout) as resp:
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
                        "resetsAt": epoch_from_iso(b.get("resetTime"), run_ctx),
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
        if os.path.exists(summaries_path):
            try:
                with sqlite3.connect(
                    "file:%s?mode=ro" % summaries_path, uri=True
                ) as db:
                    row = db.execute(
                        "SELECT COUNT(*), COALESCE(SUM(step_count),0) "
                        "FROM conversation_summaries "
                        "WHERE date(last_modified_time) = date(?)",
                        (run_ctx.today,),
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


def _collect_app_services(run_ctx=None):
    """App 模式额度条目 (薄包装; 实现见 service_catalog.build_quota_services).

    测试可 monkeypatch 此名拦截 App 路径; 生产路径经 collect_services 同样进 catalog.
    """
    run_ctx = _context_or_active(run_ctx)
    return service_catalog.build_quota_services(
        run_ctx,
        kimi_coding=service_kimi_coding,
        opencode_go=quota_official.service_opencode_go,
    )


def collect_services(run_ctx=None):
    """App/CLI 统一入口: 最终均走 service_catalog.build_quota_services.

    App 经 `_collect_app_services` 薄包装, 保留既有 monkeypatch 点;
    CLI 直接调 catalog. Mode 仅影响凭证解析; note/status 语义不变.
    """
    run_ctx = _context_or_active(run_ctx)
    if run_ctx.app_mode:
        return _collect_app_services(run_ctx)
    return service_catalog.build_quota_services(
        run_ctx,
        kimi_coding=service_kimi_coding,
        opencode_go=quota_official.service_opencode_go,
    )


# ---------------------------------------------------------------- main

def _mark_sessions_denied(agent):
    agent["status"] = "unavailable"
    agent["note"] = "未授权 localSessions 能力, 已跳过本机会话扫描"


def _quota_denied_service(service_id, name, app, run_ctx=None):
    run_ctx = _context_or_active(run_ctx)
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
        "capturedAt": run_ctx.now.isoformat(timespec="seconds"),
        "note": "未授权 externalQuotas 能力, 已跳过云端额度查询",
    }


def _quota_denied_services(run_ctx=None):
    return [
        _quota_denied_service("cc_switch_providers", "CC Switch 云端额度", "cc-switch", run_ctx),
        _quota_denied_service("antigravity", "Antigravity", "antigravity", run_ctx),
        _quota_denied_service("codex_accounts", "Codex 账号额度", "codex", run_ctx),
    ]


def collect_codex_quota_retry_only(ctx):
    """App 定向重试: 只构造 Codex service 部分 artifact.

    不扫描本地会话, 不加载定价, 不调用其他 provider. 保留 agent-usage
    契约结构 (agents/services/totalCostUsd), agents 为空数组.
    """
    run_ctx = _configure_runtime(ctx)
    return _collect_codex_quota_retry_only(run_ctx)


def _collect_codex_quota_retry_only(run_ctx):
    """RunContext 接线后的 Codex 定向重试实现."""
    codex_svcs = service_codex_accounts(run_ctx)
    return {
        "generatedAt": run_ctx.now.isoformat(timespec="seconds"),
        "agents": [],
        "services": codex_svcs,
        "totalCostUsd": None,
    }


def _validate_subscription_providers(providers):
    """校验 quota-only 的目标 Provider 集合: 非空、去重、已知.

    非法时抛 ValueError (Bridge 捕获为可诊断错误响应, 不伪造空 success).
    """
    if not isinstance(providers, list) or not providers:
        raise ValueError("subscription_providers 必须为非空字符串数组")
    target = set()
    for provider in providers:
        if not isinstance(provider, str) or not provider:
            raise ValueError("subscription_providers 元素必须是非空字符串")
        if provider in target:
            raise ValueError(
                "subscription_providers 包含重复 Provider: %s" % provider
            )
        if provider not in SUBSCRIPTION_PROVIDER_IDS:
            raise ValueError(
                "subscription_providers 包含未知 Provider: %s" % provider
            )
        target.add(provider)
    return target


def _filter_services_to_providers(catalog, target):
    """把 catalog 产出的 service 收窄到目标 Provider 的 app 集合 (防御性)."""
    apps = {_PROVIDER_APP[p] for p in target}
    return [svc for svc in catalog if svc.get("app") in apps]


def collect_subscription_quota_only(ctx=None):
    """App 定向订阅额度刷新: 只查询目标 Provider 的现有 handler.

    不扫描本机会话, 不加载定价, 不调用非目标 Provider. 复用 Antigravity /
    Codex / 官方订阅 / CC 驱动 handler 的既有边界 (Codex recovery, 官方 OAuth).
    输出仍是 artifact v1 形状: agents 为空数组, totalCostUsd 为 null,
    services 只含目标 Provider. Provider 内多账号独立, 单账号失败不阻断其他账号.
    """
    run_ctx = _configure_runtime(ctx)
    return _collect_subscription_quota_only(run_ctx)


def _collect_subscription_quota_only(run_ctx):
    """RunContext 接线后的定向订阅额度实现."""
    if not run_ctx.capability_allowed("externalQuotas"):
        raise RuntimeError("quota-only 请求需要 externalQuotas 能力")
    providers = run_ctx.context_get("subscription_providers")
    target = _validate_subscription_providers(providers)

    services = []
    # Codex / Antigravity 走独立 handler, 复用既有 recovery / OAuth 边界
    if "codex" in target:
        services.extend(service_codex_accounts(run_ctx))
    if "antigravity" in target:
        services.extend(service_antigravity(run_ctx))
    others = target - {"codex", "antigravity"}
    if others:
        catalog = service_catalog.build_quota_services(
            run_ctx,
            kimi_coding=service_kimi_coding,
            opencode_go=quota_official.service_opencode_go,
        )
        services.extend(_filter_services_to_providers(catalog, others))

    if not services:
        # 目标集合合法但没有任何 Provider 装配凭证: 返回可诊断失败,
        # 不伪造空的 success artifact.
        raise RuntimeError("目标 Provider 未装配凭证, 未生成任何额度条目")
    return {
        "generatedAt": run_ctx.now.isoformat(timespec="seconds"),
        "agents": [],
        "services": services,
        "totalCostUsd": None,
    }


def collect(ctx=None):
    """采集本机用量与额度; 返回 artifact dict.

    每次调用构造 RunContext 并贯穿 _collect. 兼容 seam 只服务旧直接测试,
    不参与生产业务逻辑.
    """
    run_ctx = _configure_runtime(ctx)
    return _collect(run_ctx)


# 只用于识别旧直接测试对公开 façade 的 monkeypatch, 不是运行时状态.
_DEFAULT_COLLECT = collect


def _collect(run_ctx):
    """RunContext 接线后的主采集实现."""
    # 未授权 localPricing 时降级为空定价, 成本估算全部为 None
    pricing = (
        load_pricing(run_ctx.paths["cc_switch_db"])
        if run_ctx.capability_allowed("localPricing")
        else {}
    )
    sessions_allowed = run_ctx.capability_allowed("localSessions")

    def kimi_cli_project(path):
        # .../sessions/wd_<name>_<hash>/conv-xxx/agents/main/wire.jsonl
        parts = path.split(os.sep)
        for p in parts:
            if p.startswith("wd_"):
                return p[3:].rsplit("_", 1)[0].replace("-", "/") or p
        return None

    # Orca 用自己的 CODEX_HOME 托管运行 Codex, 会话不在 ~/.codex 下;
    # 扫描时灌进同一个 codex agent, record_usage 桶自动合并
    paths = run_ctx.paths
    daimon_kimi_sessions = paths["daimon_kimi_sessions"]
    kimi_cli_sessions = paths["kimi_cli_sessions"]
    claude_projects = paths["claude_projects"]
    codex_sessions = paths["codex_sessions"]
    orca_home = paths["orca_home"]
    orca_codex_sessions = paths["orca_codex_sessions"]
    orca_codex_accounts = paths["orca_codex_accounts"]
    codex_oauth_auth = paths["codex_oauth_auth"]

    def orca_account_label():
        try:
            orca_auth = run_ctx.credential("orca_codex_auth")
            if orca_auth is not None:
                acc_id = (orca_auth.get("tokens") or {}).get("account_id")
            elif run_ctx.app_mode:
                return None
            else:
                with open(
                    os.path.join(
                        orca_home, "codex-runtime-home/home/auth.json"
                    ),
                    encoding="utf-8",
                ) as fh:
                    acc_id = (json.load(fh).get("tokens") or {}).get("account_id")
            oauth_data = run_ctx.credential("codex_oauth_auth")
            if (
                oauth_data is None
                and acc_id
                and not run_ctx.app_mode
                and os.path.exists(codex_oauth_auth)
            ):
                # 兼容契约: 磁盘 OAuth 回退必须等价于 `and not _APP_MODE`.
                with open(codex_oauth_auth, encoding="utf-8") as fh:
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
        elif scan_kimi(agent, daimon_kimi_sessions, context=run_ctx):
            agent["note"] = "额度见下方 Kimi 服务"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing, run_ctx)

    def build_kimi_cli():
        agent = make_agent("kimi-code-cli", "Kimi Code CLI")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_kimi(agent, kimi_cli_sessions, project_from_path=kimi_cli_project, context=run_ctx):
            agent["note"] = "额度见下方 Kimi 服务"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing, run_ctx)

    def build_claude():
        agent = make_agent("claude-code", "Claude Code")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_claude(agent, claude_projects, context=run_ctx):
            agent["note"] = "当前经 CC Switch 路由，额度见下方对应服务"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing, run_ctx)

    def build_codex():
        agent = make_agent("codex", "Codex")
        quota_candidate = None
        found_cli = False
        found_orca = False
        if sessions_allowed:
            found_cli, candidate = scan_codex(agent, [codex_sessions], context=run_ctx)
            if candidate:
                quota_candidate = candidate
            # Orca 托管会话灌进同一 agent; quota 取两侧候选中 ts 最大者
            if os.path.isdir(orca_home):
                orca_dirs = [orca_codex_sessions] + glob.glob(
                    os.path.join(orca_codex_accounts, "*/home/sessions")
                )
                found_orca, candidate = scan_codex(agent, orca_dirs, context=run_ctx)
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
        return finalize(agent, pricing, run_ctx)

    def build_grok():
        agent = make_agent("grok", "Grok")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_grok(agent, run_ctx.paths["grok_home"], context=run_ctx):
            agent["note"] = "按消息内容估算, 非精确 token 计数"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing, run_ctx)

    def build_opencode():
        agent = make_agent("opencode", "OpenCode")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_opencode(agent, paths["opencode_db"], context=run_ctx):
            agent["note"] = "本机 opencode 会话, 精确 token 计数"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现 opencode 会话记录"
        return finalize(agent, pricing, run_ctx)

    def build_pi():
        agent = make_agent("pi", "Pi")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_pi(agent, paths["pi_sessions"], context=run_ctx):
            agent["note"] = "本机 Pi 会话, 精确 token 计数"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现会话记录"
        return finalize(agent, pricing, run_ctx)

    def build_zcode():
        agent = make_agent("zcode", "ZCode")
        if not sessions_allowed:
            _mark_sessions_denied(agent)
        elif scan_zcode(agent, paths["zcode_db"], context=run_ctx):
            agent["note"] = "本机 ZCode 会话, 精确 token 计数"
        else:
            agent["status"] = "not_found"
            agent["note"] = "未发现 ZCode 会话记录"
        return finalize(agent, pricing, run_ctx)

    # 8 个本地扫描串行执行: GIL 下线程池对 CPU-bound JSON 解析无加速
    # (6 扫描时实测线程池 3.4s ≈ 串行 2.2s, 线程反而更慢), 且多线程并发解析
    # 使 malloc arena 峰值叠加 (6 扫描时实测 400MB vs 串行 190MB, 降 50%).
    builders = [
        build_kimi_work,
        build_kimi_cli,
        build_claude,
        build_codex,
        build_grok,
        build_opencode,
        build_pi,
        build_zcode,
    ]
    agents = [build() for build in builders]

    if run_ctx.capability_allowed("externalQuotas"):
        # 三路服务采集互不依赖 (CC 库为 mode=ro 独立连接), 并行后按原顺序拼接
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [
                pool.submit(collect_services, run_ctx),
                pool.submit(service_antigravity, run_ctx),
                pool.submit(service_codex_accounts, run_ctx),
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
        services = _quota_denied_services(run_ctx)

    total_cost = sum(a["todayCostUsd"] or 0 for a in agents)
    return {
        "generatedAt": run_ctx.now.isoformat(timespec="seconds"),
        "agents": agents,
        "services": services,
        "totalCostUsd": round(total_cost, 4) if total_cost > 0 else None,
    }


def run(ctx):
    # collect 内部构造 RunContext 并贯穿采集; 对外契约仍是 dict ctx -> artifact
    return {"artifact": collect(ctx)}


def run_app(ctx):
    """App 入口: 强制 app_mode, 返回 artifact + 凭证轮换/挑战旁路字段.

    生产路径由内部 RunContext 持有旁路字段; 兼容指针只为旧直接测试对
    collect 的 monkeypatch 保留.
    """
    app_ctx = dict(ctx or {})
    app_ctx["app_mode"] = True
    if collect is not _DEFAULT_COLLECT:
        # 旧直接测试会替换公开 collect; 保留该 seam, 不让它污染生产路径.
        artifact = collect(app_ctx)
        run_ctx = _ACTIVE_RUN_CONTEXT or _build_run_context(app_ctx)
    else:
        run_ctx = _build_run_context(app_ctx)
        if app_ctx.get("subscription_quota_only"):
            artifact = _collect_subscription_quota_only(run_ctx)
        elif app_ctx.get("codex_quota_retry_only"):
            artifact = _collect_codex_quota_retry_only(run_ctx)
        else:
            artifact = _collect(run_ctx)
    return {
        "artifact": artifact,
        "credentialUpdates": json.loads(json.dumps(run_ctx.credential_updates)),
        "credentialChallenges": json.loads(json.dumps(run_ctx.credential_challenges)),
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
