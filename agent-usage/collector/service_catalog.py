"""Unified App/CLI quota service catalog (S4c).

Single builder: ``build_quota_services(run_ctx, *, kimi_coding)``.

Mode only affects credential resolution (App inject vs CLI CC Switch /
local official probe). Query handlers and finalize note/status strings
are shared so fixtures stay behavior-frozen.

Codex / Antigravity are intentionally out of this catalog (collected in
parallel by ``_collect`` via dedicated service functions).
"""

from __future__ import annotations

import json
import os
import sqlite3
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

import quota_official
import quota_services
from runtime import RunContext


# ---------------------------------------------------------------- specs

# CC Switch provider name -> (service_id, default display name when no map)
_CC_HANDLERS = {
    "Kimi For Coding": "kimi_coding",
    "DeepSeek": "deepseek",
    "火山Codingplan": "volcengine",
}

# 看板展示名 (cc-switch 里的 provider 名不动, 仅改显示)
_CC_DISPLAY_NAMES = {
    "Kimi For Coding": "Kimi",
    "火山Codingplan": "火山引擎（Coding Plan）",
}

# 官方订阅 (Claude / Grok) 固定元数据.
# read/query 用属性名字符串, 运行时 getattr, 以便测试 monkeypatch
# collect_usage.quota_official.service_* 仍然生效 (与改造前一致).
_OFFICIAL_SPECS = (
    ("claude", "Claude", "claude", "read_claude_token", "service_claude"),
    ("grok", "Grok", "grok", "read_grok_token", "service_grok"),
)


@dataclass(frozen=True)
class ServiceSpec:
    """声明式额度服务描述 (目录条目, 不含运行时凭证)."""

    service_id: str
    display_name: str
    app: str
    source: str  # "app_inject" | "cc_switch" | "official"


@dataclass
class _Resolved:
    """resolve 产物: 可查询条目, 或凭证阶段预置 error."""

    service_id: str
    display_name: str
    app: str
    is_current: bool
    query: Optional[Callable[[], Any]] = None
    pre_error_note: Optional[str] = None


# ---------------------------------------------------------------- entry / finalize (shared)


def quota_service_entry(service_id, name, app, now, is_current=False):
    """合成额度条目模板; 字段与历史 CC 驱动条目同构."""
    return {
        "id": service_id,
        "name": name,
        "app": app,
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


def finalize_quota_service(svc, query):
    """执行额度查询并折叠结果/错误; empty/error note 文案与历史 fixtures 一致."""
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


# ---------------------------------------------------------------- resolve (mode branch)


def _claude_query_or_missing(run_ctx):
    """App: 注入优先, 无凭证时抛可操作错误 (走 finalize 的 查询失败: 前缀).

    通过 getattr 取 service_claude, 兼容测试对模块属性的 monkeypatch.
    """
    injected = run_ctx.credential("claude_oauth")
    service_claude = getattr(quota_official, "service_claude")
    result = service_claude(
        run_ctx.home, run_ctx.now, run_ctx.http_timeout, injected=injected
    )
    if result is None:
        raise RuntimeError(
            "未检测到 Claude 本机凭证 (Keychain 或 ~/.claude/.credentials.json)"
        )
    return result


def _grok_query_or_missing(run_ctx):
    """App: 注入优先, 无凭证时抛可操作错误 (走 finalize 的 查询失败: 前缀)."""
    injected = run_ctx.credential("grok_oauth")
    service_grok = getattr(quota_official, "service_grok")
    result = service_grok(
        run_ctx.home, run_ctx.now, run_ctx.http_timeout, injected=injected
    )
    if result is None:
        raise RuntimeError("未检测到 Grok 本机凭证 (~/.grok/auth.json)")
    return result


def _resolve_app(run_ctx: RunContext, *, kimi_coding, opencode_go) -> List[_Resolved]:
    """App 模式: 注入凭证驱动; 完全不读 CC Switch 数据库.

    支持多账号注入: 每个 provider 的凭证以 `<provider>QuotaAccounts` 字典传入,
    键为 accountID, 值含 display_name 和凭证体. 单账号也走同一路径.
    Claude/Grok 无凭证时仍经 providerMeta enabled 标记驱动本机探测.
    Antigravity 由 collect_usage.service_antigravity 统一处理, 不在此解析.
    """
    resolved: List[_Resolved] = []
    provider_meta = run_ctx.credential("provider_meta") or {}

    # --- OpenCode GO (多账号) ---
    go_accounts = run_ctx.credential("opencode_go_quota_accounts")
    if isinstance(go_accounts, dict) and go_accounts:
        home = run_ctx.home
        now = run_ctx.now
        timeout = run_ctx.http_timeout
        for account_id, payload in go_accounts.items():
            display = (payload or {}).get("display_name") or "OpenCode GO · " + account_id[:8]
            oauth = (payload or {}).get("oauth")
            resolved.append(
                _Resolved(
                    service_id="opencode_go_" + account_id,
                    display_name=display,
                    app="opencode-go",
                    is_current=False,
                    query=lambda o=oauth, h=home, n=now, t=timeout: opencode_go(
                        h, n, t, injected=o
                    ),
                )
            )

    # --- Kimi (多账号) ---
    kimi_accounts = run_ctx.credential("kimi_quota_accounts")
    if isinstance(kimi_accounts, dict) and kimi_accounts:
        for account_id, payload in kimi_accounts.items():
            display = (payload or {}).get("display_name") or "Kimi · " + account_id[:8]
            tokens = (payload or {}).get("tokens") or {}
            resolved.append(
                _Resolved(
                    service_id="kimi_coding_" + account_id,
                    display_name=display,
                    app="kimi",
                    is_current=False,
                    query=lambda t=tokens: kimi_coding(tokens=t),
                )
            )

    # --- DeepSeek (多账号) ---
    ds_accounts = run_ctx.credential("deepseek_quota_accounts")
    if isinstance(ds_accounts, dict) and ds_accounts:
        for account_id, payload in ds_accounts.items():
            display = (payload or {}).get("display_name") or "DeepSeek · " + account_id[:8]
            key = (payload or {}).get("api_key") or ""
            timeout = run_ctx.http_timeout
            resolved.append(
                _Resolved(
                    service_id="deepseek_" + account_id,
                    display_name=display,
                    app="deepseek",
                    is_current=False,
                    query=lambda k=key, t=timeout: quota_services.service_deepseek(
                        {"ANTHROPIC_AUTH_TOKEN": k}, t
                    ),
                )
            )

    # --- 火山引擎 (多账号) ---
    volc_accounts = run_ctx.credential("volcengine_quota_accounts")
    if isinstance(volc_accounts, dict) and volc_accounts:
        for account_id, payload in volc_accounts.items():
            display = (payload or {}).get("display_name") or "火山引擎 · " + account_id[:8]
            ak = (payload or {}).get("access_key") or ""
            sk = (payload or {}).get("secret_key") or ""
            meta = {"usage_script": {"accessKeyId": ak, "secretAccessKey": sk}}
            now = run_ctx.now
            timeout = run_ctx.http_timeout
            resolved.append(
                _Resolved(
                    service_id="volcengine_" + account_id,
                    display_name=display,
                    app="volcengine",
                    is_current=False,
                    query=lambda m=meta, n=now, t=timeout: quota_services.service_volcengine(
                        {}, m, n, t
                    ),
                )
            )

    # --- Claude (多账号) ---
    claude_accounts = run_ctx.credential("claude_quota_accounts")
    if isinstance(claude_accounts, dict) and claude_accounts:
        for account_id, payload in claude_accounts.items():
            display = (payload or {}).get("display_name") or "Claude · " + account_id[:8]
            oauth = (payload or {}).get("oauth")
            resolved.append(
                _Resolved(
                    service_id="claude_" + account_id,
                    display_name=display,
                    app="claude",
                    is_current=False,
                    query=lambda o=oauth: _claude_query_with_inject(run_ctx, o),
                )
            )
    elif (provider_meta.get("claude") or {}).get("enabled"):
        resolved.append(
            _Resolved(
                service_id="claude",
                display_name="Claude",
                app="claude",
                is_current=False,
                query=lambda: _claude_query_or_missing(run_ctx),
            )
        )

    # --- Grok (多账号) ---
    grok_accounts = run_ctx.credential("grok_quota_accounts")
    if isinstance(grok_accounts, dict) and grok_accounts:
        for account_id, payload in grok_accounts.items():
            display = (payload or {}).get("display_name") or "Grok · " + account_id[:8]
            oauth = (payload or {}).get("oauth")
            resolved.append(
                _Resolved(
                    service_id="grok_" + account_id,
                    display_name=display,
                    app="grok",
                    is_current=False,
                    query=lambda o=oauth: _grok_query_with_inject(run_ctx, o),
                )
            )
    elif (provider_meta.get("grok") or {}).get("enabled"):
        resolved.append(
            _Resolved(
                service_id="grok",
                display_name="Grok",
                app="grok",
                is_current=False,
                query=lambda: _grok_query_or_missing(run_ctx),
            )
        )

    # Antigravity 由 collect_usage.service_antigravity 统一处理
    # (该函数读取 antigravity_quota_accounts 并完成 OAuth 刷新 + 额度查询),
    # 不在此创建 _Resolved 条目, 避免重复空条目.

    return resolved


def _claude_query_with_inject(run_ctx, injected_oauth):
    """Claude 多账号查询: 使用注入的 oauth 凭证."""
    service_claude = getattr(quota_official, "service_claude")
    result = service_claude(
        run_ctx.home, run_ctx.now, run_ctx.http_timeout, injected=injected_oauth
    )
    if result is None:
        raise RuntimeError("Claude 凭证无效或已过期")
    return result


def _grok_query_with_inject(run_ctx, injected_oauth):
    """Grok 多账号查询: 使用注入的 oauth 凭证."""
    service_grok = getattr(quota_official, "service_grok")
    result = service_grok(
        run_ctx.home, run_ctx.now, run_ctx.http_timeout, injected=injected_oauth
    )
    if result is None:
        raise RuntimeError("Grok 凭证无效或已过期")
    return result


def _resolve_official_cli(run_ctx: RunContext) -> List[_Resolved]:
    """CLI 官方订阅: 有本机凭证才出条目; 过期等读失败给 pre_error (无 查询失败: 前缀)."""
    resolved: List[_Resolved] = []
    now_ts = run_ctx.now.timestamp()
    for service_id, name, app, read_name, query_name in _OFFICIAL_SPECS:
        read_token = getattr(quota_official, read_name)
        try:
            token = read_token(run_ctx.home, now_ts)
        except Exception as e:
            resolved.append(
                _Resolved(
                    service_id=service_id,
                    display_name=name,
                    app=app,
                    is_current=False,
                    pre_error_note=str(e)[:60] or "凭证不可用",
                )
            )
            continue
        if token is None:
            continue
        home = run_ctx.home
        now = run_ctx.now
        timeout = run_ctx.http_timeout

        def _query(
            q_name=query_name,
            h=home,
            n=now,
            t=timeout,
        ):
            return getattr(quota_official, q_name)(h, n, t)

        resolved.append(
            _Resolved(
                service_id=service_id,
                display_name=name,
                app=app,
                is_current=False,
                query=_query,
            )
        )
    return resolved


def _resolve_cli_cc_rows(run_ctx: RunContext, *, kimi_coding) -> List[Any]:
    """CLI CC Switch 驱动的 provider 行.

    返回混合列表: dict 表示 schema 错误预置条目; _Resolved 表示可 finalize 条目.
    调用方在无库时不应调用本函数.
    """
    cc_db = run_ctx.paths.get("cc_switch_db") or ""
    try:
        with sqlite3.connect("file:%s?mode=ro" % cc_db, uri=True) as db:
            rows = db.execute(
                "SELECT id, name, app_type, settings_config, meta, is_current "
                "FROM providers"
            ).fetchall()
    except sqlite3.Error:
        # schema 不兼容: 可诊断 error 条目 (字段与历史一致)
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
                "capturedAt": run_ctx.now.isoformat(timespec="seconds"),
                "note": "只读数据库 schema 不兼容",
            }
        ]

    resolved: List[Any] = []
    for _pid, name, app_type, settings_config, meta_json, is_current in rows:
        if name not in _CC_HANDLERS:
            continue
        service_id = _CC_HANDLERS[name]
        display = _CC_DISPLAY_NAMES.get(name, name)

        def _make_query(
            provider_name=name,
            svc_id=service_id,
            settings=settings_config,
            meta_raw=meta_json,
        ):
            env = (json.loads(settings or "{}")).get("env") or {}
            meta = json.loads(meta_raw or "{}")
            provider_env = run_ctx.credential("provider_env") or {}
            env.update(provider_env.get(svc_id, {}))
            provider_meta = run_ctx.credential("provider_meta") or {}
            meta.update(provider_meta.get(svc_id, {}))
            if provider_name == "火山Codingplan":
                return quota_services.service_volcengine(
                    env, meta, run_ctx.now, run_ctx.http_timeout
                )
            if provider_name == "DeepSeek":
                return quota_services.service_deepseek(env, run_ctx.http_timeout)
            # Kimi For Coding
            return kimi_coding(env)

        resolved.append(
            _Resolved(
                service_id=service_id,
                display_name=display,
                app=app_type,
                is_current=bool(is_current),
                query=_make_query,
            )
        )
    return resolved


def _resolve_cli(run_ctx: RunContext, *, kimi_coding) -> List[Any]:
    """CLI 模式: CC Switch 行 (若存在) + 官方本机探测."""
    cc_db = run_ctx.paths.get("cc_switch_db") or ""
    items: List[Any] = []
    if os.path.exists(cc_db):
        items.extend(_resolve_cli_cc_rows(run_ctx, kimi_coding=kimi_coding))
    items.extend(_resolve_official_cli(run_ctx))
    return items


# ---------------------------------------------------------------- public builder


def build_quota_services(run_ctx: RunContext, *, kimi_coding, opencode_go, providers=None) -> List[Dict[str, Any]]:
    """统一 App/CLI 额度服务构建核.

    Parameters
    ----------
    run_ctx:
        单次 collect 的 RunContext (app_mode / credentials / paths / now / timeout).
    kimi_coding:
        ``collect_usage.service_kimi_coding`` 可调用对象; 仍住在 façade 以保留
        模块 global / monkeypatch 契约, 由调用方注入避免循环 import.
    providers:
        可选 ``app`` 值集合, 用于订阅额度定向刷新 (subscription-provider-refresh);
        仅构建属于这些 provider 的额度服务. 为 ``None`` 时保持全量行为.

    Returns
    -------
    list of service dicts (artifact ``services`` 子集, 不含 codex/antigravity).
    """
    if run_ctx is None:
        raise RuntimeError("build_quota_services requires RunContext")

    if run_ctx.app_mode:
        items = _resolve_app(
            run_ctx, kimi_coding=kimi_coding, opencode_go=opencode_go
        )
    else:
        items = _resolve_cli(run_ctx, kimi_coding=kimi_coding)

    # 订阅额度定向刷新: 只保留目标 provider 的 _Resolved 条目, 复用既有
    # handler / recovery / credential update 逻辑, 不扫描其他 provider.
    if providers is not None:
        target_apps = set(providers)
        items = [
            item for item in items
            if isinstance(item, dict) or item.app in target_apps
        ]

    services: List[Dict[str, Any]] = []
    for item in items:
        if isinstance(item, dict):
            # 预置完整条目 (schema error)
            services.append(item)
            continue
        svc = quota_service_entry(
            item.service_id,
            item.display_name,
            item.app,
            run_ctx.now,
            is_current=item.is_current,
        )
        if item.pre_error_note is not None:
            svc["status"] = "error"
            svc["note"] = item.pre_error_note
            services.append(svc)
            continue
        services.append(finalize_quota_service(svc, item.query))
    return services
