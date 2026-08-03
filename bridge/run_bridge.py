#!/usr/bin/env python3
"""Run one collector through the versioned, stdout-clean Bridge v1 protocol."""

import contextlib
import importlib.util
import io
import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


if __package__:
    from .security import (
        ValidationError,
        build_collector_context,
        diagnostic,
        find_sensitive_field,
        validate_credential_challenges,
        validate_credential_updates,
        validate_request,
    )
else:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from bridge.security import (  # noqa: E402
        ValidationError,
        build_collector_context,
        diagnostic,
        find_sensitive_field,
        validate_credential_challenges,
        validate_credential_updates,
        validate_request,
    )


REPO_ROOT = Path(__file__).resolve().parents[1]
COLLECTOR_PATHS = {
    "agent-usage": REPO_ROOT / "agent-usage" / "collector" / "collect_usage.py",
}


class BridgeFault(RuntimeError):
    def __init__(
        self,
        code,
        category,
        stage,
        message,
        retryable=False,
    ):
        super().__init__(message)
        self.code = code
        self.category = category
        self.stage = stage
        self.message = message
        self.retryable = retryable


def _generated_at():
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def _safe_run_id(request):
    if isinstance(request, dict) and isinstance(request.get("runId"), str):
        try:
            return str(uuid.UUID(request["runId"]))
        except (ValueError, AttributeError):
            pass
    return str(uuid.uuid4())


def _error_response(run_id, fault):
    return {
        "schemaVersion": 1,
        "runId": run_id,
        "generatedAt": _generated_at(),
        "status": "error",
        "artifact": None,
        "credentialUpdates": [],
        "credentialChallenges": [],
        "diagnostics": [
            diagnostic(
                fault.code,
                fault.category,
                fault.stage,
                fault.message,
                fault.retryable,
            )
        ],
    }


def _load_collector(module_name):
    path = COLLECTOR_PATHS[module_name]
    spec = importlib.util.spec_from_file_location(
        "mddd_bridge_%s" % module_name.replace("-", "_"),
        path,
    )
    if spec is None or spec.loader is None:
        raise BridgeFault(
            "COLLECTOR_LOAD_FAILED",
            "collector",
            "load",
            "无法加载采集模块",
        )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _default_collector(module_name):
    module = _load_collector(module_name)
    if module_name == "agent-usage":
        return module.run_app
    return module.run


def _partial_diagnostics(module_name, artifact):
    if module_name != "agent-usage":
        return []
    failed = 0
    for section in ("agents", "services"):
        for item in artifact.get(section) or []:
            if item.get("status") in {"error", "partial"}:
                failed += 1
    if not failed:
        return []
    return [
        diagnostic(
            "COLLECTOR_PARTIAL_RESULT",
            "collector",
            "collect",
            "部分数据源采集失败, 已保留可用结果",
            True,
        )
    ]


def execute_request(
    request,
    runtime_overrides=None,
    collector_overrides=None,
):
    run_id = _safe_run_id(request)
    try:
        validate_request(request)
        run_id = request["runId"]
        module_name = request["module"]
        context = build_collector_context(request)
        if runtime_overrides and module_name in runtime_overrides:
            context.update(runtime_overrides[module_name])

        stdout_buffer = io.StringIO()
        stderr_buffer = io.StringIO()
        with contextlib.redirect_stdout(stdout_buffer):
            with contextlib.redirect_stderr(stderr_buffer):
                collector = None
                if collector_overrides:
                    collector = collector_overrides.get(module_name)
                if collector is None:
                    collector = _default_collector(module_name)
                result = collector(context)

        if stdout_buffer.getvalue():
            raise BridgeFault(
                "COLLECTOR_STDOUT_CONTAMINATION",
                "protocol",
                "collect",
                "采集模块向受保护的 stdout 写入了额外内容",
            )
        if not isinstance(result, dict) or not isinstance(
            result.get("artifact"), dict
        ):
            raise BridgeFault(
                "COLLECTOR_INVALID_RESULT",
                "schema",
                "collect",
                "采集模块未返回有效 Artifact",
            )

        artifact = dict(result["artifact"])
        existing_version = artifact.get("schemaVersion", 1)
        existing_module = artifact.get("module", module_name)
        if existing_version != 1 or existing_module != module_name:
            raise BridgeFault(
                "ARTIFACT_METADATA_MISMATCH",
                "schema",
                "validate",
                "Artifact 版本或模块标识不匹配",
            )
        artifact["schemaVersion"] = 1
        artifact["module"] = module_name
        sensitive_location = find_sensitive_field(artifact)
        if sensitive_location:
            raise BridgeFault(
                "ARTIFACT_SENSITIVE_FIELD",
                "security",
                "validate",
                "Artifact 包含不允许的敏感字段",
            )
        updates = validate_credential_updates(
            result.get("credentialUpdates", [])
        )
        challenges = validate_credential_challenges(
            result.get("credentialChallenges", [])
        )
        diagnostics = _partial_diagnostics(module_name, artifact)
        if stderr_buffer.getvalue():
            diagnostics.append(
                diagnostic(
                    "COLLECTOR_STDERR",
                    "collector",
                    "collect",
                    "采集模块产生了已抑制的诊断输出",
                    True,
                )
            )

        return {
            "schemaVersion": 1,
            "runId": run_id,
            "generatedAt": _generated_at(),
            "status": "partial" if diagnostics else "success",
            "artifact": artifact,
            "credentialUpdates": updates,
            "credentialChallenges": challenges,
            "diagnostics": diagnostics,
        }
    except ValidationError as exc:
        return _error_response(
            run_id,
            BridgeFault(
                exc.code,
                exc.category,
                "request",
                exc.message,
            ),
        )
    except BridgeFault as exc:
        return _error_response(run_id, exc)
    except Exception:
        return _error_response(
            run_id,
            BridgeFault(
                "COLLECTOR_FAILED",
                "collector",
                "collect",
                "采集模块执行失败",
                True,
            ),
        )


def main(stdin=None, stdout=None, executor=execute_request):
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    try:
        request = json.loads(stdin.read())
    except (json.JSONDecodeError, UnicodeError):
        response = _error_response(
            str(uuid.uuid4()),
            BridgeFault(
                "BRIDGE_INVALID_JSON",
                "protocol",
                "request",
                "输入不是有效的 JSON 文档",
            ),
        )
    else:
        try:
            response = executor(request)
        except Exception:
            response = _error_response(
                _safe_run_id(request),
                BridgeFault(
                    "BRIDGE_INTERNAL_ERROR",
                    "internal",
                    "bridge",
                    "Bridge 内部执行失败",
                ),
            )
    json.dump(
        response,
        stdout,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
