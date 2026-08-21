"""运行时时间和 HTTP 工具.

生产路径通过显式 `RunContext` 读取时间、时区和 HTTP 注入. 模块级 setter
只为旧的直接测试调用保留, 新代码不得依赖它们.
"""

import datetime
import json
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set


# 旧直接测试 seam; 生产路径不读取这些镜像.
_RUNTIME_TZ = None

# 旧直接测试 seam; 生产路径从 RunContext.http 读取.
_RUNTIME_HTTP = {}

# 旧直接测试 seam; 生产路径从 RunContext 日期字段读取.
TODAY = None
CUTOFF_TS = None
DAY_LIST = []


@dataclass
class RunContext:
    """单次 collector 运行的显式状态 (S4b).

    credentials / credential_updates / credential_challenges 是单次运行的
    可变容器. 生产采集显式传递本对象; 模块级 setter 只服务旧直接测试.
    """

    app_mode: bool
    home: str
    now: datetime.datetime
    credentials: Dict[str, Any]
    credential_updates: List[Dict[str, Any]]
    credential_challenges: List[Dict[str, Any]]
    paths: Dict[str, str] = field(default_factory=dict)
    timezone: Any = None  # tzinfo
    http: Dict[str, Any] = field(default_factory=dict)
    days: int = 14
    http_timeout: float = 8.0
    # None = 未启用门禁 (CLI); set = Bridge App 能力白名单
    capabilities: Optional[Set[str]] = None
    # 输入 ctx 全量快照 (含 codex_quota_account_order 等协议映射键)
    raw: Dict[str, Any] = field(default_factory=dict)
    today: Optional[str] = None
    cutoff_ts: Optional[float] = None
    day_list: List[str] = field(default_factory=list)
    codex_usage_url: Optional[str] = None
    codex_token_url: Optional[str] = None
    metrics: Any = None

    def capability_allowed(self, name: str) -> bool:
        """能力门禁: capabilities 为 None 时全部放行."""
        return self.capabilities is None or name in self.capabilities

    def credential(self, name: str, default: Any = None) -> Any:
        return self.credentials.get(name, default)

    def context_get(self, name: str, default: Any = None) -> Any:
        """读取运行时顶层 context 键 (协议映射键)."""
        return self.raw.get(name, default)

    def day_of(self, ts_seconds):
        return datetime.datetime.fromtimestamp(ts_seconds, self.timezone).strftime("%Y-%m-%d")

    def hour_of(self, ts_seconds):
        return datetime.datetime.fromtimestamp(ts_seconds, self.timezone).hour

    def parse_iso(self, ts):
        try:
            value = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if value.tzinfo is None:
                value = value.replace(tzinfo=self.timezone)
            return value.timestamp()
        except Exception:
            return None

    def epoch_from_iso(self, ts):
        value = self.parse_iso(ts or "")
        return int(value) if value else None

    def urlopen(self, request, **kwargs):
        if self.metrics is not None:
            self.metrics.increment("http_request_count")
        opener = self.http.get("urlopen") or urllib.request.urlopen
        return opener(request, **kwargs)

    def http_get_json(self, url, headers, http_timeout):
        override = self.http.get("get_json")
        if override:
            if self.metrics is not None:
                self.metrics.increment("http_request_count")
            return override(url, headers)
        req = urllib.request.Request(url, headers=headers)
        with self.urlopen(req, timeout=http_timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))


def set_timezone(tz):
    """由 _configure_runtime 调用, 设置本轮运行时时区."""
    global _RUNTIME_TZ
    _RUNTIME_TZ = tz


def set_http_overrides(overrides):
    """由 _configure_runtime 调用, 设置本轮 HTTP 注入覆盖."""
    global _RUNTIME_HTTP
    _RUNTIME_HTTP = overrides or {}


def set_date_buckets(today, cutoff_ts, day_list):
    """由 _configure_runtime 调用, 设置本轮日期桶边界."""
    global TODAY, CUTOFF_TS, DAY_LIST
    TODAY = today
    CUTOFF_TS = cutoff_ts
    DAY_LIST = day_list


def day_of(ts_seconds, context=None):
    if context is not None:
        return context.day_of(ts_seconds)
    return datetime.datetime.fromtimestamp(ts_seconds, _RUNTIME_TZ).strftime("%Y-%m-%d")


def hour_of(ts_seconds, context=None):
    if context is not None:
        return context.hour_of(ts_seconds)
    return datetime.datetime.fromtimestamp(ts_seconds, _RUNTIME_TZ).hour


def parse_iso(ts, context=None):
    if context is not None:
        return context.parse_iso(ts)
    try:
        value = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        if value.tzinfo is None:
            value = value.replace(tzinfo=_RUNTIME_TZ)
        return value.timestamp()
    except Exception:
        return None


def epoch_from_iso(ts, context=None):
    t = parse_iso(ts or "", context)
    return int(t) if t else None


def urlopen(request, *, context=None, **kwargs):
    """HTTP 打开; 生产传入 RunContext, 旧测试可使用 setter 注入."""
    if context is not None:
        return context.urlopen(request, **kwargs)
    opener = _RUNTIME_HTTP.get("urlopen") or urllib.request.urlopen
    return opener(request, **kwargs)


def http_get_json(url, headers, http_timeout, context=None):
    """GET JSON; 生产传入 RunContext, 旧测试可使用 setter 注入."""
    if context is not None:
        return context.http_get_json(url, headers, http_timeout)
    override = _RUNTIME_HTTP.get("get_json")
    if override:
        return override(url, headers)
    req = urllib.request.Request(url, headers=headers)
    with urlopen(req, timeout=http_timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))
