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
    "capabilities",
    "codexQuotaRetryOnly",
    "codexQuotaAccountOrder",
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
        "kimiQuotaAccounts",
        "deepseekQuotaAccounts",
        "volcengineQuotaAccounts",
        "antigravityOAuth",
        "antigravityQuotaAccounts",
        "claudeOAuth",
        "claudeQuotaAccounts",
        "grokOAuth",
        "grokQuotaAccounts",
        "opencodeGoQuotaAccounts",
        "codexQuotaAccounts",
        "orcaCodexAuth",
        "providerEnv",
        "providerMeta",
    },
}
RUNTIME_CREDENTIAL_NAMES = {
    "kimiWebTokens": "kimi_web_tokens",
    "kimiQuotaAccounts": "kimi_quota_accounts",
    "deepseekQuotaAccounts": "deepseek_quota_accounts",
    "volcengineQuotaAccounts": "volcengine_quota_accounts",
    "codexQuotaAccounts": "codex_quota_accounts",
    "orcaCodexAuth": "orca_codex_auth",
    "antigravityOAuth": "antigravity_oauth",
    "antigravityQuotaAccounts": "antigravity_quota_accounts",
    "claudeOAuth": "claude_oauth",
    "claudeQuotaAccounts": "claude_quota_accounts",
    "grokOAuth": "grok_oauth",
    "grokQuotaAccounts": "grok_quota_accounts",
    "opencodeGoQuotaAccounts": "opencode_go_quota_accounts",
    "providerEnv": "provider_env",
    "providerMeta": "provider_meta",
}
RUNTIME_CONTEXT_NAMES = {
    "codexQuotaRetryOnly": "codex_quota_retry_only",
    "codexQuotaAccountOrder": "codex_quota_account_order",
}
# 短期 access token 注入的账号条目允许的字段 (白名单, 拒绝 refresh/id token)
CODEX_QUOTA_ACCOUNT_FIELDS = {
    "display_name",
    "access_token",
}
# Codex 账号数量上限 (与 schemas/request-v1.schema.json 一致)
CODEX_QUOTA_ACCOUNT_MAX = 64
# Codex 账号 ID / 展示名 / access token 长度上限
CODEX_QUOTA_ACCOUNT_ID_MAX = 256
CODEX_QUOTA_DISPLAY_NAME_MAX = 256
CODEX_QUOTA_ACCESS_TOKEN_MAX = 8192
# Codex quota challenge 上限, 与 schemas/response-v1.schema.json 保持一致
CREDENTIAL_CHALLENGE_ACCOUNT_ID_MAX = 256
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
UPDATE_PROVIDERS = {"kimi", "antigravity"}


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
    if "codexQuotaRetryOnly" in context and not isinstance(
        context["codexQuotaRetryOnly"], bool
    ):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "codexQuotaRetryOnly 必须是布尔值",
        )
    if "codexQuotaAccountOrder" in context:
        order = context["codexQuotaAccountOrder"]
        if not isinstance(order, list) or not all(
            isinstance(item, str) and item for item in order
        ):
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccountOrder 必须是非空字符串数组",
            )
        if len(order) > CODEX_QUOTA_ACCOUNT_MAX:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccountOrder 超过账号数量上限",
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
        if not isinstance(value, dict):
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "凭证上下文类型无效",
            )
    if "codexQuotaAccounts" in credentials:
        if "codexQuotaAccountOrder" not in context:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts 必须携带 codexQuotaAccountOrder",
            )
        _validate_codex_quota_accounts(
            credentials["codexQuotaAccounts"], context["codexQuotaAccountOrder"]
        )
    elif "codexQuotaAccountOrder" in context:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "codexQuotaAccountOrder 必须携带 codexQuotaAccounts",
        )
    return request


def _validate_codex_quota_accounts(accounts, order=None):
    """Codex 短期 access token 注入: 每账号只允许 display_name + access_token,
    不得携带 refresh token / id token / 完整邮箱等可旋转凭证.
    限制账号数、ID、展示名和 access token 长度.
    校验 order 和账号 map 一一对应且无重复."""
    if not isinstance(accounts, dict):
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "codexQuotaAccounts 必须是 JSON object",
        )
    if len(accounts) > CODEX_QUOTA_ACCOUNT_MAX:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "codexQuotaAccounts 超过账号数量上限",
        )
    if not accounts:
        raise ValidationError(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "codexQuotaAccounts 不能为空",
        )
    for account_id, entry in accounts.items():
        if not isinstance(account_id, str) or not account_id:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts 账号 id 无效",
            )
        if len(account_id) > CODEX_QUOTA_ACCOUNT_ID_MAX:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts 账号 id 超过长度上限",
            )
        if not isinstance(entry, dict) or set(entry) - CODEX_QUOTA_ACCOUNT_FIELDS:
            raise ValidationError(
                "BRIDGE_CREDENTIAL_SCOPE",
                "security",
                "codexQuotaAccounts 账号条目包含不允许的字段",
            )
        access = entry.get("access_token")
        if not isinstance(access, str) or not access:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts 缺少 access_token",
            )
        if len(access) > CODEX_QUOTA_ACCESS_TOKEN_MAX:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts access_token 超过长度上限",
            )
        display_name = entry.get("display_name")
        if display_name is None:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts 缺少 display_name",
            )
        if not isinstance(display_name, str) or not display_name:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts display_name 无效",
            )
        if len(display_name) > CODEX_QUOTA_DISPLAY_NAME_MAX:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccounts display_name 超过长度上限",
            )
    # order 和账号 map 一一对应且无重复
    if order is not None:
        order_set = set(order)
        if len(order_set) != len(order):
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccountOrder 包含重复账号",
            )
        account_keys = set(accounts.keys())
        if order_set != account_keys:
            raise ValidationError(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "codexQuotaAccountOrder 与 codexQuotaAccounts 不一致",
            )


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

# credentialChallenges 字段 (白名单严格, 与 schemas/response-v1.schema.json 一致)
CHALLENGE_FIELDS = {
    "provider",
    "accountId",
    "reason",
}
CHALLENGE_PROVIDERS = {"codex"}
CHALLENGE_REASONS = {"accessRejected"}


def validate_credential_challenges(challenges):
    """校验 collector 返回的 credentialChallenges (严格白名单).

    - 必须是数组; 每条只允许精确字段 provider / accountId / reason.
    - provider 仅允许 codex, reason 仅允许 accessRejected,
      account ID 必须非空且不超过上限.
    校验失败抛 ValidationError (BRIDGE_INVALID_CREDENTIAL_CHALLENGE).
    """
    if not isinstance(challenges, list):
        raise ValidationError(
            "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
            "security",
            "credentialChallenges 必须是数组",
        )
    validated = []
    for challenge in challenges:
        if not isinstance(challenge, dict) or set(challenge) - CHALLENGE_FIELDS:
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "security",
                "credentialChallenge 字段无效",
            )
        missing = CHALLENGE_FIELDS - set(challenge)
        if missing:
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "security",
                "credentialChallenge 缺少必需字段",
            )
        if challenge["provider"] not in CHALLENGE_PROVIDERS:
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "security",
                "credentialChallenge provider 不受支持",
            )
        if challenge["reason"] not in CHALLENGE_REASONS:
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "security",
                "credentialChallenge reason 不受支持",
            )
        account_id = challenge["accountId"]
        if (
            not isinstance(account_id, str)
            or not account_id
            or len(account_id) > CREDENTIAL_CHALLENGE_ACCOUNT_ID_MAX
        ):
            raise ValidationError(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "security",
                "credentialChallenge accountId 无效",
            )
        validated.append(copy.deepcopy(challenge))
    return validated


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
