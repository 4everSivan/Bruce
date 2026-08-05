"""运行时时间工具, HTTP 工具与 RunContext (阶段 D / S4b).

持有 `_RUNTIME_TZ` (运行时时区) 和 `_RUNTIME_HTTP` (HTTP 注入覆盖),
由 _configure_runtime 每次运行重置. 时间函数是纯逻辑; HTTP 工具
通过 _RUNTIME_HTTP 支持测试注入.

RunContext 承载单次 collect 的路径/时间/凭证/能力等状态; 过渡期
`_configure_runtime` 仍同步模块 global, 新代码应优先读 RunContext,
禁止新增 global 依赖.
"""

import datetime
import json
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set


# 运行时时区; 由 collect_usage._configure_runtime 每次运行重置.
_RUNTIME_TZ = None

# HTTP 注入覆盖 (get_json/post_json/urlopen); 测试用, 生产为空.
_RUNTIME_HTTP = {}

# 日期桶状态; 由 collect_usage._configure_runtime 每次运行重置.
TODAY = None
CUTOFF_TS = None
DAY_LIST = []


@dataclass
class RunContext:
    """单次 collector 运行的显式状态 (S4b).

    credentials / credential_updates / credential_challenges 是可变容器;
    _configure_runtime 把它们绑定到模块 global, 使尚未迁移的 service
    路径继续写入同一 list, 输出语义不变.
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

    def capability_allowed(self, name: str) -> bool:
        """能力门禁: capabilities 为 None 时全部放行."""
        return self.capabilities is None or name in self.capabilities

    def credential(self, name: str, default: Any = None) -> Any:
        return self.credentials.get(name, default)

    def context_get(self, name: str, default: Any = None) -> Any:
        """读取运行时顶层 context 键 (协议映射键)."""
        return self.raw.get(name, default)


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
