// Settings window bootstrap (TD-011): wires navigation, composes the category panes from the
// section scripts and owns the shared settings/dashboard/stepfun event listeners.
// Shared state and DOM helpers live in settings-state.js; section implementations in the
// settings-subscription / settings-workbench / settings-pricing / settings-maintenance scripts.
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const { byId, listen, message, applyTheme, switchCategory, state } = core;

  // MARK: - 初始化
  const ready = (async () => {
    // 绑定侧栏点击
    for (const navBtn of document.querySelectorAll(".navitem")) {
      navBtn.addEventListener("click", () => switchCategory(navBtn.dataset.category));
    }

    const gHost = byId("pane-general-content");
    const uHost = byId("pane-agentUsage-content");
    const sHost = byId("pane-subscription-content");
    const cHost = byId("pane-consent-content");
    const mHost = byId("pane-maintenance-content");

    if (gHost) S.buildGeneral(gHost);
    if (uHost) S.buildAgentUsage(uHost);
    if (sHost) S.buildSubscription(sHost);
    if (cHost) S.buildConsent(cHost);
    if (mHost) S.buildMaintenance(mHost);

    try {
      await Promise.all([S.loadSettings(), S.loadCredentials(), S.loadPrices(), S.loadRuntimeInfo(), S.loadPlans(), S.loadClaudeLocalStatus(), S.initSoftwareUpdate()]);
      await listen("settings-updated", async () => {
        try { await S.loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); }
      });
      await listen("dashboard-updated", event => {
        state.currentDashboard = event.payload;
        S.renderAgentUsageWorkbench();
      });
      // StepFun 双轨捕获 (C086): WebView2 页面加载事件到达时同步更新当前 URL 并立即试捕一次。
      await listen("stepfun-page-load", event => {
        if (!state.stepfunWebSession) return;
        const payload = event?.payload || {};
        if (payload.url) {
          state.stepfunWebSession.currentUrl = payload.url;
          S.renderStepFunWebPanel();
        }
        if (payload.loading === false) {
          S.pollStepFunWebLogin(false);
        }
      });
    } catch {
      message(byId("settings-status"), "部分配置读取失败，请重新打开设置");
    }
  })();

  window.BruceSettings = { ready, applyTheme, switchCategory };
})();
