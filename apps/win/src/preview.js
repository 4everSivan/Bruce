// 托盘悬停实时预览卡 (T12)。C178: 自 preview.html 内联脚本移出 —— 严格 CSP 不放行内联脚本。
const tauri = window.__TAURI__;
let leaveTimer = null;

function invokeTauri(cmd, args) {
  if (tauri && tauri.core && tauri.core.invoke) {
    return tauri.core.invoke(cmd, args);
  }
  return Promise.resolve(null);
}

// 渲染视图模型 (C115): 全部取自后端 `panel.preview` —— 与托盘配额环同一份
// extract_quota_summary 结果, 状态灯与 HUD / 托盘同一判定表 (C100); 缺失值显示「—」。
const TONE_TEXT = { ok: "运行正常", warn: "部分告警", error: "异常断开", neutral: "暂无数据" };
function renderPreview(panel) {
  const preview = panel && panel.preview;
  if (!preview) return;

  // 1. 状态灯
  const statusChip = document.getElementById("statusChip");
  statusChip.className = "status-badge-chip";
  if (preview.statusTone === "warn") statusChip.classList.add("warn");
  if (preview.statusTone === "error") statusChip.classList.add("danger");
  statusChip.title = preview.statusReason || "";
  document.getElementById("statusText").textContent =
    TONE_TEXT[preview.statusTone] || preview.statusReason || "—";

  // 2. 今日费用与 Token
  document.getElementById("kpiCostText").textContent = preview.costText || "—";
  document.getElementById("kpiTokensText").textContent =
    preview.tokensText ? preview.tokensText + " Tokens" : "—";

  // 3. 活跃 Agent (与 HUD「N AGENTS ACTIVE」同口径)
  document.getElementById("activeAgentCountText").textContent = preview.activeAgents + " 活跃";

  // 4. 配额与 42px 环形仪表: 无有效配额窗口时不伪装为 100%
  const hasQuota = typeof preview.remainingPct === "number";
  const remainingPct = hasQuota ? Math.max(0, Math.min(100, Math.round(preview.remainingPct))) : 0;
  document.getElementById("ringPercentText").textContent = hasQuota ? remainingPct + "%" : "—";
  document.getElementById("topProviderName").textContent = preview.topProvider || "暂无订阅额度";
  document.getElementById("topResetCountdown").textContent =
    preview.resetText ? "重置 " + preview.resetText : (preview.topWindowLabel || "—");

  // SVG 周长 2 * PI * 16 = 100.53
  const circumference = 100.53;
  const offset = circumference - (remainingPct / 100) * circumference;
  const ringCircle = document.getElementById("ringCircle");
  ringCircle.style.strokeDashoffset = offset;
  if (!hasQuota) {
    ringCircle.style.stroke = "var(--muted, #8a8a8a)";
  } else if (remainingPct < 15) {
    ringCircle.style.stroke = "var(--danger)";
  } else if (remainingPct < 30) {
    ringCircle.style.stroke = "var(--warn)";
  } else {
    ringCircle.style.stroke = "var(--ok)";
  }

  const stripFill = document.getElementById("stripProgressFill");
  stripFill.style.width = remainingPct + "%";
  stripFill.style.background = ringCircle.style.stroke;
}

// 交互绑定
document.getElementById("expandBtn").addEventListener("click", () => {
  invokeTauri("expand_dashboard");
});
document.getElementById("settingsBtn").addEventListener("click", () => {
  invokeTauri("open_settings");
  invokeTauri("hide_preview_window");
});
document.getElementById("refreshBtn").addEventListener("click", () => {
  invokeTauri("refresh_now");
});
document.getElementById("closeBtn").addEventListener("click", () => {
  invokeTauri("hide_preview_window");
});

window.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    invokeTauri("hide_preview_window");
  }
});

// 鼠标移出预览卡平滑自动收起
const cardEl = document.getElementById("previewCard");
cardEl.addEventListener("mouseleave", () => {
  leaveTimer = setTimeout(() => {
    invokeTauri("hide_preview_window");
  }, 350);
});
cardEl.addEventListener("mouseenter", () => {
  if (leaveTimer) {
    clearTimeout(leaveTimer);
    leaveTimer = null;
  }
});

// 启动与事件监听
invokeTauri("get_dashboard").then(panel => {
  if (panel) renderPreview(panel);
});

if (tauri && tauri.event) {
  tauri.event.listen("dashboard-updated", (event) => {
    renderPreview(event.payload);
  });
}
