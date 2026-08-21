"""官方订阅额度查询: Claude (Anthropic OAuth) + Grok (xAI gRPC-web).

机制移植自 CC Switch (farion1231/cc-switch, commit 59a2bd1)
src-tauri/src/services/subscription.rs 与 subscription_grok.rs.
凭证实时只读, 不刷新, 不回写第三方存储; 查询失败抛异常由调用方折叠.
"""

import json
import os
import struct
import subprocess
import urllib.error
import urllib.request

import runtime

CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_BETA_HEADER = "oauth-2025-04-20"
CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"

GROK_BILLING_URL = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
GROK_OIDC_SCOPE_PREFIX = "https://auth.x.ai::"
GROK_LEGACY_SCOPE = "https://accounts.x.ai/sign-in"

# Claude 已知窗口 -> (统一措辞标签, windowMinutes); 未知窗口按原 key 透传.
_CLAUDE_TIER_LABELS = {
    "five_hour": ("每 5 小时", 300),
    "seven_day": ("每周", 10080),
    "seven_day_opus": ("每周 Opus", 10080),
    "seven_day_sonnet": ("每周 Sonnet", 10080),
}


# ---------------------------------------------------------------- 凭证读取 (只读)

def _security_find(service):
    """包装 security CLI 读取登录 Keychain 通用密码 (无 account 过滤);
    测试可替换; 未找到返回 None."""
    try:
        proc = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _is_expired(expires_at, now_ts, context=None):
    """兼容 Unix 秒/毫秒时间戳与 ISO 字符串; 无法解析时不视为过期."""
    if expires_at is None:
        return False
    if isinstance(expires_at, (int, float)):
        ts = expires_at / 1000 if expires_at > 1_000_000_000_000 else expires_at
        return ts < now_ts
    if isinstance(expires_at, str):
        parsed = runtime.parse_iso(expires_at, context)
        return parsed is not None and parsed < now_ts
    return False


def _parse_claude_credentials(content, now_ts, context=None):
    """解析 Claude OAuth 凭证 JSON (Keychain 与文件共用), 返回 access token.
    无 OAuth 条目或空 token 返回 None; 过期抛 RuntimeError (可诊断)."""
    try:
        parsed = json.loads(content)
    except Exception:
        return None
    entry = parsed.get("claudeAiOauth") or parsed.get("claude.ai_oauth")
    if not isinstance(entry, dict):
        return None
    token = entry.get("accessToken") or ""
    if not token:
        return None
    if _is_expired(entry.get("expiresAt"), now_ts, context):
        raise RuntimeError("Claude OAuth token 已过期, 请重新登录 Claude CLI")
    return token


def read_claude_token(home, now_ts, keychain_reader=None, injected=None, context=None):
    """App 模式注入凭证优先, 其次 Keychain, 最后 ~/.claude/.credentials.json 兜底.

    injected 为 Swift 注入的 claude_oauth JSON (claudeAiOauth 同构);
    解析失败 (过期/无效) 抛错, 不静默回退本机 (避免注入与本地分叉).
    """
    if injected:
        return _parse_claude_credentials(injected, now_ts, context)
    reader = keychain_reader or _security_find
    raw = reader(CLAUDE_KEYCHAIN_SERVICE)
    if raw:
        token = _parse_claude_credentials(raw, now_ts, context)
        if token:
            return token
    cred_path = os.path.join(home, ".claude", ".credentials.json")
    if not os.path.exists(cred_path):
        return None
    try:
        with open(cred_path, encoding="utf-8") as fh:
            return _parse_claude_credentials(fh.read(), now_ts, context)
    except OSError:
        return None


def _select_grok_entry(root):
    """OIDC (SuperGrok) 优先, legacy session 兜底; 只接受 key 非空的条目."""
    oidc = None
    legacy = None
    for scope, value in root.items():
        if not isinstance(value, dict):
            continue
        key = value.get("key")
        if not isinstance(key, str) or not key:
            continue
        if scope.startswith(GROK_OIDC_SCOPE_PREFIX):
            oidc = value
        elif scope == GROK_LEGACY_SCOPE or "/sign-in" in scope:
            legacy = value
    return oidc or legacy


def read_grok_token(home, now_ts, injected=None, context=None):
    """App 模式注入凭证优先, 否则读取 ~/.grok/auth.json 首选条目.

    injected 为 Swift 注入的 grok_oauth JSON (scope 映射同构);
    注入内容不可解析时回退本机文件; 解析成功但过期时抛错
    (不静默回退, 避免注入与本地分叉).
    """
    if injected:
        parsed = injected
        if isinstance(parsed, str):
            try:
                parsed = json.loads(parsed)
            except ValueError:
                parsed = None
        if isinstance(parsed, dict):
            entry = _select_grok_entry(parsed)
            if entry is not None:
                if _is_expired(entry.get("expires_at"), now_ts, context):
                    raise RuntimeError("Grok OAuth token 已过期, 请重新 grok login")
                return entry["key"]
    auth_path = os.path.join(home, ".grok", "auth.json")
    if not os.path.exists(auth_path):
        return None
    try:
        with open(auth_path, encoding="utf-8") as fh:
            parsed = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(parsed, dict):
        return None
    entry = _select_grok_entry(parsed)
    if entry is None:
        return None
    if _is_expired(entry.get("expires_at"), now_ts, context):
        raise RuntimeError("Grok OAuth token 已过期, 请重新 grok login")
    return entry["key"]


# ---------------------------------------------------------------- Claude 查询

def service_claude(home, now, http_timeout, keychain_reader=None, injected=None, context=None):
    """查询 Claude 官方订阅额度. 无凭证返回 None, 查询失败抛异常."""
    now_ts = now.timestamp()
    token = read_claude_token(
        home, now_ts, keychain_reader, injected=injected, context=context
    )
    if not token:
        return None
    d = runtime.http_get_json(
        CLAUDE_USAGE_URL,
        {
            "Authorization": "Bearer " + token,
            "anthropic-beta": CLAUDE_BETA_HEADER,
            "Accept": "application/json",
        },
        http_timeout,
        context=context,
    )
    if not isinstance(d, dict):
        raise RuntimeError("Claude 用量响应不是 JSON 对象")
    windows = []
    for key, value in d.items():
        if key == "extra_usage" or not isinstance(value, dict):
            continue
        util = value.get("utilization")
        if util is None:
            continue
        label, minutes = _CLAUDE_TIER_LABELS.get(key, (key, None))
        windows.append(
            {
                "label": label,
                "usedPercent": max(0.0, min(100.0, float(util))),
                "windowMinutes": minutes,
                "resetsAt": runtime.epoch_from_iso(value.get("resets_at"), context),
            }
        )
    extra = d.get("extra_usage")
    if isinstance(extra, dict) and extra.get("is_enabled"):
        util = extra.get("utilization")
        if util is not None:
            windows.append(
                {
                    "label": "额外用量",
                    "usedPercent": max(0.0, min(100.0, float(util))),
                    "windowMinutes": None,
                    "resetsAt": None,
                    "ownRow": True,
                }
            )
    return {"kind": "windows", "plan": None, "windows": windows}


# ---------------------------------------------------------------- Grok gRPC-web / protobuf

def _read_varint(data, index):
    """返回 (value, next_index); 不完整返回 (None, index+1) 供重同步."""
    value = 0
    shift = 0
    while index < len(data) and shift < 64:
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, index
        shift += 7
    return None, index


def _scan_protobuf(data, depth, path, order, scan):
    """递归扫描 protobuf 消息, 收集 varint 与 fixed32 字段 (无 .proto).

    length-delimited 字段一律当嵌套消息试扫 (深度 <= 4);
    无法解析的字节从字段起点 +1 重新同步. 返回下一个 fixed32 序号.
    """
    index = 0
    next_order = order
    while index < len(data):
        field_start = index
        key, index = _read_varint(data, index)
        if not key:
            index = field_start + 1
            continue
        field_number = key >> 3
        wire_type = key & 0x07
        field_path = path + [field_number]
        if wire_type == 0:
            value, index = _read_varint(data, index)
            if value is None:
                index = field_start + 1
            else:
                scan["varint"].append((field_path, value))
        elif wire_type == 1:
            if index + 8 > len(data):
                return next_order
            index += 8
        elif wire_type == 2:
            length, index = _read_varint(data, index)
            if length is None or length > len(data) - index:
                index = field_start + 1
                continue
            end = index + length
            if depth < 4:
                next_order = _scan_protobuf(
                    data[index:end], depth + 1, field_path, next_order, scan
                )
            index = end
        elif wire_type == 5:
            if index + 4 > len(data):
                return next_order
            value = struct.unpack_from("<f", data, index)[0]
            scan["fixed32"].append((field_path, value, next_order))
            next_order += 1
            index += 4
        else:
            index = field_start + 1
    return next_order


def _grpc_web_data_frames(data):
    """拆出 gRPC-web data 帧 (跳过 trailer 帧); 任一帧长度非法返回空列表."""
    frames = []
    index = 0
    while index < len(data):
        if index + 5 > len(data):
            return []
        flags = data[index]
        length = struct.unpack_from(">I", data, index + 1)[0]
        start = index + 5
        end = start + length
        if end > len(data):
            return []
        if flags & 0x80 == 0:
            frames.append(data[start:end])
        index = end
    return frames


def _looks_like_protobuf(data):
    """响应体无帧头时, 首字节像合法 protobuf tag 即按裸 protobuf 兜底."""
    if not data:
        return False
    first = data[0]
    return first >> 3 > 0 and (first & 0x07) in (0, 1, 2, 5)


def _percent_decode(text):
    """gRPC message 的 percent-encoding 解码; 失败序列原样保留."""
    out = bytearray()
    raw = text.encode("utf-8", "replace")
    i = 0
    while i < len(raw):
        if raw[i:i + 1] == b"%" and i + 3 <= len(raw):
            try:
                out.append(int(raw[i + 1:i + 3].decode("ascii"), 16))
                i += 3
                continue
            except (ValueError, UnicodeDecodeError):
                pass
        out.append(raw[i])
        i += 1
    return out.decode("utf-8", "replace")


def _grpc_web_trailer_fields(data):
    """从 trailer 帧 (flags & 0x80) 解析 grpc-status / grpc-message."""
    fields = {}
    index = 0
    while index + 5 <= len(data):
        flags = data[index]
        length = struct.unpack_from(">I", data, index + 1)[0]
        start = index + 5
        end = start + length
        if end > len(data):
            break
        if flags & 0x80 != 0:
            text = data[start:end].decode("utf-8", "replace")
            for line in text.splitlines():
                if not line or ":" not in line:
                    continue
                key, value = line.split(":", 1)
                fields[key.strip().lower()] = _percent_decode(value.strip())
        index = end
    return fields


def parse_billing_payload(data, now_ts):
    """从响应体提取 (used_percent, resets_at); 定位失败抛 RuntimeError.

    启发式 (与 CC Switch / CodexBar 一致):
    - 百分比: fixed32 中路径末段为 1, 值域 [0,100], 取路径最浅, 出现最早者;
    - 重置时间: varint 落在合理 Unix 秒区间且晚于当前, 优先路径 [1,5,1];
    - 零用量特判: proto3 省略 0 值 percent, 存在重置时间与周期标记时按 0%.
    """
    payloads = _grpc_web_data_frames(data)
    if not payloads and _looks_like_protobuf(data):
        payloads = [data]
    if not payloads:
        raise RuntimeError("Grok 账单响应无 protobuf 载荷")
    scan = {"fixed32": [], "varint": []}
    for payload in payloads:
        _scan_protobuf(payload, 0, [], 0, scan)

    percent_candidates = [
        (path, value, order)
        for path, value, order in scan["fixed32"]
        if path and path[-1] == 1 and 0.0 <= value <= 100.0
    ]
    percent = None
    if percent_candidates:
        percent_candidates.sort(key=lambda item: (len(item[0]), item[2]))
        percent = percent_candidates[0][1]

    reset_candidates = [
        (path, value)
        for path, value in scan["varint"]
        if 1_700_000_000 <= value <= 2_100_000_000 and value > now_ts
    ]
    reset = None
    preferred = [v for path, v in reset_candidates if path == [1, 5, 1]]
    if preferred:
        reset = min(preferred)
    elif reset_candidates:
        reset = min(v for _, v in reset_candidates)

    has_usage_period = any(
        path[:2] == [1, 6] or (path == [1, 8, 1] and value in (1, 2))
        for path, value in scan["varint"]
    )
    if percent is None and not scan["fixed32"] and reset is not None and has_usage_period:
        percent = 0.0
    if percent is None:
        raise RuntimeError("无法从 Grok 账单响应定位用量")
    return float(percent), reset


def _grok_tier_label(resets_at, now_ts):
    """按重置距今天数推断窗口标签 (CC 阈值):
    < 1 天 -> 每 5 小时; 4-12 天每周; 20-45 天每月; 其余额度."""
    if resets_at:
        days = round((resets_at - now_ts) / 86400.0)
        if days < 1:
            return "每 5 小时"
        if 4 <= days <= 12:
            return "每周"
        if 20 <= days <= 45:
            return "每月"
    return "额度"


def _grok_window_minutes(resets_at, now_ts):
    """根据重置距今天数推断窗口分钟数 (供 Swift 精确映射):
    < 1 天 -> 300 (5h); 4-12 天 -> 10080 (周); 20-45 天 -> 43200 (月)."""
    if not resets_at:
        return None
    days = round((resets_at - now_ts) / 86400.0)
    if days < 1:
        return 300
    if 4 <= days <= 12:
        return 10080
    if 20 <= days <= 45:
        return 43200
    return None


def _grok_auth_failure(status, message):
    if status == 16:
        return True
    if status != 7:
        return False
    lower = message.lower()
    return (
        "bad-credentials" in lower
        or "unauthenticated" in lower
        or ("oauth2" in lower and "could not be validated" in lower)
        or (
            "access token" in lower
            and any(
                s in lower
                for s in ("invalid", "expired", "could not be validated")
            )
        )
    )


def _grok_raise_for_grpc_status(status, message):
    """非 0 grpc-status 映射为可诊断异常; 瞬时状态 (4/14) 同样抛出让上层保旧快照."""
    if _grok_auth_failure(status, message):
        raise RuntimeError("Grok 凭证被拒绝 (grpc-status %d), 请重新 grok login" % status)
    if status == 9 and message.strip().lower().rstrip(".") == "no personal team":
        raise RuntimeError("Grok 团队账号暂不支持账单接口")
    raise RuntimeError("Grok 账单 RPC 失败 (grpc-status %d): %s" % (status, message[:60]))


# ---------------------------------------------------------------- OpenCode GO

# OpenCode GO 订阅用量来自 opencode.ai 网页控制台 (workspace 维度) 的
# SolidStart server function. 该端点是前端私有协议 (seroval RPC), 但返回
# 与网页面板完全一致的数据: rollingUsage (滚动/5 小时), weeklyUsage (每周),
# monthlyUsage (每月) 的 usagePercent 与 resetInSec.
OPCODE_WEB_URL = "https://opencode.ai"
OPCODE_SERVER_FN_URL = OPCODE_WEB_URL + "/_server"
# lite.subscription.get 的 server function 哈希 (前端 JS 内嵌, 随版本可能变化;
# 解析失败必须保留可诊断证据, 不得伪造用量)
OPCODE_LITE_SUB_GET_HASH = "c7389bd0e731f80f49593e5ee53835475f4e28594dd6bd83eb229bab753498cd"

# usage 键 -> (统一措辞 label, windowMinutes)
_OPCODE_USAGE_LABELS = {
    "rollingUsage": ("每 5 小时", 300),
    "weeklyUsage": ("每周", 10080),
    "monthlyUsage": ("每月", 43200),
}


def _opcode_parse_seroval(body):
    """解析 SolidStart server function 响应, 提取首个 $R[0] 对象.

    响应形如: ;0x...;((self.$R=self.$R||{})["server-fn:x"]=[],($R=>
    $R[0]={mine:!0,...})($R["server-fn:x"])) — seroval 语法:
    布尔为 !0/!1, 数组为 $R[n]=[...] 前置引用. 只提取我们关心的
    rollingUsage/weeklyUsage/monthlyUsage 字段, 其余忽略.
    解析失败抛 RuntimeError (保留响应前缀作为可诊断证据).
    """
    try:
        import re as _re
        m = _re.search(r'\$R\[0\]=\{', body)
        if not m:
            raise ValueError("缺少 $R[0]")
        seg = body[m.end() - 1:]
        # 截到顶层对象闭合: 从 { 起做花括号深度扫描
        depth = 0
        end = 0
        in_str = False
        for i, ch in enumerate(seg):
            if ch == '"':
                in_str = not in_str
            elif not in_str:
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                    if depth == 0:
                        end = i + 1
                        break
        if end == 0:
            raise ValueError("对象未闭合")
        seg = seg[:end]
        # seroval -> JSON: 裸键加引号, !0/!1 -> false/true,
        # $R[n]=[...] 数组赋值 -> null (忽略), $R[n]={...} 对象赋值就地展开,
        # 其余 $R[n] 引用 -> null 兜底
        seg = seg.replace("!0", "false").replace("!1", "true")
        seg = _re.sub(r'\$R\[\d+\]\s*=\s*\[[^\]]*\]', 'null', seg)
        seg = _re.sub(r'\$R\[\d+\]\s*=\s*\{', '{', seg)
        seg = _re.sub(r'\$R\[\d+\]', 'null', seg)
        seg = _re.sub(r'(?<=\{|,)\s*([A-Za-z_]\w*)\s*:', r'"\1":', seg)
        d = json.loads(seg)
        if not isinstance(d, dict):
            raise ValueError("不是对象")
        return d
    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(
            "OpenCode GO 响应解析失败: %s (响应前缀: %s)"
            % (str(e)[:80], body[:120])
        )


def _opcode_lite_subscription_get(cookie, workspace_id, http_timeout, instance, context=None):
    """调 lite.subscription.get server function, 返回 usage dict.

    GET /_server?id=<hash>&args=["<workspace_id>"] (seroval 单字符串参数),
    必须带 auth cookie 与 X-Server-Id / X-Server-Instance 头.
    """
    import urllib.parse as _urlparse
    import uuid as _uuid
    args = _urlparse.quote(json.dumps([workspace_id], ensure_ascii=False))
    url = "%s?id=%s&args=%s" % (
        OPCODE_SERVER_FN_URL, OPCODE_LITE_SUB_GET_HASH, args
    )
    req = urllib.request.Request(
        url,
        headers={
            "Cookie": "auth=" + cookie,
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36",
            "Accept": "*/*",
            "X-Server-Id": OPCODE_LITE_SUB_GET_HASH,
            "X-Server-Instance": instance or ("server-fn:" + _uuid.uuid4().hex[:8]),
        },
        method="GET",
    )
    try:
        with runtime.urlopen(req, context=context, timeout=http_timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise RuntimeError(
                "OpenCode GO 会话已失效 (HTTP %d), 请重新登录 opencode.ai" % e.code
            )
        raise RuntimeError("OpenCode GO 查询失败 (HTTP %d)" % e.code)
    d = _opcode_parse_seroval(body)
    if not isinstance(d, dict):
        raise RuntimeError("OpenCode GO 响应不是对象")
    return d


def read_opencode_go_credential(home, now_ts, injected=None):
    """App 注入凭证优先; 凭证为 {"auth": <Fe26 cookie>, "workspaceId": "wrk_..."}.

    无凭证返回 None; 格式无效抛可诊断错误.
    """
    if injected is None:
        return None
    if not isinstance(injected, dict):
        raise RuntimeError("OpenCode GO 凭证格式无效")
    cookie = injected.get("auth") or ""
    workspace_id = injected.get("workspaceId") or ""
    if not cookie or not workspace_id:
        raise RuntimeError("OpenCode GO 凭证缺少 auth cookie 或 workspaceId")
    return {"auth": cookie, "workspaceId": workspace_id}


def service_opencode_go(home, now, http_timeout, injected=None, on_refreshed=None, context=None):
    """查询 OpenCode GO 订阅滚动用量 (opencode.ai 网页控制台, workspace 维度).

    返回哪些窗口就输出哪些 (统一语义: 每 5 小时 / 每周 / 每月);
    服务端没有的窗口 (如未订阅的月度窗口) 不输出. 无凭证返回 None.
    """
    cred = read_opencode_go_credential(home, now.timestamp(), injected=injected)
    if cred is None:
        return None
    # 服务端偶发返回 new Response 重定向包装 (会话续期), 重试一次
    d = None
    last_err = None
    for _ in range(2):
        try:
            d = _opcode_lite_subscription_get(
                cred["auth"], cred["workspaceId"], http_timeout, instance=None, context=context
            )
            break
        except RuntimeError as e:
            last_err = e
    if d is None:
        raise last_err or RuntimeError("OpenCode GO 查询失败")

    windows = []
    for key, (label, minutes) in _OPCODE_USAGE_LABELS.items():
        usage = d.get(key)
        if not isinstance(usage, dict) or usage.get("status") != "ok":
            # 未订阅的窗口 (status 非 ok / 缺失) 不输出
            continue
        try:
            used = float(usage.get("usagePercent") or 0)
        except (TypeError, ValueError):
            used = 0.0
        used = max(0.0, min(100.0, used))
        window = {
            "label": label,
            "usedPercent": used,
            "resetsAt": None,
        }
        reset_in = usage.get("resetInSec")
        if isinstance(reset_in, (int, float)):
            window["resetsAt"] = int(now.timestamp() + reset_in)
        if minutes is not None:
            window["windowMinutes"] = minutes
        windows.append(window)

    return {"kind": "windows", "plan": None, "windows": windows}


def service_grok(home, now, http_timeout, injected=None, context=None):
    """查询 Grok 官方订阅额度. 无凭证返回 None, 查询失败抛异常."""
    now_ts = now.timestamp()
    token = read_grok_token(home, now_ts, injected=injected, context=context)
    if not token:
        return None
    # 空 gRPC-web 帧: 1 字节 flags + 4 字节大端长度 0
    req = urllib.request.Request(
        GROK_BILLING_URL,
        data=b"\x00" * 5,
        headers={
            "Authorization": "Bearer " + token,
            "Origin": "https://grok.com",
            "Referer": "https://grok.com/?_s=usage",
            "Accept": "*/*",
            "Content-Type": "application/grpc-web+proto",
            "x-grpc-web": "1",
            "x-user-agent": "connect-es/2.1.1",
            "User-Agent": "mddd-collector",
        },
        method="POST",
    )
    try:
        with runtime.urlopen(req, context=context, timeout=http_timeout) as resp:
            body = resp.read()
            header_status = resp.headers.get("grpc-status") if resp.headers else None
            header_message = resp.headers.get("grpc-message") if resp.headers else ""
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise RuntimeError("Grok 凭证被拒绝 (HTTP %d), 请重新 grok login" % e.code)
        raise RuntimeError("Grok 账单请求失败 (HTTP %d)" % e.code)
    if header_status and header_status != "0":
        try:
            _grok_raise_for_grpc_status(int(header_status), header_message or "")
        except ValueError:
            raise RuntimeError("Grok 账单 RPC 失败 (grpc-status %s)" % header_status)
    trailer = _grpc_web_trailer_fields(body)
    trailer_status = trailer.get("grpc-status")
    if trailer_status and trailer_status != "0":
        try:
            _grok_raise_for_grpc_status(
                int(trailer_status), trailer.get("grpc-message") or ""
            )
        except ValueError:
            raise RuntimeError("Grok 账单 RPC 失败 (grpc-status %s)" % trailer_status)
    percent, reset = parse_billing_payload(body, now_ts)
    return {
        "kind": "windows",
        "plan": None,
        "windows": [
            {
                "label": _grok_tier_label(reset, now_ts),
                "usedPercent": max(0.0, min(100.0, percent)),
                "windowMinutes": _grok_window_minutes(reset, now_ts),
                "resetsAt": reset,
            }
        ],
    }
