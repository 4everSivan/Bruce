// Bruce 模型价格表表现层 (T21, 09-模型价格表远端同步 §4.2 R5) —— 纯函数, 无 DOM 无网络。
// 文案与状态区语义与 mac 侧 BruceAppCore/PricingCatalogSyncPresentation.swift 共享对拍用例
// tests/fixtures/pricing-sync-parity/cases.json。
//
// 时间口径: lastSyncAt 为 RFC3339 带偏移字符串; 「今天」按字符串内民事日期比较 (与宿主时区无关)。

(() => {
  const copy = {
    caption: "模型价格表",
    autoSyncTitle: "自动同步价格表",
    autoSyncSubtitle: "启动 30 秒后静默同步一次, 之后每 24 小时一次; 同步失败不打扰",
    currentCatalogTitle: "当前价格表",
    syncCatalogTitle: "同步价格表",
    syncButton: "同步更新",
    restoreButton: "恢复内置",
    syncingText: "正在从 GitHub 同步模型价格表…",
    failedTitle: "同步失败",
  };

  // RFC3339 民事字段: 直接取字符串内的年月日时分 (含偏移语义自洽, 与宿主时区无关)。
  function civilFromIso(iso) {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(iso || ""));
    if (!m) return null;
    return { y: +m[1], m: +m[2], d: +m[3], hh: m[4], mm: m[5] };
  }

  // 当前本地时间 → 同构民事字段。
  function civilNow(now) {
    if (typeof now === "string") {
      const fromIso = civilFromIso(now);
      if (fromIso) return fromIso;
    }
    const date = now instanceof Date ? now : new Date();
    const pad = (v, w = 2) => String(v).padStart(w, "0");
    return {
      y: date.getFullYear(),
      m: date.getMonth() + 1,
      d: date.getDate(),
      hh: pad(date.getHours()),
      mm: pad(date.getMinutes()),
    };
  }

  // 同日 `今天 HH:mm`, 跨天 `M月d日 HH:mm`。
  function timestamp(iso, now) {
    const at = civilFromIso(iso);
    if (!at) return "";
    const clock = `${at.hh}:${at.mm}`;
    const ref = civilNow(now);
    if (at.y === ref.y && at.m === ref.m && at.d === ref.d) return `今天 ${clock}`;
    return `${at.m}月${at.d}日 ${clock}`;
  }

  function currentCatalogSubtitle(source, modelCount) {
    const count = Number(modelCount) || 0;
    if (source === "builtin") {
      return `内置基线 · ${count} 款模型`;
    }
    return `GitHub 已同步 · ${count} 款模型`;
  }

  function lastSyncSubtitle(lastSyncAt, now) {
    if (!lastSyncAt) return "上次同步 —";
    return `上次同步 ${timestamp(lastSyncAt, now)}`;
  }

  function failureInfo(reason, statusCode) {
    switch (reason) {
      case "timeout":
        return {
          detail: "无法访问 GitHub (超时 10 秒);当前继续使用本地价格表",
          statusLine: "同步价格表失败：网络超时",
        };
      case "offline":
        return {
          detail: "无法访问 GitHub (网络不可用);当前继续使用本地价格表",
          statusLine: "同步价格表失败：网络不可用",
        };
      case "http_error": {
        const code = statusCode || 404;
        return {
          detail: `无法获取价格表 (HTTP ${code});当前继续使用本地价格表`,
          statusLine: `同步价格表失败：HTTP ${code}`,
        };
      }
      case "invalid_catalog":
        return {
          detail: "远端价格表格式无法识别;已拒绝覆盖本地价格表",
          statusLine: "同步价格表失败：价格表格式无效",
        };
      case "stale_version":
        return {
          detail: "远端价格表版本低于本地基线;已保留当前价格表",
          statusLine: "同步价格表失败：远端版本过期",
        };
      default:
        return {
          detail: "同步价格表失败;当前继续使用本地价格表",
          statusLine: "同步价格表失败",
        };
    }
  }

  function stageDisplay(stage) {
    const s = stage || { kind: "idle" };
    switch (s.kind) {
      case "idle":
        return { kind: "hidden", text: null };
      case "syncing":
        return { kind: "spinner", text: copy.syncingText };
      case "upToDate":
        return {
          kind: "confirmation",
          text: `已是最新价格表 · ${s.updatedAt} (${s.modelCount} 款模型)`,
        };
      case "updated": {
        const added = s.addedCount || 0;
        const adjusted = s.adjustedCount || 0;
        let diffStr = "";
        if (added > 0 && adjusted > 0) {
          diffStr = ` (新增 ${added} 款 / 调价 ${adjusted} 款)`;
        } else if (added > 0) {
          diffStr = ` (新增 ${added} 款)`;
        } else if (adjusted > 0) {
          diffStr = ` (调价 ${adjusted} 款)`;
        }
        return {
          kind: "confirmation",
          text: `已更新至 ${s.updatedAt} · 共 ${s.modelCount} 款模型${diffStr}`,
        };
      }
      case "restored":
        return {
          kind: "confirmation",
          text: `已恢复为内置基准价格表 · ${s.updatedAt} (${s.modelCount} 款模型)`,
        };
      case "failed": {
        const info = failureInfo(s.reason, s.statusCode);
        return {
          kind: "failure",
          title: copy.failedTitle,
          detail: info.detail,
          statusLine: info.statusLine,
        };
      }
      default:
        return { kind: "hidden", text: null };
    }
  }

  function isSyncButtonEnabled(stage) {
    return (stage && stage.kind) !== "syncing";
  }

  function isRestoreButtonEnabled(stage) {
    return (stage && stage.kind) !== "syncing";
  }

  const BrucePricingPresentation = {
    copy,
    currentCatalogSubtitle,
    lastSyncSubtitle,
    stageDisplay,
    isSyncButtonEnabled,
    isRestoreButtonEnabled,
    timestamp,
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = BrucePricingPresentation;
  } else if (typeof window !== "undefined") {
    window.BrucePricingPresentation = BrucePricingPresentation;
  }
})();
