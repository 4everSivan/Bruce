(function () {
  "use strict";

  // DaimonWidget 宿主导入: 视觉 harness 专用的状态层模拟,
  // 迁移自已拆除的 App 内嵌 WKWebView 资源, 仅保留 Daimon 场景
  // 需要的数据/状态契约和文字状态覆盖层.
  var dataCallbacks = [];
  var statusCallbacks = [];
  var themeCallbacks = [];
  var host = window.DaimonWidget || {};
  host.data = host.data || { main: null };
  host.status = host.status || "loading";
  host.onDataChange = function (callback) {
    if (typeof callback === "function") dataCallbacks.push(callback);
  };
  host.onStatusChange = function (callback) {
    if (typeof callback === "function") statusCallbacks.push(callback);
  };
  host.onThemeChange = function (callback) {
    if (typeof callback === "function") themeCallbacks.push(callback);
  };
  window.DaimonWidget = host;

  var labels = {
    loading: "正在加载本地快照…",
    refreshing: "正在刷新, 当前显示上次成功数据",
    stale: "数据可能已过期",
    authRequired: "授权已失效, 请前往设置重新登录",
    offline: "网络不可用, 当前显示本地快照",
    partial: "部分数据源暂不可用",
    error: "刷新失败, 当前显示上次成功数据",
    notConfigured: "尚未配置此模块"
  };

  function ensureStateElement() {
    var existing = document.querySelector("[data-mddd-host-state]");
    if (existing) return existing;
    if (!document.body) return null;
    var style = document.createElement("style");
    style.textContent =
      ".mddd-host-state{position:fixed;z-index:2147483647;right:12px;bottom:10px;" +
      "max-width:calc(100% - 24px);padding:5px 9px;border-radius:999px;" +
      "border:1px solid var(--kimi-color-border,#d8d3c5);" +
      "background:color-mix(in srgb,var(--kimi-color-card,#f7f5ee) 92%,transparent);" +
      "box-shadow:0 4px 14px rgba(31,29,26,.10);backdrop-filter:blur(8px);" +
      "font:10px/1.3 system-ui,sans-serif;color:var(--kimi-color-text-secondary,#4d483d)}" +
      ".mddd-host-state[hidden]{display:none}" +
      "@media(prefers-reduced-motion:reduce){*,*::before,*::after{" +
      "animation-duration:.01ms!important;animation-iteration-count:1!important;" +
      "transition-duration:.01ms!important;scroll-behavior:auto!important}}";
    document.head.appendChild(style);
    var element = document.createElement("div");
    element.className = "mddd-host-state";
    element.setAttribute("data-mddd-host-state", "");
    element.setAttribute("role", "status");
    element.setAttribute("aria-live", "polite");
    document.body.appendChild(element);
    return element;
  }

  function renderState() {
    var element = ensureStateElement();
    if (!element) return;
    var label = labels[host.status];
    element.hidden = !label;
    element.textContent = label || "";
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderState, { once: true });
  } else {
    renderState();
  }
})();
