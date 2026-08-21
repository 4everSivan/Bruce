# Shared runtime manifest for Preview and Release App bundles.
# The caller supplies the repository root and destination Resources/runtime.

MDDD_RUNTIME_FILES=(
    bridge/__init__.py
    bridge/run_bridge.py
    bridge/security.py
    bridge/schemas
    agent-usage/collector/collect_usage.py
    agent-usage/collector/pricing.py
    agent-usage/collector/runtime.py
    agent-usage/collector/quota_services.py
    agent-usage/collector/local_usage.py
    agent-usage/collector/codex_compat.py
    agent-usage/collector/quota_official.py
    agent-usage/collector/service_catalog.py
)

MDDD_BUNDLE_FILES=(
    "${MDDD_RUNTIME_FILES[@]}"
    macos/MdddApp/Assets/AppIcon.icns
)

mddd_validate_packaging_sources() {
    local repo_root="$1"
    local relative_path
    for relative_path in "${MDDD_BUNDLE_FILES[@]}"; do
        if [[ ! -e "$repo_root/$relative_path" ]]; then
            echo "缺少打包资源: $repo_root/$relative_path" >&2
            return 1
        fi
    done
}

mddd_copy_runtime() {
    local repo_root="$1"
    local runtime_root="$2"
    local relative_path

    mkdir -p "$runtime_root/bridge" "$runtime_root/agent-usage/collector"
    for relative_path in "${MDDD_RUNTIME_FILES[@]}"; do
        ditto "$repo_root/$relative_path" "$runtime_root/$relative_path"
    done
}
