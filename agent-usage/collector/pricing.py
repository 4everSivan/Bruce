"""内置价目表与成本估算 (阶段 D: 从 collect_usage.py 拆出).

内置价目优先; CC Switch 的 model_pricing 只补充内置表没有的新模型.
纯逻辑, 不依赖 runtime 状态.
"""

import os
import sqlite3

# 内置价目表（2026-07 快照，来自各厂商公开定价；usd / 1M tokens：
# input, output, cache_read, cache_creation）。成本估算不再依赖 CC Switch，
# 仅当遇到内置表没有的新模型时才回落读取 CC 的 model_pricing 作为补充。
BUILTIN_PRICING = {
    "claude-3-5-haiku-20241022": (0.80, 4, 0.08, 1),
    "claude-3-5-sonnet-20241022": (3, 15, 0.30, 3.75),
    "claude-fable-5": (10, 50, 1.00, 12.50),
    "claude-haiku-4-5-20251001": (1, 5, 0.10, 1.25),
    "claude-mythos-5": (10, 50, 1.00, 12.50),
    "claude-opus-4-1-20250805": (15, 75, 1.50, 18.75),
    "claude-opus-4-20250514": (15, 75, 1.50, 18.75),
    "claude-opus-4-5-20251101": (5, 25, 0.50, 6.25),
    "claude-opus-4-6-20260206": (5, 25, 0.50, 6.25),
    "claude-opus-4-7": (5, 25, 0.50, 6.25),
    "claude-opus-4-8": (5, 25, 0.50, 6.25),
    "claude-sonnet-4-20250514": (3, 15, 0.30, 3.75),
    "claude-sonnet-4-5-20250929": (3, 15, 0.30, 3.75),
    "claude-sonnet-4-6-20260217": (3, 15, 0.30, 3.75),
    "claude-sonnet-5": (3, 15, 0.30, 3.75),
    "codestral-2508": (0.30, 0.90, 0.03, 0),
    "codex-mini": (0.75, 3, 0.025, 0),
    "command-a": (2.50, 10, 0, 0),
    "command-r": (0.15, 0.60, 0, 0),
    "command-r-plus": (2.50, 10, 0, 0),
    "deepseek-chat": (0.27, 1.10, 0.07, 0),
    "deepseek-reasoner": (0.55, 2.19, 0.14, 0),
    "deepseek-v3": (0.28, 1.11, 0.028, 0),
    "deepseek-v3.1": (0.55, 1.67, 0.055, 0),
    "deepseek-v3.2": (0.28, 0.42, 0.028, 0),
    "deepseek-v4-flash": (0.14, 0.28, 0.0028, 0),
    "deepseek-v4-pro": (0.435, 0.87, 0.003625, 0),
    "devstral-2-2512": (0.40, 2, 0.04, 0),
    "devstral-medium": (0.40, 2, 0.04, 0),
    "devstral-small-1.1": (0.07, 0.28, 0.01, 0),
    "devstral-small-2-2512": (0.10, 0.30, 0.01, 0),
    "doubao-seed-2-0-code": (0.47, 2.37, 0.09, 0),
    "doubao-seed-2-0-code-preview-latest": (0.47, 2.37, 0.09, 0),
    "doubao-seed-2-0-lite": (0.08, 0.50, 0.017, 0),
    "doubao-seed-2-0-mini": (0.03, 0.31, 0.0056, 0),
    "doubao-seed-2-0-pro": (0.47, 2.37, 0.09, 0),
    "doubao-seed-2-1-pro": (0.84, 4.2, 0.17, 0),
    "doubao-seed-2-1-turbo": (0.42, 2.1, 0.08, 0),
    "doubao-seed-code": (0.17, 1.11, 0.02, 0),
    "gemini-2.0-flash": (0.10, 0.40, 0.025, 0),
    "gemini-2.5-flash": (0.3, 2.5, 0.03, 0),
    "gemini-2.5-flash-lite": (0.10, 0.40, 0.01, 0),
    "gemini-2.5-pro": (1.25, 10, 0.125, 0),
    "gemini-3-flash-preview": (0.5, 3, 0.05, 0),
    "gemini-3-pro-preview": (2, 12, 0.2, 0),
    "gemini-3.1-flash-lite": (0.25, 1.50, 0.025, 0),
    "gemini-3.1-flash-lite-preview": (0.25, 1.50, 0.025, 0),
    "gemini-3.1-pro-preview": (2, 12, 0.20, 0),
    "gemini-3.5-flash": (1.50, 9.00, 0.15, 0),
    "glm-4.6": (0.6, 2.2, 0.11, 0),
    "glm-4.7": (0.6, 2.2, 0.11, 0),
    "glm-5": (1, 3.2, 0.2, 0),
    "glm-5.1": (1.4, 4.4, 0.26, 0),
    "glm-5.2": (1.4, 4.4, 0.26, 0),
    "gpt-4.1": (2, 8, 0.50, 0),
    "gpt-4.1-mini": (0.40, 1.60, 0.10, 0),
    "gpt-4.1-nano": (0.10, 0.40, 0.025, 0),
    "gpt-5": (1.25, 10, 0.125, 0),
    "gpt-5-codex": (1.25, 10, 0.125, 0),
    "gpt-5-codex-high": (1.25, 10, 0.125, 0),
    "gpt-5-codex-low": (1.25, 10, 0.125, 0),
    "gpt-5-codex-medium": (1.25, 10, 0.125, 0),
    "gpt-5-codex-mini": (1.25, 10, 0.125, 0),
    "gpt-5-codex-mini-high": (1.25, 10, 0.125, 0),
    "gpt-5-codex-mini-medium": (1.25, 10, 0.125, 0),
    "gpt-5-high": (1.25, 10, 0.125, 0),
    "gpt-5-low": (1.25, 10, 0.125, 0),
    "gpt-5-medium": (1.25, 10, 0.125, 0),
    "gpt-5-mini": (0.25, 2, 0.025, 0),
    "gpt-5-minimal": (1.25, 10, 0.125, 0),
    "gpt-5-nano": (0.05, 0.40, 0.005, 0),
    "gpt-5.1": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-max": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-max-high": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-max-xhigh": (1.25, 10, 0.125, 0),
    "gpt-5.1-codex-mini": (1.25, 10, 0.125, 0),
    "gpt-5.1-high": (1.25, 10, 0.125, 0),
    "gpt-5.1-low": (1.25, 10, 0.125, 0),
    "gpt-5.1-medium": (1.25, 10, 0.125, 0),
    "gpt-5.1-minimal": (1.25, 10, 0.125, 0),
    "gpt-5.2": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-high": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-low": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-medium": (1.75, 14, 0.175, 0),
    "gpt-5.2-codex-xhigh": (1.75, 14, 0.175, 0),
    "gpt-5.2-high": (1.75, 14, 0.175, 0),
    "gpt-5.2-low": (1.75, 14, 0.175, 0),
    "gpt-5.2-medium": (1.75, 14, 0.175, 0),
    "gpt-5.2-xhigh": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-high": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-low": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-medium": (1.75, 14, 0.175, 0),
    "gpt-5.3-codex-xhigh": (1.75, 14, 0.175, 0),
    "gpt-5.4": (2.50, 15, 0.25, 0),
    "gpt-5.4-mini": (0.75, 4.50, 0.075, 0),
    "gpt-5.4-nano": (0.20, 1.25, 0.02, 0),
    "gpt-5.5": (5, 30, 0.50, 0),
    "gpt-5.5-high": (5, 30, 0.50, 0),
    "gpt-5.5-low": (5, 30, 0.50, 0),
    "gpt-5.5-medium": (5, 30, 0.50, 0),
    "gpt-5.5-minimal": (5, 30, 0.50, 0),
    "gpt-5.5-xhigh": (5, 30, 0.50, 0),
    "gpt-5.6": (5, 30, 0.50, 6.25),
    "gpt-5.6-high": (5, 30, 0.50, 6.25),
    "gpt-5.6-low": (5, 30, 0.50, 6.25),
    "gpt-5.6-luna": (1, 6, 0.10, 1.25),
    "gpt-5.6-medium": (5, 30, 0.50, 6.25),
    "gpt-5.6-minimal": (5, 30, 0.50, 6.25),
    "gpt-5.6-sol": (5, 30, 0.50, 6.25),
    "gpt-5.6-terra": (2.50, 15, 0.25, 3.125),
    "gpt-5.6-xhigh": (5, 30, 0.50, 6.25),
    "grok-3": (3, 15, 0.75, 0),
    "grok-3-mini": (0.25, 0.50, 0.075, 0),
    "grok-4": (3, 15, 0.75, 0),
    "grok-4-1-fast-non-reasoning": (0.20, 0.50, 0.05, 0),
    "grok-4-1-fast-reasoning": (0.20, 0.50, 0.05, 0),
    "grok-4.20-0309-non-reasoning": (1.25, 2.50, 0.20, 0),
    "grok-4.20-0309-reasoning": (1.25, 2.50, 0.20, 0),
    "grok-4.3": (1.25, 2.50, 0.20, 0),
    "grok-build-0.1": (1, 2, 0.20, 0),
    "grok-code-fast-1": (1, 2, 0.20, 0),
    "hunyuan-hy3": (0.14, 0.56, 0.035, 0),
    "hy3": (0.14, 0.56, 0.035, 0),
    "kimi-k2-0905": (0.55, 2.20, 0.10, 0),
    "kimi-k2-thinking": (0.55, 2.20, 0.10, 0),
    "kimi-k2-turbo": (1.11, 8.06, 0.14, 0),
    "kimi-k2.5": (0.60, 3.00, 0.10, 0),
    "kimi-k2.6": (0.95, 4.00, 0.16, 0),
    "kimi-k2.7-code": (0.95, 4.00, 0.19, 0),
    "magistral-medium": (2, 5, 0, 0),
    "magistral-small": (0.50, 1.50, 0, 0),
    "mimo-v2-flash": (0.09, 0.29, 0.009, 0),
    "mimo-v2-pro": (0.435, 0.87, 0.0036, 0),
    "mimo-v2.5": (0.14, 0.29, 0.0028, 0),
    "mimo-v2.5-pro": (0.435, 0.87, 0.0036, 0),
    "minimax-m2": (0.27, 0.95, 0.03, 0),
    "minimax-m2.1": (0.27, 0.95, 0.03, 0),
    "minimax-m2.1-lightning": (0.27, 2.33, 0.03, 0),
    "minimax-m2.5": (0.15, 0.95, 0.03, 0),
    "minimax-m2.5-lightning": (0.30, 2.40, 0.03, 0),
    "minimax-m2.7": (0.30, 1.20, 0.06, 0.375),
    "minimax-m2.7-highspeed": (0.60, 2.40, 0.06, 0.375),
    "minimax-m3": (0.60, 2.40, 0.12, 0),
    "mistral-large-3-2512": (0.50, 1.50, 0.05, 0),
    "mistral-medium-3.1": (0.40, 2, 0.04, 0),
    "mistral-medium-3.5": (1.50, 7.50, 0, 0),
    "mistral-small-3.2-24b": (0.075, 0.20, 0.01, 0),
    "mistral-small-4": (0.10, 0.30, 0.01, 0),
    "o1": (15, 60, 7.50, 0),
    "o1-mini": (0.55, 2.20, 0.55, 0),
    "o3": (2, 8, 0.50, 0),
    "o3-mini": (0.55, 2.20, 0.55, 0),
    "o3-pro": (20, 80, 0, 0),
    "o4-mini": (1.10, 4.40, 0.275, 0),
    "qwen3-235b-a22b": (0.70, 8.40, 0, 0),
    "qwen3-32b": (0.16, 0.64, 0, 0),
    "qwen3-coder-480b": (0.65, 3.25, 0, 0),
    "qwen3-coder-480b-a35b-instruct": (0.65, 3.25, 0, 0),
    "qwen3-coder-flash": (0.195, 0.975, 0.039, 0),
    "qwen3-coder-next": (0.12, 0.75, 0, 0),
    "qwen3-coder-plus": (0.65, 3.25, 0.13, 0),
    "qwen3-max": (0.78, 3.90, 0, 0),
    "qwen3.5-plus": (0.26, 1.56, 0.052, 0),
    "qwen3.6-plus": (0.325, 1.95, 0.065, 0),
    "qwen3.7-max": (2.50, 7.50, 0.25, 0),
    "qwen3.7-plus": (0.40, 1.60, 0.08, 0),
    "qwq-32b": (0.20, 0.60, 0, 0),
    "qwq-plus": (0.80, 2.40, 0, 0),
    "step-3.5-flash": (0.10, 0.30, 0.02, 0),
    "step-3.5-flash-2603": (0.10, 0.30, 0.02, 0),
    "step-3.7-flash": (0.19, 1.13, 0.04, 0),
}


def load_pricing(cc_switch_db):
    """内置价目优先；CC Switch 的 model_pricing 只补充内置表没有的新模型。"""
    pricing = dict(BUILTIN_PRICING)
    if not os.path.exists(cc_switch_db):
        return pricing
    try:
        with sqlite3.connect("file:%s?mode=ro" % cc_switch_db, uri=True) as db:
            rows = db.execute(
                "SELECT model_id, input_cost_per_million, output_cost_per_million,"
                " cache_read_cost_per_million, cache_creation_cost_per_million"
                " FROM model_pricing"
            ).fetchall()
        for mid, ci, co, cr, cc in rows:
            mid = (mid or "").lower()
            if not mid or mid in pricing:
                continue
            try:
                pricing[mid] = (float(ci), float(co), float(cr), float(cc))
            except (TypeError, ValueError):
                continue
    except Exception:
        pass
    return pricing


def estimate_cost(model, bucket, pricing):
    if not pricing or not model:
        return None
    key = model.lower().split("[")[0].split("/")[-1].strip()
    prices = pricing.get(model.lower()) or pricing.get(key)
    if prices is None:
        for pid, p in pricing.items():
            if key and (key in pid or pid in key):
                prices = p
                break
    if prices is None:
        return None
    ci, co, cr, cc = prices
    return (
        bucket["input"] * ci
        + bucket["output"] * co
        + bucket["cacheRead"] * cr
        + bucket["cacheCreation"] * cc
    ) / 1e6
