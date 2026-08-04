"""运行时时间工具与 HTTP 工具 (阶段 D: 从 collect_usage.py 拆出).

持有 `_RUNTIME_TZ` (运行时时区) 和 `_RUNTIME_HTTP` (HTTP 注入覆盖),
由 _configure_runtime 每次运行重置. 时间函数是纯逻辑; HTTP 工具
通过 _RUNTIME_HTTP 支持测试注入.
"""

import datetime
import json
import urllib.request

# 运行时时区; 由 collect_usage._configure_runtime 每次运行重置.
_RUNTIME_TZ = None

# HTTP 注入覆盖 (get_json/post_json/urlopen); 测试用, 生产为空.
_RUNTIME_HTTP = {}


def set_timezone(tz):
    """由 _configure_runtime 调用, 设置本轮运行时时区."""
    global _RUNTIME_TZ
    _RUNTIME_TZ = tz


def set_http_overrides(overrides):
    """由 _configure_runtime 调用, 设置本轮 HTTP 注入覆盖."""
    global _RUNTIME_HTTP
    _RUNTIME_HTTP = overrides or {}


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


def epoch_from_iso(ts):
    t = parse_iso(ts or "")
    return int(t) if t else None


def urlopen(request, **kwargs):
    """HTTP 打开; 测试可通过 _RUNTIME_HTTP['urlopen'] 注入."""
    opener = _RUNTIME_HTTP.get("urlopen") or urllib.request.urlopen
    return opener(request, **kwargs)


def http_get_json(url, headers, http_timeout):
    """GET JSON; 测试可通过 _RUNTIME_HTTP['get_json'] 注入."""
    override = _RUNTIME_HTTP.get("get_json")
    if override:
        return override(url, headers)
    req = urllib.request.Request(url, headers=headers)
    with urlopen(req, timeout=http_timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def http_post_json(url, payload, headers, http_timeout):
    """POST JSON; 测试可通过 _RUNTIME_HTTP['post_json'] 注入."""
    override = _RUNTIME_HTTP.get("post_json")
    if override:
        return override(url, payload, headers)
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urlopen(req, timeout=http_timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))
