"""额度服务查询: DeepSeek + 火山引擎 (阶段 D: 从 collect_usage.py 拆出).

纯查询逻辑, 通过 runtime 模块访问 HTTP 工具和时间函数.
不持有状态; now 和 http_timeout 由调用方传入.
"""

import base64
import datetime
import hashlib
import hmac
import urllib.parse

import runtime


def service_deepseek(env, http_timeout):
    """查询 DeepSeek 余额. 无 key 返回 None."""
    key = env.get("ANTHROPIC_AUTH_TOKEN") or ""
    if not key:
        return None
    d = runtime.http_get_json(
        "https://api.deepseek.com/user/balance",
        {"Authorization": "Bearer " + key, "Accept": "application/json"},
        http_timeout,
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


def _volc_sign(method, host, query, payload, ak, sk, now, region="cn-beijing", service="ark"):
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
                "resetsAt": runtime.epoch_from_iso(reset) if isinstance(reset, str) else reset,
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


def service_volcengine(env, meta, now, http_timeout):
    """查询火山引擎 Coding Plan 额度. 无凭证返回 None, 查询失败抛异常."""
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
                headers = _volc_sign("GET", host, query, "", ak, sk, now)
                headers.pop("host", None)
                url = "https://%s/?%s" % (host, urllib.parse.urlencode(query))
                d = runtime.http_get_json(url, headers, http_timeout)
                result = d.get("Result") or d.get("result") or d
                return _volc_parse(result)
            except Exception as e:  # try next candidate/action
                last_err = e
                continue
    raise last_err or RuntimeError("volcengine query failed")
