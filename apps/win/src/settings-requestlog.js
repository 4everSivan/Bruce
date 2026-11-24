// 设置页「请求日志」(C264, design/14): 只读本机请求台账, 不触发全量采集。
// 数据来自 Rust 命令 get_request_log (module=request-log, 0-based page)。
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections = window.BruceSettingsSections || {};
  const { node, byId, invoke, button, card, state } = core;

  const SUPPORTED_AGENTS = ["claude-code", "codex", "antigravity", "zcode"];
  const AGENT_LABELS = {
    "claude-code": "Claude Code",
    codex: "Codex",
    antigravity: "Antigravity",
    zcode: "ZCode",
  };
  const RANGES = [
    ["today", "今日"],
    ["sevenDays", "近 7 天"],
    ["thirtyDays", "近 30 天"],
  ];
  const PAGE_SIZE = 50;

  const rl = {
    range: "today",
    selected: new Set(),
    userChosen: false,
    model: "",
    page: 0,
    seq: 0,
    data: null,
    detailId: null,
    loading: false,
  };

  function rangeStart(range, now) {
    if (range === "today") {
      const start = new Date(now);
      start.setHours(0, 0, 0, 0);
      return start.getTime();
    }
    const days = range === "sevenDays" ? 7 : 30;
    return now - days * 24 * 60 * 60 * 1000;
  }

  /// design/14 §4.2.8: 首次只勾选今日有用量的受支持来源; 用户改选后不再自动覆盖。
  function applyDefaultAgents(panel) {
    if (rl.userChosen) return false;
    const active = new Set(
      (panel?.hourly?.rows || [])
        .filter((row) => (row.todayTotal || 0) > 0)
        .map((row) => row.agentId || row.id)
        .filter((id) => SUPPORTED_AGENTS.includes(id)),
    );
    const changed = active.size !== rl.selected.size || [...active].some((id) => !rl.selected.has(id));
    rl.selected = active;
    return changed;
  }

  function formatTokens(value) {
    return Number(value || 0).toLocaleString("zh-CN");
  }

  function formatTime(ms) {
    return new Date(ms).toLocaleString("zh-CN", { hour12: false });
  }

  function speedText(entry) {
    const latency = entry.latencyMs;
    if ((entry.output || 0) < 200 || !latency || latency < 1000) return "—";
    const speed = entry.output / (latency / 1000);
    if (!Number.isFinite(speed) || speed <= 0) return "—";
    return `≈${speed >= 1 ? Math.round(speed) : speed.toFixed(1)}/s`;
  }

  function displayModel(entry) {
    if (entry.model) return entry.model;
    if (entry.rawModel) return entry.rawModel;
    return "未标注模型";
  }

  function costText(entry) {
    return typeof entry.costUsd === "number" ? `$${entry.costUsd.toFixed(4)}` : "—";
  }

  async function query() {
    const seq = ++rl.seq;
    const start = rangeStart(rl.range, Date.now());
    rl.loading = true;
    renderStatus();
    let data = null;
    try {
      data = await invoke("get_request_log", {
        start,
        end: Date.now(),
        page: rl.page,
        pageSize: PAGE_SIZE,
        agentIds: [...rl.selected].sort(),
        model: rl.model || null,
      });
    } catch (error) {
      if (seq !== rl.seq) return;
      rl.loading = false;
      rl.data = null;
      renderBody();
      renderStatus(error?.message || String(error));
      return;
    }
    if (seq !== rl.seq) return;
    rl.loading = false;
    rl.data = data || {};
    rl.detailId = null;
    renderBody();
    renderStatus();
  }

  let bodyHost = null;
  let statusHost = null;
  let rangeButtons = [];
  let agentButtons = [];

  function renderStatus(error = null) {
    if (!statusHost) return;
    if (error) {
      statusHost.textContent = `请求日志读取失败：${error}`;
      statusHost.dataset.tone = "warn";
    } else if (rl.loading) {
      statusHost.textContent = "正在读取…";
      statusHost.dataset.tone = "info";
    } else {
      statusHost.textContent = "";
      statusHost.dataset.tone = "info";
    }
  }

  function renderRange() {
    for (const [key, buttonEl] of rangeButtons) {
      buttonEl.classList.toggle("active", key === rl.range);
      buttonEl.setAttribute("aria-checked", String(key === rl.range));
    }
  }

  function renderAgents() {
    for (const [id, buttonEl] of agentButtons) {
      const on = rl.selected.has(id);
      buttonEl.classList.toggle("active", on);
      buttonEl.setAttribute("aria-checked", String(on));
    }
  }

  function summaryRow(label, value) {
    const cell = node("div", null, { class: "requestlog-metric" });
    cell.append(node("div", label, { class: "requestlog-metric-label" }), node("b", value, { class: "requestlog-metric-value" }));
    return cell;
  }

  function renderBody() {
    if (!bodyHost) return;
    bodyHost.replaceChildren();
    const data = rl.data;
    if (!data) {
      bodyHost.append(node("div", "暂无请求日志", { class: "requestlog-empty" }));
      return;
    }
    const summary = data.summary || { tokens: 0, costUsd: 0, avgTokens: 0 };
    const metrics = node("div", null, { class: "requestlog-summary" });
    metrics.append(
      summaryRow("请求数", formatTokens(data.total)),
      summaryRow("Token 总量", formatTokens(summary.tokens)),
      summaryRow("折算费用", typeof summary.costUsd === "number" ? `$${summary.costUsd.toFixed(4)}` : "—"),
      summaryRow("平均 Token", formatTokens(summary.avgTokens)),
    );
    bodyHost.append(metrics);
    if (data.notice) bodyHost.append(node("p", data.notice, { class: "hint" }));

    const entries = data.entries || [];
    if (!entries.length) {
      bodyHost.append(node("div", "当前筛选条件下没有请求记录", { class: "requestlog-empty" }));
    } else {
    const wrap = node("div", null, { class: "price-table-wrap requestlog-table-wrap" });
    const table = node("table", null, { class: "fluent-table requestlog-table" });
    const head = node("thead");
    const headRow = node("tr");
    for (const label of ["时间", "Agent", "模型", "输入", "输出", "缓存读", "缓存写", "费用", "状态", "耗时", "速度"]) {
      headRow.append(node("th", label));
    }
    head.append(headRow);
    const tbody = node("tbody");
    for (const entry of entries) {
      const row = node("tr", null, { class: "requestlog-row", tabindex: "0" });
      row.dataset.requestId = entry.requestId;
      if (entry.requestId === rl.detailId) row.classList.add("selected");
      const cells = [
        formatTime(entry.occurredAt),
        AGENT_LABELS[entry.agentId] || entry.agentId,
        displayModel(entry),
        formatTokens(entry.input),
        formatTokens(entry.output),
        formatTokens(entry.cacheRead),
        formatTokens(entry.cacheCreation),
        costText(entry),
        entry.statusCode ? String(entry.statusCode) : "—",
        entry.latencyMs != null ? `${entry.latencyMs} ms` : "—",
        speedText(entry),
      ];
      for (const text of cells) row.append(node("td", text));
      const select = () => {
        rl.detailId = rl.detailId === entry.requestId ? null : entry.requestId;
        renderBody();
      };
      row.addEventListener("click", select);
      row.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          select();
        }
      });
      tbody.append(row);
    }
    table.append(head, tbody);
    wrap.append(table);
    bodyHost.append(wrap);
    }

    const page = Number(data.page || 0);
    const totalPages = Math.max(1, Math.ceil(Number(data.total || 0) / Number(data.pageSize || PAGE_SIZE)));
    const pager = node("div", null, { class: "requestlog-pager" });
    const prev = node("button", "上一页", { type: "button", class: "btn plain-btn" });
    prev.disabled = page <= 0 || rl.loading;
    prev.addEventListener("click", () => {
      if (rl.page > 0) {
        rl.page -= 1;
        query();
      }
    });
    const next = node("button", "下一页", { type: "button", class: "btn plain-btn" });
    next.disabled = page + 1 >= totalPages || rl.loading;
    next.addEventListener("click", () => {
      rl.page += 1;
      query();
    });
    pager.append(prev, node("span", `第 ${page + 1} / ${totalPages} 页 · 共 ${formatTokens(data.total)} 条`, { class: "requestlog-page-label" }), next);
    bodyHost.append(pager);

    const detail = entries.find((entry) => entry.requestId === rl.detailId);
    if (detail) bodyHost.append(requestDetail(detail));
  }

  function requestDetail(entry) {
    const panel = node("section", null, { class: "fluent-card requestlog-detail", "aria-label": "请求详情" });
    panel.append(node("h2", "请求详情", { class: "card-caption" }));
    const grid = node("div", null, { class: "requestlog-detail-grid" });
    const field = (label, value) => {
      const cell = node("div", null, { class: "requestlog-detail-field" });
      cell.append(node("span", label, { class: "requestlog-detail-label" }), node("span", value, { class: "requestlog-detail-value" }));
      grid.append(cell);
    };
    field("请求 ID", entry.requestId);
    field("Agent", AGENT_LABELS[entry.agentId] || entry.agentId);
    field("模型", displayModel(entry));
    field("计价模型", entry.pricingModel || "未计价");
    field("时间", formatTime(entry.occurredAt));
    field("项目", entry.project || "—");
    field("输入", formatTokens(entry.input));
    field("输出", formatTokens(entry.output));
    field("缓存读", formatTokens(entry.cacheRead));
    field("缓存写", formatTokens(entry.cacheCreation));
    if (entry.cacheCreation1h != null) field("1h 缓存写", formatTokens(entry.cacheCreation1h));
    field("费用", costText(entry));
    field("状态码", entry.statusCode ? String(entry.statusCode) : "—");
    field("耗时", entry.latencyMs != null ? `${entry.latencyMs} ms` : "—");
    field("首 Token", entry.firstTokenMs != null ? `${entry.firstTokenMs} ms` : "—");
    field("速度", speedText(entry));
    field("数据保真", entry.fidelity || "—");
    panel.append(grid);
    return panel;
  }

  function buildRequestLog(host) {
    host.replaceChildren();
    const intro = card(host, "请求日志");
    intro.append(node("p", "只读本机请求台账，保留最近 30 天；打开此页不会启动全量采集。", { class: "hint" }));

    const toolbar = card(host);
    toolbar.classList.add("requestlog-toolbar");
    const rangeGroup = node("div", null, { class: "fluent-seg", role: "radiogroup", "aria-label": "时间范围" });
    rangeButtons = RANGES.map(([key, label]) => {
      const choice = node("button", label, { type: "button", class: "seg-opt", role: "radio", "aria-checked": "false" });
      choice.addEventListener("click", () => {
        if (rl.range === key) return;
        rl.range = key;
        rl.page = 0;
        renderRange();
        query();
      });
      rangeGroup.append(choice);
      return [key, choice];
    });
    const agentGroup = node("div", null, { class: "requestlog-agents", "aria-label": "Agent 筛选" });
    agentButtons = SUPPORTED_AGENTS.map((id) => {
      const choice = node("button", AGENT_LABELS[id], { type: "button", class: "requestlog-agent", role: "checkbox", "aria-checked": "false" });
      choice.addEventListener("click", () => {
        rl.userChosen = true;
        if (rl.selected.has(id)) rl.selected.delete(id);
        else rl.selected.add(id);
        rl.page = 0;
        renderAgents();
        query();
      });
      agentGroup.append(choice);
      return [id, choice];
    });
    const modelInput = node("input", null, { type: "text", class: "requestlog-model", placeholder: "按模型筛选（回车）", "aria-label": "模型筛选" });
    modelInput.addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      const value = modelInput.value.trim();
      if (value === rl.model) return;
      rl.model = value;
      rl.page = 0;
      query();
    });
    const refresh = button(toolbar, "requestlog-refresh", "刷新", () => query(), "btn plain-btn");
    refresh.title = "重新读取请求日志（不触发全量采集）";
    statusHost = node("span", null, { class: "requestlog-status", role: "status" });
    toolbar.append(rangeGroup, agentGroup, modelInput, refresh, statusHost);

    bodyHost = node("div", null, { class: "requestlog-body" });
    host.append(bodyHost);

    applyDefaultAgents(state.currentDashboard);
    renderRange();
    renderAgents();
    renderBody();
    query();
  }

  /// dashboard-updated 时仅刷新默认 Agent 选择, 不重新查询当前页。
  function updateRequestLogDashboard(panel) {
    const changed = applyDefaultAgents(panel);
    renderAgents();
    if (changed) {
      rl.page = 0;
      query();
    }
  }

  Object.assign(S, { buildRequestLog, updateRequestLogDashboard, _requestLogState: rl });
})();
