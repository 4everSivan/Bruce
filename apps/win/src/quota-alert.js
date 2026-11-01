// 订阅额度预警气泡 (C159)。C178: 自 quota-alert.html 内联脚本移出 —— 严格 CSP 不放行内联脚本
// 与内联事件属性; 告警字段写入 innerHTML 前一律转义。
const tauri = window.__TAURI__;
let alertsData = [];
let countdownInterval = null;
let dismissTimeout = null;
let isHovering = false;

function invokeTauri(cmd, args = {}) {
  if (tauri && tauri.core && typeof tauri.core.invoke === "function") {
    return tauri.core.invoke(cmd, args);
  }
  return Promise.resolve();
}

/** 写入 innerHTML 的告警字段 (服务名 / 窗口标签 / 重置文案) 来自采集结果, 一律转义。 */
function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
  })[ch]);
}

function getTierColor(tier) {
  if (tier >= 95) return "var(--tier-danger)";
  if (tier >= 80) return "var(--tier-warn)";
  return "var(--tier-notice)";
}

function formatCountdown(resetsAt, resetText) {
  if (!resetsAt) return resetText || "";
  const target = new Date(resetsAt).getTime();
  const now = Date.now();
  const diffSecs = Math.max(0, Math.floor((target - now) / 1000));
  if (diffSecs <= 0) return "00:00:00";
  const h = Math.floor(diffSecs / 3600);
  const m = Math.floor((diffSecs % 3600) / 60);
  const s = diffSecs % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function formatWindow(label) {
  if (!label) return "每5小时";
  const s = String(label).trim();
  if (s.includes("5") && (s.includes("小时") || s.includes("h"))) return "每5小时";
  if (s.includes("周") || s.includes("week")) return "每周";
  if (s.includes("月") || s.includes("month")) return "每月";
  if (s.includes("天") || s.includes("日") || s.includes("day")) return "每日";
  return s.replace(/\s+/g, "");
}

function renderAlerts(alerts) {
  alertsData = alerts || [];
  const container = document.getElementById("alertsContainer");
  container.innerHTML = "";

  alertsData.forEach(alert => {
    const row = document.createElement("div");
    row.className = "alert-row";

    const tierColor = getTierColor(alert.tier || 80);
    const usedPct = Math.round(alert.usedPercent || 0);
    const countdown = formatCountdown(alert.resetsAt, alert.resetText);

    let iconSvg = "";
    if (window.ProviderBrand && window.ProviderBrand.getGlyph) {
      iconSvg = window.ProviderBrand.getGlyph(alert.providerId || alert.serviceId, 16);
    }
    if (!iconSvg) {
      iconSvg = `<span style="font-size:10px;font-weight:700;">${escapeHtml((alert.serviceName || "A")[0])}</span>`;
    }

    const isNothing = document.body.classList.contains("theme-nothing");
    let progressHtml = "";
    if (isNothing) {
      const segs = [];
      for (let i = 0; i < 14; i++) {
        const threshold = (i + 1) / 14 * 100;
        const filled = (usedPct >= threshold) || (i === 0 && usedPct > 0);
        segs.push(`<div class="nothing-seg ${filled ? 'should-fill' : ''}" data-fill-color="${tierColor}"></div>`);
      }
      progressHtml = `<div class="progress-track segmented">${segs.join("")}</div>`;
    } else {
      progressHtml = `
        <div class="progress-track">
          <div class="progress-fill" style="width: 0%; background: ${tierColor}; transition: width 0.85s cubic-bezier(0.33, 0, 0.2, 1);" data-target-width="${Math.min(100, usedPct)}"></div>
        </div>`;
    }

    row.innerHTML = `
      <div class="badge-icon">${iconSvg}</div>
      <div class="info-col">
        <div class="info-top">
          <span class="service-title">${escapeHtml(alert.serviceName || alert.serviceId)}</span>
          <div class="right-time-group">
            <span class="window-chip">${escapeHtml(formatWindow(alert.windowLabel))}</span>
            ${countdown ? `<span class="countdown-timer" style="color: ${tierColor};" data-resets-at="${escapeHtml(alert.resetsAt)}" data-reset-text="${escapeHtml(alert.resetText)}">${escapeHtml(countdown)}</span>` : ""}
          </div>
        </div>
        <div class="info-bottom">
          ${progressHtml}
          <span class="percent-val" style="color: ${tierColor};">${usedPct}%</span>
        </div>
      </div>
      <button class="close-btn" title="关闭">✕</button>
    `;
    container.appendChild(row);
  });

  // 气泡展示动画: 进度条从 0 平滑增长至目标用量
  requestAnimationFrame(() => {
    setTimeout(() => {
      document.querySelectorAll(".progress-fill").forEach(el => {
        el.style.width = el.getAttribute("data-target-width") + "%";
      });
      document.querySelectorAll(".nothing-seg.should-fill").forEach((el, idx) => {
        setTimeout(() => {
          el.style.background = el.getAttribute("data-fill-color");
          el.classList.add("filled");
        }, idx * 40);
      });
    }, 30);
  });

  startCountdownTimer();
  scheduleAutoDismiss(6000);
}

function startCountdownTimer() {
  if (countdownInterval) clearInterval(countdownInterval);
  countdownInterval = setInterval(() => {
    const timers = document.querySelectorAll(".countdown-timer");
    timers.forEach(el => {
      const resetsAt = el.getAttribute("data-resets-at");
      const resetText = el.getAttribute("data-reset-text");
      el.textContent = formatCountdown(resetsAt, resetText);
    });
  }, 1000);
}

function scheduleAutoDismiss(ms) {
  if (dismissTimeout) clearTimeout(dismissTimeout);
  dismissTimeout = setTimeout(() => {
    if (!isHovering) {
      window.closeAlert();
    }
  }, ms);
}

window.closeAlert = function() {
  if (countdownInterval) {
    clearInterval(countdownInterval);
    countdownInterval = null;
  }
  if (dismissTimeout) {
    clearTimeout(dismissTimeout);
    dismissTimeout = null;
  }
  const card = document.getElementById("quotaCard");
  card.style.opacity = "0";
  setTimeout(() => {
    invokeTauri("hide_quota_alert_window");
    card.style.opacity = "1";
  }, 250);
};

const card = document.getElementById("quotaCard");
card.addEventListener("mouseenter", () => {
  isHovering = true;
  if (dismissTimeout) clearTimeout(dismissTimeout);
});

card.addEventListener("mouseleave", () => {
  isHovering = false;
  scheduleAutoDismiss(3000);
});

card.addEventListener("click", (e) => {
  // 关闭按钮只收起气泡 (原内联 onclick, C178 改为委托), 卡片主体收起并唤出主看板。
  if (e.target.closest(".close-btn")) {
    window.closeAlert();
    return;
  }
  window.closeAlert();
  invokeTauri("show_dashboard_from_alert");
});

if (tauri && tauri.event) {
  tauri.event.listen("quota-alert-data", (e) => {
    if (e.payload) {
      const payload = e.payload;
      const alerts = Array.isArray(payload) ? payload : (payload.alerts || []);
      const theme = Array.isArray(payload) ? "fluent" : (payload.theme || "fluent");
      document.body.classList.toggle("theme-nothing", theme === "nothing");
      renderAlerts(alerts);
    }
  });
}
