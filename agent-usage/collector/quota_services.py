"""额度服务查询: DeepSeek + 火山引擎 (阶段 D: 从 collect_usage.py 拆出).

纯查询逻辑, 通过 runtime 模块访问 HTTP 工具和时间函数.
不持有状态; now 和 http_timeout 由调用方传入.
"""

import base64
import datetime
import hashlib
import hmac
import urllib.error
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


# ---------------------------------------------------------------- 智谱 Coding Plan

_ZHIPU_CN_HOST = "open.bigmodel.cn"
_ZHIPU_EN_HOST = "api.z.ai"


def _zhipu_quota_base(base_url):
    """按 base_url 路由到智谱额度端点 host; 含 bigmodel.cn 走国内站, 否则国际站.

    与 CC Switch (coding_plan.rs::zhipu_quota_base) 一致: 额度端点与推理端点
    同 host, 不做跨 host 回退, 也不做鉴权启发式.
    """
    if "bigmodel.cn" in (base_url or "").lower():
        return _ZHIPU_CN_HOST
    return _ZHIPU_EN_HOST


def _zhipu_reset_seconds(reset_ms):
    """智谱 nextResetTime 为毫秒时间戳; 转 epoch 秒, 非正数返回 None.

    兼容秒级时间戳 (值未超 1e12 视为秒), 与 quota_official._is_expired 同约定.
    """
    if not isinstance(reset_ms, (int, float)) or reset_ms <= 0:
        return None
    if reset_ms > 1_000_000_000_000:
        return int(reset_ms / 1000)
    return int(reset_ms)


def _parse_zhipu_windows(limits):
    """解析智谱 limits 数组, 只取额度窗口条目 (忽略 TIME_LIMIT 等非额度条目).

    智谱接口已从 token 制度演进为 credit 制度: type 由 TOKENS_LIMIT 变为
    CREDIT_LIMIT (实测 2026-08, level=pro); 两者窗口语义一致, 一并识别.

    窗口分类与 CC Switch (coding_plan.rs::parse_zhipu_token_tiers) 一致:
    - unit 3 -> 每 5 小时; unit 6 -> 每周 (只锚定 unit, 不绑 number).
    - unit 缺失/未知走兜底: 无 nextResetTime 的优先归每 5 小时, 其余按 reset 升序填槽.
    - 老套餐只回 1 条, 自然降级为仅每 5 小时; 最多取 2 条.
    percentage 即已用百分比, 不裁剪 (下游 parseWindow 负责 clamp).
    """
    five_hour = None
    weekly = None
    unclassified = []

    if isinstance(limits, list):
        for item in limits:
            if not isinstance(item, dict):
                continue
            limit_type = str(item.get("type") or "").upper()
            if limit_type not in ("TOKENS_LIMIT", "CREDIT_LIMIT"):
                continue
            try:
                percentage = float(item.get("percentage"))
            except (TypeError, ValueError):
                percentage = 0.0
            reset_sec = _zhipu_reset_seconds(item.get("nextResetTime"))
            unit = item.get("unit")
            entry = (reset_sec, percentage)
            if unit == 3 and five_hour is None:
                five_hour = entry
            elif unit == 6 and weekly is None:
                weekly = entry
            else:
                unclassified.append(entry)

    # 兜底: 无 reset 优先 (5 小时桶 0% 时可能没有 reset), 其余按 reset 升序.
    unclassified.sort(key=lambda e: (e[0] is not None, e[0] if e[0] is not None else -1))
    for entry in unclassified:
        if five_hour is None:
            five_hour = entry
        elif weekly is None:
            weekly = entry

    windows = []
    if five_hour is not None:
        windows.append({
            "label": "每 5 小时",
            "usedPercent": five_hour[1],
            "windowMinutes": 300,
            "resetsAt": five_hour[0],
        })
    if weekly is not None:
        windows.append({
            "label": "每周",
            "usedPercent": weekly[1],
            "windowMinutes": 10080,
            "resetsAt": weekly[0],
        })
    return windows


def service_zhipu(env, http_timeout):
    """查询智谱 Coding Plan 个人版额度. 无 key/base_url 返回 None, 查询失败抛异常.

    凭证取 env.ANTHROPIC_BASE_URL + env.ANTHROPIC_AUTH_TOKEN (与 CC Switch 里
    智谱挂在 Claude app 下的 Anthropic 风格 env 一致). 端点 GET
    /api/monitor/usage/quota/limit, Authorization 头为裸 API key (不加 Bearer).
    """
    key = env.get("ANTHROPIC_AUTH_TOKEN") or ""
    base_url = env.get("ANTHROPIC_BASE_URL") or ""
    if not key or not base_url:
        return None
    url = "https://%s/api/monitor/usage/quota/limit" % _zhipu_quota_base(base_url)
    headers = {
        "Authorization": key,  # 智谱不加 Bearer 前缀
        "Content-Type": "application/json",
        "Accept-Language": "en-US,en",
    }
    try:
        d = runtime.http_get_json(url, headers, http_timeout)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise RuntimeError("智谱凭证被拒绝 (HTTP %d), 请检查 API key" % e.code)
        raise RuntimeError("智谱额度请求失败 (HTTP %d)" % e.code)
    if not isinstance(d, dict):
        raise RuntimeError("智谱额度响应不是 JSON 对象")
    if d.get("success") is False:
        raise RuntimeError("智谱额度查询失败: %s" % (d.get("msg") or "未知错误"))
    data = d.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("智谱额度响应缺少 data 字段")
    return {
        "kind": "windows",
        "plan": data.get("level"),
        "windows": _parse_zhipu_windows(data.get("limits")),
    }
