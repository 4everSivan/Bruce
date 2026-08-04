"""Codex CLI legacy 认证读取与额度查询 (阶段 D: 从 collect_usage.py 拆出).

包含 codex 多账号查询的公共逻辑: service ID 生成, 窗口标签, 错误分类,
单账号 wham/usage 查询. CLI legacy 的磁盘认证读取/刷新/写回仍在
collect_usage.py 的 service_codex_accounts 中 (阶段 D 剩余).
App 模式和 CLI 模式共用查询主体, 通过参数注入 URL/时间/HTTP/challenge 记录.
"""

import hashlib
import json
import urllib.parse
import urllib.request


def window_label(seconds):
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return "窗口"
    if s <= 6 * 3600:
        return "5小时窗口"
    if s <= 8 * 24 * 3600:
        return "每周窗口"
    return "每月窗口"


def refresh(refresh_token, token_url, client_id, urlopen, http_timeout):
    """CLI legacy: 用 refresh_token 换新令牌 (App 模式不调用, token 由 Swift 管理)."""
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "client_id": client_id,
            "refresh_token": refresh_token,
        }
    ).encode()
    req = urllib.request.Request(
        token_url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urlopen(req, timeout=http_timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def service_id(acc_id):
    """codex_ + SHA256(accountID) 前 16 位 hex. 跨 Swift/Python 统一."""
    return "codex_" + hashlib.sha256((acc_id or "").encode("utf-8")).hexdigest()[:16]


def failure_kind(exc):
    """从异常分类固定 failureKind: auth/permission/rateLimit/network/server/invalidResponse."""
    code = getattr(exc, "code", None)
    message = str(exc)
    if code == 401 or "HTTP 401" in message:
        return "auth"
    if code == 403 or "HTTP 403" in message:
        return "permission"
    if code == 429 or "HTTP 429" in message:
        return "rateLimit"
    if code is not None and 500 <= code < 600:
        return "server"
    return "network"


def query_single_account(
    acc_id,
    access_token,
    display_name,
    style,
    usage_url,
    now,
    http_get_json,
    record_challenge,
):
    """查询单账号 wham/usage 额度, 两种调用方共用同一查询主体.

    style="app": 消费注入的短期 access token, 错误分类生成固定文案
    (401 -> accessRejected challenge; 403 -> 权限/套餐错误; 其余 -> 暂时
    失败), 不解析响应体进 note. style="legacy": 保留 CLI 兼容行为, 错误
    文案带原始消息.

    display_name 由 Swift 传入最终展示名 (含 "Codex · " 前缀), 原样写入
    service.name, 不添加或删除前缀.
    成功: freshness=fresh, capturedAt=本轮成功时间.
    失败: freshness=unavailable, failureKind=分类, 不写 capturedAt.
    """
    svc = {
        "id": service_id(acc_id),
        "name": display_name or "账号",
        "app": "codex",
        "isCurrent": False,
        "status": "ok",
        "kind": None,
        "plan": None,
        "windows": [],
        "balance": None,
        "currency": None,
        "capturedAt": now.isoformat(timespec="seconds"),
        "freshness": "fresh",
        "failureKind": None,
        "note": "",
    }
    try:
        d = http_get_json(
            usage_url,
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
                    "label": window_label(secs),
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
        kind = failure_kind(e)
        if style == "app":
            message = str(e)
            if code == 401 or "HTTP 401" in message:
                svc["status"] = "error"
                svc["note"] = "登录态已失效, 请重新登录该账号"
                record_challenge(acc_id)
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
        # 失败时不写 capturedAt (不伪造成功时间); freshness=unavailable
        del svc["capturedAt"]
        svc["freshness"] = "unavailable"
        svc["failureKind"] = kind
    return svc
