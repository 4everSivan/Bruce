from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_CORE = (
    REPO_ROOT / "macos" / "BruceApp" / "Sources" / "BruceAppCore"
)
ONBOARDING_CORE = (
    REPO_ROOT / "macos" / "BruceApp" / "Sources" / "BruceOnboardingCore"
)


def test_collector_subprocess_uses_an_environment_allowlist():
    source = (APP_CORE / "CollectorRunner.swift").read_text()
    launch_start = source.index("process.executableURL = executableURL")
    launch_end = source.index("process.standardInput = stdinPipe")
    launch = source[launch_start:launch_end]
    assert "process.environment = [" in launch
    assert '"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"' in launch
    assert '"LANG": "en_US.UTF-8"' in launch
    assert '"LC_ALL": "en_US.UTF-8"' in launch
    assert '"TMPDIR": FileManager.default.temporaryDirectory.path' in launch
    assert "ProcessInfo.processInfo.environment" not in launch


def test_diagnostics_model_never_declares_business_or_identity_fields():
    source = (APP_CORE / "Diagnostics.swift").read_text()
    report_start = source.index("private struct DiagnosticApplication")
    report_end = source.index("package enum DiagnosticExportError")
    report_models = source[report_start:report_end].lower()
    for forbidden in (
        "artifact",
        "credential",
        "token",
        "email",
        "repository",
        "hostname",
        "baseurl",
        "filepath",
    ):
        assert forbidden not in report_models


def test_diagnostics_archive_is_reexpanded_and_allowlisted_before_publish():
    source = (APP_CORE / "Diagnostics.swift").read_text()
    assert "try archiver.expand(" in source
    assert "try validateExpandedArchive(at: verificationURL)" in source
    assert '"Bruce-diagnostics/README.txt"' in source
    assert '"Bruce-diagnostics/report.json"' in source
    assert "isSymbolicLink" in source


APP_LAYER = REPO_ROOT / "macos" / "BruceApp" / "Sources" / "BruceApp"
SETTINGS_DIR = APP_LAYER / "Settings"
CODEX_SETTINGS = SETTINGS_DIR / "CodexProviderSettingsSection.swift"


def _settings_layer_source() -> str:
    """SettingsView + Settings/ 下全部 section (Task 10 文件拆分后契约扫描面)."""
    parts = [(APP_LAYER / "SettingsView.swift").read_text()]
    if SETTINGS_DIR.is_dir():
        for path in sorted(SETTINGS_DIR.glob("*.swift")):
            parts.append(path.read_text())
    return "\n".join(parts)


def test_settings_codex_actions_use_discovery_not_import():
    """任务 10 契约: Codex 入口只使用「发现」语义, 不暗示 token 导入."""
    settings = _settings_layer_source()
    assert "发现 CC Switch 账号" in settings
    assert "发现本机 CLI 账号" in settings
    assert "从 CC Switch 导入账号库" not in settings
    assert "从本机导入当前账号" not in settings
    # 确认文案明确说明不导入、不保存、不使用 CC Switch token
    assert "不导入、不保存、不使用 CC Switch 持有的 Codex 登录令牌" in settings


def test_settings_codex_status_distinguishes_authorization_states():
    """任务 10 契约: 设置页可区分 connected / needsReauthorization / revoked,
    needsReauthorization 提供「在 Bruce 中重新授权」操作."""
    settings = _settings_layer_source()
    assert "case .connected:" in settings
    assert "case .needsReauthorization:" in settings
    assert "case .revoked:" in settings
    assert '"需要重新授权"' in settings
    assert 'Button("重新授权")' in settings
    assert "accountStatusLabel" in settings
    # 状态列表不携带 token 或完整账号 ID 的渲染路径
    assert "codexAccountStatuses" in settings


def test_settings_codex_ui_never_renders_sensitive_values():
    """任务 10 契约: Codex 管理区 UI 不得把 token 或完整账号 ID 渲染进文本."""
    group_source = CODEX_SETTINGS.read_text()
    for forbidden in ("access_token", "refresh_token", "id_token"):
        assert forbidden not in group_source
    # 账号行只展示脱敏账号名与状态; 状态列表用 accountID 仅作稳定 id, 不进文本
    assert "Text(status.displayName)" in group_source
    assert "Text(status.accountID)" not in group_source


def test_subscription_card_marks_stale_codex_data():
    """任务 10 契约: 额度卡对非 ok 的 Codex 账号显示上次成功时间文案."""
    card = (
        APP_LAYER / "Views" / "SubscriptionCard.swift"
    ).read_text()
    assert "lastSuccessText" in card
    assert "Text(lastSuccessText)" in card
    assert "上次成功的数据" in card
    # 复用现有玻璃卡片结构 (Color.adaptive 深浅色), 不新增自定义材质
    assert "Color.adaptive" in card


def test_panel_mapper_exposes_last_success_time_for_codex_errors():
    """任务 9 契约: Panel 映射层为 stale Codex 账号提供上次成功时间.
    lastSuccessText 只在 freshness == stale 且 capturedAt 存在时生成.
    S5a 后实现落在 SubscriptionMapping (PanelViewModel 仅保留入口)."""
    mapping = (APP_CORE / "SubscriptionMapping.swift").read_text()
    assert "lastSuccessText" in mapping
    assert '"上次成功 "' in mapping
    assert "service.capturedAt" in mapping
    assert 'service.freshness == "stale"' in mapping


def test_codex_configured_flag_requires_complete_record():
    """任务 9 契约: Codex"已配置"按真实完整 record 判定 (fail-closed),
    发现导入的 metadata-only 账号不算已配置, 索引状态不作数."""
    store = (ONBOARDING_CORE / "CodexCredentialStore.swift").read_text()
    assert "hasConfiguredCredentials" in store
    assert "resolvedAuthorizationState" in store
    assert '== .connected' in store


def test_coordinator_uses_hasConfiguredCredentials_for_codex():
    """任务 9 契约: SubscriptionService (Coordinator 门面后的实现体) 的 Codex
    "已配置"与发现导入收尾都走 hasConfiguredCredentials, 不再以索引 connected
    代判或无条件标 true."""
    service = (
        REPO_ROOT / "macos" / "BruceApp" / "Sources" / "BruceApp"
        / "SubscriptionService.swift"
    ).read_text()
    assert "hasConfiguredCredentials()" in service
    # 发现导入收尾不再无条件标"已配置"
    assert "finishCodexDiscoveryImport" in service
    assert 'setSubscriptionCredentialConfigured(true, for: .codex)' not in service
