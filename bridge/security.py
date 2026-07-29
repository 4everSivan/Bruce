"""Credential routing and redaction helpers for Bridge v1."""

import copy
import re
import uuid
from urllib.parse import urlsplit, urlunsplit


REQUEST_FIELDS = {
    "schemaVersion",
    "runId",
    "module",
    "timeouts",
    "context",
    "credentials",
}
CONTEXT_FIELDS = {
    "home",
    "now",
    "timezone",
    "days",
    "paths",
    "baseUrl",
    "username",
    "caFile",
    "ghPath",
    "capabilities",
}
CAPABILITY_VALUES = {
    "localSessions",
    "localPricing",
    "externalQuotas",
}
TIMEOUT_FIELDS = {
    "localScanSeconds",
    "externalRequestSeconds",
    "moduleSeconds",
}
CREDENTIAL_FIELDS_BY_MODULE = {
    "agent-usage": {
        "kimiWebTokens",
        "codexOAuthAccounts",
        "codexAuth",
        "orcaCodexAuth",
        "antigravityOAuth",
        "providerEnv",
        "providerMeta",
    },
    "github": set(),
    "gitlab": {"gitlabToken"},
}
RUNTIME_CREDENTIAL_NAMES = {
    "kimiWebTokens": "kimi_web_tokens",
    "codexOAuthAccounts": "codex_oauth_auth",
    "codexAuth": "codex_auth",
    "orcaCodexAuth": "orca_codex_auth",
    "antigravityOAuth": "antigravity_oauth",
    "providerEnv": "provider_env",
    "providerMeta": "provider_meta",
    "gitlabToken": "gitlab_token",
}
RUNTIME_CONTEXT_NAMES = {
    "baseUrl": "base_url",
    "caFile": "ca_file",
    "ghPath": "gh_path",
}
SENSITIVE_KEY_PARTS = {
    "accesstoken",
    "refreshtoken",
    "idtoken",
    "token",
    "secret",
    "password",
    "authorization",
    "cookie",
    "apikey",
    "privatekey",
    "credential",
}
UPDATE_FIELDS = {
    "provider",
    "accountId",
    "kind",
    "operation",
    "credentials",
}
UPDATE_CREDENTIAL_FIELDS = {
    "access_token",
    "refresh_token",
    "id_token",
    "expiry",
}
UPDATE_PROVIDERS = {"kimi", "codex", "antigravity"}


class ValidationError(ValueError):
    """A protocol or security validation failure safe to expose."""

    def __init__(self, code, category, message):
        super().__init__(message)
        self.code = code
        self.category = category
        self.message = message


def _require_exact_fields(value, required, allowed, label):
    if not isinstance(value, dict):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "%s 必须是 JSON object" % label,
        )
    missing = required - set(value)
    if missing:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "%s 缺少必需字段" % label,
        )
    if set(value) - allowed:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "%s 包含不支持的字段" % label,
        )


def validate_request(request):
    _require_exact_fields(request, REQUEST_FIELDS, REQUEST_FIELDS, "请求")
    if request["schemaVersion"] != 1:
        raise ValidationError(
            "BRIDGE_UNSUPPORTED_SCHEMA",
            "protocol",
            "不支持的 Bridge schema 版本",
        )
    module = request["module"]
    if module not in CREDENTIAL_FIELDS_BY_MODULE:
        raise ValidationError(
            "BRIDGE_UNKNOWN_MODULE",
            "protocol",
            "不支持的采集模块",
        )

    run_id = request["runId"]
    if not isinstance(run_id, str) or not run_id:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "runId 必须是 UUID 字符串",
        )
    try:
        uuid.UUID(run_id)
    except (ValueError, AttributeError):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "runId 必须是有效 UUID",
        )

    _require_exact_fields(
        request["timeouts"],
        TIMEOUT_FIELDS,
        TIMEOUT_FIELDS,
        "timeouts",
    )
    for field in TIMEOUT_FIELDS:
        value = request["timeouts"][field]
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or value <= 0
        ):
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "超时值必须为正数",
            )
    if request["timeouts"]["localScanSeconds"] > 300:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "本地扫描超时超过协议上限",
        )
    if request["timeouts"]["externalRequestSeconds"] > 300:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "外部请求超时超过协议上限",
        )
    if request["timeouts"]["moduleSeconds"] > 600:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "模块超时超过协议上限",
        )

    context = request["context"]
    _require_exact_fields(context, set(), CONTEXT_FIELDS, "context")
    if "days" in context and (
        isinstance(context["days"], bool)
        or not isinstance(context["days"], int)
        or not 1 <= context["days"] <= 366
    ):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "days 必须在 1 到 366 之间",
        )
    if "paths" in context and (
        not isinstance(context["paths"], dict)
        or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in context["paths"].items()
        )
    ):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "paths 必须是字符串映射",
        )
    if "capabilities" in context:
        capabilities = context["capabilities"]
        if not isinstance(capabilities, list) or not all(
            isinstance(item, str) for item in capabilities
        ):
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "capabilities 必须是字符串数组",
            )
        if set(capabilities) - CAPABILITY_VALUES:
            raise ValidationError(
                "BRIDGE_UNKNOWN_CAPABILITY",
                "security",
                "请求包含未知能力",
            )

    credentials = request["credentials"]
    if not isinstance(credentials, dict):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "credentials 必须是 JSON object",
        )
    unsupported = set(credentials) - CREDENTIAL_FIELDS_BY_MODULE[module]
    if unsupported:
        raise ValidationError(
            "BRIDGE_CREDENTIAL_SCOPE",
            "security",
            "请求包含当前模块不需要的凭证",
        )
    for key, value in credentials.items():
        expected_type = str if key == "gitlabToken" else dict
        if not isinstance(value, expected_type):
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "凭证上下文类型无效",
            )
    return request


def build_collector_context(request):
    context = {}
    for key, value in request["context"].items():
        context[RUNTIME_CONTEXT_NAMES.get(key, key)] = copy.deepcopy(value)
    # 缺失能力默认 deny: Bridge 总是携带显式能力列表
    context["capabilities"] = list(context.get("capabilities") or [])
    context["credentials"] = {
        RUNTIME_CREDENTIAL_NAMES[key]: copy.deepcopy(value)
        for key, value in request["credentials"].items()
    }
    external_timeout = float(
        request["timeouts"]["externalRequestSeconds"]
    )
    context["http_timeout"] = external_timeout
    context["request_timeout"] = external_timeout
    context["app_mode"] = True
    return context


def _normalized_key(key):
    return re.sub(r"[^a-z0-9]", "", str(key).lower())


def find_sensitive_field(value, location="artifact"):
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = _normalized_key(key)
            if any(part in normalized for part in SENSITIVE_KEY_PARTS):
                return "%s.%s" % (location, key)
            found = find_sensitive_field(child, "%s.%s" % (location, key))
            if found:
                return found
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found = find_sensitive_field(
                child,
                "%s[%d]" % (location, index),
            )
            if found:
                return found
    return None


def validate_credential_updates(updates):
    if not isinstance(updates, list):
        raise ValidationError(
            "BRIDGE_INVALID_CREDENTIAL_UPDATE",
            "security",
            "credentialUpdates 必须是数组",
        )
    validated = []
    for update in updates:
        _require_exact_fields(
            update,
            UPDATE_FIELDS,
            UPDATE_FIELDS,
            "credentialUpdate",
        )
        if update["provider"] not in UPDATE_PROVIDERS:
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "security",
                "credentialUpdate provider 不受支持",
            )
        if (
            not isinstance(update["accountId"], str)
            or not update["accountId"]
            or len(update["accountId"]) > 256
            or update["kind"] != "oauthTokens"
            or update["operation"] != "replace"
        ):
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "security",
                "credentialUpdate 元数据无效",
            )
        values = update["credentials"]
        if (
            not isinstance(values, dict)
            or not values
            or set(values) - UPDATE_CREDENTIAL_FIELDS
            or not all(isinstance(value, str) for value in values.values())
        ):
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "security",
                "credentialUpdate 凭证字段无效",
            )
        validated.append(copy.deepcopy(update))
    return validated


_BEARER_RE = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+")
_ASSIGNMENT_RE = re.compile(
    r"(?i)\b(token|secret|password|api[_-]?key|authorization)"
    r"\s*[:=]\s*[^\s,;]+"
)
_EMAIL_RE = re.compile(
    r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"
)
_HOME_PATH_RE = re.compile(r"/Users/[^/\s]+(?:/[^\s]*)?")
_URL_RE = re.compile(r"https?://[^\s]+")


def _redact_url(match):
    raw = match.group(0)
    try:
        parts = urlsplit(raw)
        if not parts.query and not parts.fragment:
            return raw
        return urlunsplit(
            (parts.scheme, parts.netloc, parts.path, "[REDACTED]", "")
        )
    except ValueError:
        return "[REDACTED_URL]"


def redact_text(value):
    text = str(value).replace("\r", " ").replace("\n", " ")
    text = _BEARER_RE.sub("Bearer [REDACTED]", text)
    text = _ASSIGNMENT_RE.sub(
        lambda match: "%s=[REDACTED]" % match.group(1),
        text,
    )
    text = _EMAIL_RE.sub("[REDACTED_EMAIL]", text)
    text = _HOME_PATH_RE.sub("[REDACTED_PATH]", text)
    text = _URL_RE.sub(_redact_url, text)
    return text[:300]


def diagnostic(code, category, stage, message, retryable=False):
    return {
        "code": code,
        "category": category,
        "stage": stage,
        "message": redact_text(message),
        "retryable": bool(retryable),
    }
