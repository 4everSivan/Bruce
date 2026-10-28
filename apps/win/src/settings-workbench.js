// Settings section: Agent usage workbench, KPI tiles and charts (TD-011).
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const coreState = core.state;
  const { invoke, listen, providers, CATEGORIES, node, byId, UP, REFRESH_PRESETS, TIME_RANGES, SESSION_PROBES, svgEl, catmullRomToBezier, applyTheme, message, persist, input, row, card, segmented, button, actions, segmentRenderers, objectJSON, validateOverrides, orderedAll, move, switchCategory } = core;
  // 跨分节调用经共享命名空间在调用时解析 (脚本按顺序加载, 调用发生在全部加载完成之后)。
  const runExport = (...args) => S.runExport(...args);
  const loadRuntimeInfo = (...args) => S.loadRuntimeInfo(...args);
  const loadPlans = (...args) => S.loadPlans(...args);

  function buildAgentUsage(host) {
    host.replaceChildren();

    // T07 工作台容器
    const workbenchRoot = node("div", null, { id: "workbench-root" });
    host.append(workbenchRoot);

    // 1. 会话来源与采集探针 (对齐 mac AgentUsageWorkbenchView.sessionProbeFooterCard)
    const cSources = card(host, "会话来源与采集探针");
    row(cSources, "Rust Collector", node("span", "可用", { class: "status-tag ok" }), "扫描本机会话目录并计算 Token 增量缓存与指纹");

    const probeList = node("div", null, { id: "session-probes" });
    cSources.append(probeList);

    const act = actions(cSources);
    act.append(node("span", "所有会话仅在本机分析，绝不上报远程服务器", { class: "card-actions-note" }));
    button(act, "session-rescan", "重新检查", async () => {
      try {
        message(byId("settings-status"), "正在重新扫描本机会话…");
        await invoke("refresh_now");
        await loadRuntimeInfo();
        await loadPlans();
        message(byId("settings-status"), "会话扫描已刷新");
      } catch (error) {
        message(byId("settings-status"), `扫描失败: ${error.message || error}`);
      }
    });

    // 2. Agent 会话采集授权 (对齐 mac)
    const cUsage = card(host, "Agent 会话采集");
    const usageToggle = input("setting-usage", "checkbox");
    usageToggle.addEventListener("change", () => persist({ usageEnabled: usageToggle.checked }, {
      revert: () => { usageToggle.checked = !usageToggle.checked; },
    }));
    row(cUsage, "读取本机 Agent 会话用量", usageToggle, "开启后在本机读取会话记录，计算 Token 用量与费用。");
    const summary = node("div", null, { class: "hint-box" });
    summary.append(node("p", "授权后应用将：", { class: "hint-title" }));
    const ul = node("ul", null, { class: "hint-list" });
    ul.append(node("li", "只读扫描本机 Agent 会话目录（如 Claude Code, Codex, Kimi, OpenCode 等）与 CC Switch 数据库；"));
    ul.append(node("li", "在用户本机闭环计算 Token 总量与估算费用，无自有云端服务端；"));
    ul.append(node("li", "严格执行只读模式（mode=ro），绝不修改、删除或上传任何外部会话日志。"));
    summary.append(ul);
    cUsage.append(summary);

    renderAgentUsageWorkbench();
    renderSessionProbes();
  }

  // MARK: - Agent 用量工作台 (C070, 对齐 mac AgentUsageWorkbenchView 及其卡片)
  //
  // 数值全部来自 get_usage_analytics (Rust viewmodel analytics, 与 mac golden 逐字段对拍);
  // 前端只负责呈现与交互状态, 不做任何汇总或估算。

  // Rust/C `{:.N}` 按精确二进制值舍入、平局取偶; JS toFixed 平局进位。
  // 只在恰为平局时改取偶, 使悬停数值文案与 mac 逐字符一致。
  function fixedEven(value, digits) {
    const rounded = value.toFixed(digits);
    const [whole, fraction = ""] = value.toFixed(20).split(".");
    const tail = fraction.slice(digits);
    if (!/^50*$/.test(tail)) return rounded;
    const kept = fraction.slice(0, digits);
    const lastDigit = Number((digits ? kept : whole).slice(-1));
    return lastDigit % 2 === 0 ? (digits ? `${whole}.${kept}` : whole) : rounded;
  }

  // mac PanelFormat.tokenCount / Rust format::token_count: K/M 一位小数、B 两位, 去尾零。
  function tokenCount(value) {
    const trim = text => text.replace(/\.?0+$/, "");
    if (value < 1000) return String(value);
    if (value < 1_000_000) return `${trim(fixedEven(value / 1000, 1))}K`;
    if (value < 1_000_000_000) return `${trim(fixedEven(value / 1_000_000, 1))}M`;
    return `${trim(fixedEven(value / 1_000_000_000, 2))}B`;
  }

  const percentText = value => `${fixedEven(value, 1)}%`;

  const TOKEN_TYPE_SERIES = [
    { key: "type_input", name: "输入 Prompt", color: "#4C9CFF", short: "输入" },
    { key: "type_output", name: "输出 Output", color: "#A855F7", short: "输出" },
    { key: "type_cache", name: "缓存命中 Read", color: "#10B981", short: "缓存" },
  ];
  const CHART_MODES = [["agent", "Agent"], ["model", "模型"], ["tokenType", "Token 构成"], ["cost", "费用"]];

  const workbench = {
    snapshot: null,
    seq: 0,
    chartMode: "agent",
    chartType: "line",
    selectedIndex: null,
    mergedModels: true,
    expandedModels: new Set(),
    expandedAgents: new Set(),
    hoveredHour: null,
  };

  function chip(text, color, cls = "wb-chip") {
    return node("span", text, { class: cls, style: `--chip: ${color};` });
  }

  // 「**粗体**」片段 (峰值 / 均值摘要) -> 文本 + <strong>
  function markdownLine(text, cls) {
    const line = node("span", null, { class: cls });
    String(text).split("**").forEach((part, index) => {
      if (part) line.append(index % 2 ? node("strong", part) : part);
    });
    return line;
  }

  function segButtons(options, value, onPick, cls = "") {
    const group = node("div", null, { class: `fluent-seg ${cls}`.trim(), role: "radiogroup" });
    for (const [key, label] of options) {
      const isOn = key === value;
      const choice = node("button", label, {
        type: "button", class: isOn ? "seg-opt active" : "seg-opt", role: "radio", "aria-checked": String(isOn),
      });
      choice.addEventListener("click", () => (isOn ? undefined : onPick(key)));
      group.append(choice);
    }
    return group;
  }

  function cardHeader(title, badge, badgeColor, sub, trailing = []) {
    const head = node("div", null, { class: "wb-head" });
    const meta = node("div", null, { class: "wb-head-meta" });
    const line = node("div", null, { class: "wb-title-line" });
    line.append(node("span", title, { class: "wb-title" }));
    if (badge) line.append(chip(badge, badgeColor, "wb-chip wb-chip-lg"));
    meta.append(line, node("span", sub, { class: "wb-sub" }));
    head.append(meta, node("span", null, { class: "wb-spacer" }), ...trailing);
    return head;
  }

  // mac chevron.down.circle / chevron.up.circle.fill
  function expandButton(expanded, help, onToggle) {
    const toggle = node("button", null, {
      type: "button", class: expanded ? "wb-expand on" : "wb-expand", title: help, "aria-label": help, "aria-expanded": String(expanded),
    });
    const glyph = svgEl("svg", { viewBox: "0 0 16 16", "aria-hidden": "true" });
    glyph.append(svgEl("circle", { cx: "8", cy: "8", r: "6.75", class: "wb-expand-ring" }));
    glyph.append(svgEl("path", { d: expanded ? "M5.2 9.4 8 6.6l2.8 2.8" : "M5.2 6.6 8 9.4l2.8-2.8", class: "wb-expand-chevron" }));
    toggle.append(glyph);
    toggle.addEventListener("click", onToggle);
    return toggle;
  }

  async function renderAgentUsageWorkbench() {
    const root = byId("workbench-root");
    if (!root) return;
    const seq = ++workbench.seq;
    let snapshot = null;
    try {
      snapshot = await invoke("get_usage_analytics", { range: coreState.selectedTimeRange });
    } catch (error) {
      message(byId("settings-status"), `用量分析读取失败：${error.message || error}`, "warn");
    }
    // 期间又切换了范围或收到新快照: 丢弃过期结果
    if (seq !== workbench.seq) return;
    workbench.snapshot = snapshot;
    workbench.selectedIndex = null;
    drawWorkbench();
  }

  function drawWorkbench() {
    const root = byId("workbench-root");
    if (!root) return;
    const snapshot = workbench.snapshot;
    root.replaceChildren(workbenchToolbar());
    if (!snapshot) return;
    const slots = ["timeline", "models", "agents", "composition"].map(name => node("div", null, { id: `wb-${name}`, class: "wb-slot" }));
    root.append(kpiTiles(snapshot.kpi), ...slots);
    drawTimeline();
    drawModels();
    drawAgents();
    drawComposition();
  }

  function fillSlot(name, content) {
    const slot = byId(`wb-${name}`);
    if (slot) slot.replaceChildren(content);
  }

  function workbenchToolbar() {
    const bar = node("div", null, { class: "wb-toolbar" });
    bar.append(segButtons(TIME_RANGES.map(range => [range.key, range.label]), coreState.selectedTimeRange, key => {
      coreState.selectedTimeRange = key;
      return renderAgentUsageWorkbench();
    }, "time-range-picker"));
    bar.append(node("span", null, { class: "wb-spacer" }));
    const csv = button(bar, "workbench-export-csv", "导出 CSV 账单", () => runExport("export_workbench_csv", "CSV 账单", "csv", {
      // mac Date.now.formatted(.iso8601.year().month().day()) 为 UTC 日期
      defaultName: `bruce_agent_usage_${new Date().toISOString().slice(0, 10)}.csv`,
      args: { range: coreState.selectedTimeRange },
    }));
    csv.setAttribute("title", "导出归一化模型与 Token 账单 CSV");
    const json = button(bar, "workbench-export-json", "导出 JSON 明细", () => runExport("export_workbench_json", "JSON 明细", "json", {
      defaultName: "bruce_agent_usage_artifact.json",
    }));
    json.setAttribute("title", "导出完整会话用量 JSON 原始结构");
    return bar;
  }

  // MARK: 4 格核心 KPI 磁贴

  function kpiTiles(kpi) {
    const grid = node("div", null, { class: "kpi-tiles-grid", id: "kpi-tiles" });
    const rangeLabel = TIME_RANGES.find(range => range.key === coreState.selectedTimeRange)?.label || "";
    const tiles = [
      ["总 Token", kpi.totalTokensText, `${kpi.equivalentMText} Tokens`, rangeLabel, "var(--settings-accent)"],
      ["费用", kpi.costText, kpi.averageCostPerMillionText, kpi.costTagText, "var(--ok)"],
      ["缓存收益", kpi.cacheHitRateText, kpi.cacheSavedCostText, "已省", "#10B981"],
      ["活跃 Agent", `${kpi.activeAgentsCount} 个`, kpi.topAgentText, "全域", "#8B5CF6"],
    ];
    for (const [title, value, sub, tag, color] of tiles) {
      const tile = node("div", null, { class: "kpi-tile" });
      const head = node("div", null, { class: "kpi-head" });
      head.append(node("span", title, { class: "kpi-label" }), chip(tag, color));
      tile.append(head, node("div", value, { class: "kpi-value" }), node("div", sub, { class: "kpi-sub", title: sub }));
      grid.append(tile);
    }
    return grid;
  }

  // MARK: 时序趋势 (mac TimelineChartCard)

  function chartSeries(snapshot) {
    switch (workbench.chartMode) {
      case "agent":
        return snapshot.agents.map(agent => ({ key: agent.agentId, name: agent.name, color: agent.colorHex, value: point => point.seriesValues[agent.agentId] || 0 }));
      case "model":
        return snapshot.models.slice(0, 5).map(model => ({ key: `model_${model.canonicalKey}`, name: model.displayName, color: model.colorHex, value: point => point.seriesValues[`model_${model.canonicalKey}`] || 0 }));
      case "tokenType":
        return TOKEN_TYPE_SERIES.map(type => ({ ...type, value: point => point.seriesValues[type.key] || 0 }));
      default:
        return [{ key: "cost", name: "折算总费用 ($)", color: "#10B981", value: point => point.costUsd }];
    }
  }

  // 纵轴刻度: 约 4 段的「整」步长 (1/2/2.5/5 × 10^n)
  function niceTicks(max) {
    if (!(max > 0)) return { top: 1, ticks: [0] };
    const raw = max / 4;
    const magnitude = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].map(factor => factor * magnitude).find(value => value >= raw);
    const top = Math.ceil(max / step) * step;
    const ticks = [];
    for (let index = 0; index * step <= top + step / 2; index += 1) ticks.push(index * step);
    return { top, ticks };
  }

  // mac yAxisValue: 费用 "$x.xx"; token "x.xM" / "xK" / 整数
  function axisLabel(value) {
    if (workbench.chartMode === "cost") return `$${fixedEven(value, 2)}`;
    const whole = Math.trunc(value);
    if (whole >= 1_000_000) return `${fixedEven(whole / 1_000_000, 1)}M`;
    if (whole >= 1_000) return `${fixedEven(whole / 1_000, 0)}K`;
    return String(whole);
  }

  function drawTimeline() {
    const snapshot = workbench.snapshot;
    const timeline = snapshot.timeline;
    const series = chartSeries(snapshot);
    const card = node("section", null, { class: "fluent-card wb-card workbench-chart-card" });
    card.append(cardHeader("时序趋势", null, null, "多维度用量走势与峰值下钻分析", [
      segButtons([["line", "折线"], ["area", "面积"]], workbench.chartType, type => { workbench.chartType = type; drawTimeline(); }, "chart-type-picker"),
      segButtons(CHART_MODES, workbench.chartMode, mode => { workbench.chartMode = mode; workbench.selectedIndex = null; drawTimeline(); }, "chart-dim-tabs"),
    ]));
    const legend = node("div", null, { class: "wb-legend" });
    for (const item of series) {
      const entry = node("span", null, { class: "wb-legend-item" });
      entry.append(node("i", null, { class: "wb-dot", style: `background: ${item.color};` }), item.name);
      legend.append(entry);
    }
    card.append(legend);
    if (!timeline.points.length || !series.length) {
      const empty = node("div", null, { class: "wb-chart-empty" });
      empty.append(node("span", "⌁", { class: "wb-chart-empty-icon" }), node("span", "当前时间跨度暂无活跃用量点"));
      card.append(empty);
    } else {
      card.append(timelineChart(timeline.points, series));
    }
    card.append(node("div", null, { class: "wb-summary", id: "wb-timeline-summary" }));
    fillSlot("timeline", card);
    drawTimelineSummary();
  }

  function timelineChart(points, series) {
    const width = 1000;
    const height = 200;
    const values = points.flatMap(point => series.map(item => item.value(point)));
    const { top, ticks } = niceTicks(Math.max(0, ...values));
    // Swift Charts 对字符串 x 值用分带刻度: 点位于各带中心, 首末点不贴边
    const xAt = index => ((index + 0.5) / points.length) * width;
    const yAt = value => height - (value / top) * height;

    const chart = node("div", null, { class: "wb-chart" });
    const yAxis = node("div", null, { class: "wb-chart-y" });
    for (const tick of ticks) yAxis.append(node("span", axisLabel(tick), { style: `bottom: ${(tick / top) * 100}%;` }));
    const plot = node("div", null, { class: "wb-chart-plot" });
    const svg = svgEl("svg", { viewBox: `0 0 ${width} ${height}`, preserveAspectRatio: "none" });
    for (const tick of ticks) {
      svg.append(svgEl("line", { x1: 0, x2: width, y1: yAt(tick), y2: yAt(tick), class: "wb-grid", "vector-effect": "non-scaling-stroke" }));
    }
    const defs = svgEl("defs");
    svg.append(defs);
    series.forEach((item, index) => {
      const { pathD, areaD } = catmullRomToBezier(points.map((point, at) => ({ x: xAt(at), y: yAt(item.value(point)) })), height, width);
      if (workbench.chartType === "area") {
        const gradient = svgEl("linearGradient", { id: `wb-grad-${index}`, x1: "0", y1: "0", x2: "0", y2: "1" });
        gradient.append(svgEl("stop", { offset: "0%", "stop-color": item.color, "stop-opacity": "0.35" }));
        gradient.append(svgEl("stop", { offset: "100%", "stop-color": item.color, "stop-opacity": "0.04" }));
        defs.append(gradient);
        svg.append(svgEl("path", { d: areaD, fill: `url(#wb-grad-${index})` }));
      }
      svg.append(svgEl("path", { d: pathD, fill: "none", stroke: item.color, "stroke-width": "2", "vector-effect": "non-scaling-stroke", class: "wb-line" }));
    });
    const rule = svgEl("line", { id: "wb-rule", x1: 0, x2: 0, y1: 0, y2: height, class: "wb-rule hidden", "vector-effect": "non-scaling-stroke" });
    svg.append(rule);
    plot.append(svg);
    // mac 在 ≤14 个点时画点标记; HTML 圆点避免 preserveAspectRatio=none 把圆拉成椭圆
    if (points.length <= 14) {
      series.forEach(item => points.forEach((point, index) => {
        plot.append(node("i", null, {
          class: "wb-point",
          style: `left: ${(xAt(index) / width) * 100}%; bottom: ${(item.value(point) / top) * 100}%; background: ${item.color};`,
        }));
      }));
    }
    // 悬停选点 (mac chartXSelection): 就近点, 移出清除
    const select = index => {
      if (index === workbench.selectedIndex) return;
      workbench.selectedIndex = index;
      rule.setAttribute("class", index == null ? "wb-rule hidden" : "wb-rule");
      if (index != null) {
        rule.setAttribute("x1", xAt(index));
        rule.setAttribute("x2", xAt(index));
      }
      drawTimelineSummary();
    };
    plot.addEventListener("mousemove", event => {
      const rect = plot.getBoundingClientRect?.();
      if (!rect || !rect.width) return;
      const band = Math.floor(((event.clientX - rect.left) / rect.width) * points.length);
      select(Math.min(points.length - 1, Math.max(0, band)));
    });
    plot.addEventListener("mouseleave", () => select(null));

    const xAxis = node("div", null, { class: "wb-chart-x" });
    const labelCount = Math.min(points.length, 8);
    const labelIndexes = new Set(Array.from({ length: labelCount }, (_, at) => (labelCount > 1 ? Math.round((at * (points.length - 1)) / (labelCount - 1)) : 0)));
    for (const index of labelIndexes) {
      xAxis.append(node("span", points[index].label, { style: `left: ${(xAt(index) / width) * 100}%;` }));
    }
    chart.append(yAxis, plot, xAxis);
    return chart;
  }

  function drawTimelineSummary() {
    const host = byId("wb-timeline-summary");
    const snapshot = workbench.snapshot;
    if (!host || !snapshot) return;
    host.replaceChildren();
    const point = workbench.selectedIndex == null ? null : snapshot.timeline.points[workbench.selectedIndex];
    if (!point) {
      host.append(
        markdownLine(snapshot.timeline.peakSummary, "wb-summary-peak"),
        node("span", null, { class: "wb-spacer" }),
        markdownLine(snapshot.timeline.avgSummary, "wb-summary-avg"),
      );
      return;
    }
    host.append(node("span", `📍 ${point.label}`, { class: "wb-summary-label" }));
    if (workbench.chartMode === "cost") {
      host.append(node("span", `$${fixedEven(point.costUsd, 4)}`, { class: "wb-summary-value cost" }));
      return;
    }
    host.append(node("span", `${tokenCount(point.totalTokens)} Tokens`, { class: "wb-summary-value" }));
    const parts = workbench.chartMode === "agent"
      ? snapshot.agents.slice(0, 3).map(agent => [agent.name, point.seriesValues[agent.agentId], agent.colorHex])
      : workbench.chartMode === "model"
        ? snapshot.models.slice(0, 3).map(model => [model.displayName, point.seriesValues[`model_${model.canonicalKey}`], model.colorHex])
        : TOKEN_TYPE_SERIES.map(type => [type.short, point.seriesValues[type.key], type.color]);
    for (const [name, value, color] of parts) {
      if (value > 0) host.append(node("span", `${name}: ${tokenCount(value)}`, { class: "wb-summary-part", style: `color: ${color};` }));
    }
  }

  // MARK: 模型分布 (mac CanonicalModelAnalyticsCard)

  function drawModels() {
    const models = workbench.snapshot.models;
    const sourceCount = models.reduce((sum, model) => sum + Math.max(1, model.sources.length), 0);
    const card = node("section", null, { class: "fluent-card wb-card canonical-card" });
    card.append(cardHeader("模型分布", `${models.length} 款主模型 · ${sourceCount} 个渠道`, "var(--ok)", "自动归并同类模型，支持展开查看各渠道细分贡献", [
      segButtons([["merged", "合并视图"], ["raw", "原始渠道"]], workbench.mergedModels ? "merged" : "raw", view => { workbench.mergedModels = view === "merged"; drawModels(); }),
    ]));
    const list = node("div", null, { class: "wb-list" });
    if (!models.length) {
      list.append(node("div", "暂无模型消耗数据", { class: "wb-empty" }));
    } else if (workbench.mergedModels) {
      for (const model of models) list.append(modelRow(model));
    } else {
      const sources = models.flatMap(model => model.sources).sort((left, right) => right.tokens - left.tokens);
      sources.forEach((source, index) => {
        const item = node("div", null, { class: "wb-row wb-raw-row" });
        const meta = node("div", null, { class: "wb-row-meta" });
        meta.append(node("span", source.rawModelName, { class: "wb-mono-name" }), node("span", `来源 Agent: ${source.agentDisplayName}`, { class: "wb-row-sub" }));
        item.append(node("span", `#${index + 1}`, { class: "wb-rank" }), meta, node("span", null, { class: "wb-spacer" }), node("span", source.tokensText, { class: "wb-tokens" }));
        if (source.costText) item.append(node("span", source.costText, { class: "wb-cost" }));
        list.append(item);
      });
    }
    card.append(list);
    fillSlot("models", card);
  }

  function modelRow(model) {
    const expanded = workbench.expandedModels.has(model.canonicalKey);
    const multi = model.sources.length > 1;
    const group = node("div", null, { class: "canonical-row" });
    const line = node("div", null, { class: "wb-row" });
    const meta = node("div", null, { class: "wb-row-meta" });
    const title = node("div", null, { class: "wb-name-line" });
    title.append(node("span", model.displayName, { class: "wb-name" }), node("span", model.vendor, { class: "wb-tag" }));
    if (multi) title.append(chip(`合并 ${model.sources.length} 个渠道`, "var(--settings-accent)"));
    meta.append(title, node("span", `规范键: ${model.canonicalKey}`, { class: "wb-row-sub wb-mono" }));
    const figures = node("div", null, { class: "wb-figures" });
    const shareLine = node("div", null, { class: "wb-share-line" });
    const bar = node("span", null, { class: "wb-share-bar" });
    bar.append(node("i", null, { style: `width: max(2px, ${Math.min(100, Math.max(0, model.sharePercent))}%); background: ${model.colorHex};` }));
    shareLine.append(bar, node("span", percentText(model.sharePercent), { class: "wb-share" }));
    const amountLine = node("div", null, { class: "wb-amount-line" });
    amountLine.append(node("span", model.totalTokensText, { class: "wb-tokens" }));
    if (model.costText) amountLine.append(node("span", model.costText, { class: "wb-cost" }));
    figures.append(shareLine, amountLine);
    line.append(node("i", null, { class: "wb-dot wb-dot-lg", style: `background: ${model.colorHex};` }), meta, node("span", null, { class: "wb-spacer" }), figures);
    line.append(multi
      ? expandButton(expanded, expanded ? "收起渠道明细" : `展开 ${model.sources.length} 个渠道明细`, () => {
        workbench.expandedModels[expanded ? "delete" : "add"](model.canonicalKey);
        drawModels();
      })
      : node("span", null, { class: "wb-expand-placeholder" }));
    group.append(line);
    if (expanded && multi) {
      const tree = node("div", null, { class: "wb-sources" });
      for (const source of model.sources) {
        const item = node("div", null, { class: "wb-source" });
        item.append(
          node("span", "↳", { class: "wb-source-arrow" }),
          node("span", source.rawModelName, { class: "wb-mono-name" }),
          node("span", source.agentDisplayName, { class: "wb-tag" }),
          node("span", null, { class: "wb-spacer" }),
          node("span", `${source.tokensText} (${percentText(source.shareOfModelPercent)})`, { class: "wb-source-share" }),
        );
        if (source.costText) item.append(node("span", source.costText, { class: "wb-cost" }));
        tree.append(item);
      }
      group.append(tree);
    }
    return group;
  }

  // MARK: Agent 表现 (mac AgentComparisonMatrixCard)

  function drawAgents() {
    const agents = workbench.snapshot.agents;
    const card = node("section", null, { class: "fluent-card wb-card agent-matrix-card" });
    card.append(cardHeader("Agent 表现", `${agents.length} 个活跃`, "var(--settings-accent)", "透视各 Agent 用量占比、Token 结构与关联工程"));
    const list = node("div", null, { class: "wb-list" });
    if (!agents.length) list.append(node("div", "暂无活跃 Agent 消耗数据", { class: "wb-empty" }));
    for (const agent of agents) list.append(agentRow(agent));
    card.append(list);
    fillSlot("agents", card);
  }

  function agentRow(agent) {
    const expanded = workbench.expandedAgents.has(agent.agentId);
    const hasDetails = agent.topProjects.length > 0 || agent.topModels.length > 0;
    const group = node("div", null, { class: "wb-agent" });
    const line = node("div", null, { class: "wb-row" });
    const meta = node("div", null, { class: "wb-row-meta" });
    const title = node("div", null, { class: "wb-name-line" });
    title.append(node("span", agent.name, { class: "wb-name" }), node("span", agent.status, { class: "wb-tag strong" }));
    meta.append(title);
    if (agent.note) meta.append(node("span", agent.note, { class: "wb-row-sub" }));
    // 构成比例条: 输入 (含缓存写入) 蓝 + 输出紫 + 缓存读取绿, 三段之和 = 总量
    const total = Math.max(1, agent.inputTokens + agent.outputTokens + agent.cacheReadTokens);
    const stack = node("span", null, { class: "wb-stack" });
    for (const [value, color] of [[agent.inputTokens, "#4C9CFF"], [agent.outputTokens, "#A855F7"], [agent.cacheReadTokens, "#10B981"]]) {
      stack.append(node("i", null, { style: `width: max(1px, ${(value / total) * 100}%); background: ${color};` }));
    }
    const figures = node("div", null, { class: "wb-figures" });
    const amounts = node("div", null, { class: "wb-amount-line" });
    amounts.append(
      node("span", agent.totalTokensText, { class: "wb-tokens" }),
      node("span", agent.costText, { class: "wb-cost" }),
      node("span", percentText(agent.sharePercent), { class: "wb-share wb-share-narrow" }),
    );
    figures.append(stack, amounts);
    line.append(node("i", null, { class: "wb-dot wb-dot-lg", style: `background: ${agent.colorHex};` }), meta, node("span", null, { class: "wb-spacer" }), figures);
    line.append(hasDetails
      ? expandButton(expanded, expanded ? "收起关联工程与模型" : "展开关联工程与模型下钻", () => {
        workbench.expandedAgents[expanded ? "delete" : "add"](agent.agentId);
        drawAgents();
      })
      : node("span", null, { class: "wb-expand-placeholder" }));
    group.append(line);
    if (expanded && hasDetails) {
      const detail = node("div", null, { class: "wb-agent-detail" });
      if (agent.topProjects.length) {
        const row = node("div", null, { class: "wb-detail-row" });
        const tags = node("div", null, { class: "wb-flow" });
        for (const project of agent.topProjects.slice(0, 4)) {
          const tag = node("span", null, { class: "wb-flow-tag" });
          tag.append(node("span", project.name, { class: "wb-mono-name" }), node("span", `(${tokenCount(project.total)})`, { class: "wb-flow-dim" }));
          tags.append(tag);
        }
        row.append(node("span", "📁 今日 Top 工程:", { class: "wb-detail-label" }), tags);
        detail.append(row);
      }
      if (agent.topModels.length) {
        const row = node("div", null, { class: "wb-detail-row" });
        const tags = node("div", null, { class: "wb-flow" });
        for (const model of agent.topModels.slice(0, 3)) {
          const tag = node("span", null, { class: "wb-flow-tag" });
          tag.append(node("i", null, { class: "wb-dot wb-dot-sm", style: `background: ${model.colorHex};` }), node("span", model.displayName, { class: "wb-flow-name" }), node("span", `(${model.totalTokensText})`, { class: "wb-flow-dim" }));
          tags.append(tag);
        }
        row.append(node("span", "⚡️ 主要消耗模型:", { class: "wb-detail-label" }), tags);
        detail.append(row);
      }
      group.append(detail);
    }
    return group;
  }

  // MARK: Token 构成与今日时段 (mac TokenCompositionCard)

  function drawComposition() {
    const { kpi, todayHourlyTokens: hours } = workbench.snapshot;
    const card = node("section", null, { class: "fluent-card wb-card composition-card" });
    card.append(cardHeader("Token 构成与时段", "Prompt Cache 专项分析", "var(--ok)", "所选范围的输入、输出与缓存读写结构，以及今日 24 小时活跃分布"));
    const grid = node("div", null, { class: "composition-grid" });
    const quadrants = [
      ["Prompt Input", "用户提示词与工程上下文", kpi.inputTokensText, "输入基础", "#4C9CFF"],
      ["Model Output", "大模型生成与代码产出", kpi.outputTokensText, "高单价", "#A855F7"],
      ["Prompt Cache Read", `命中率 ${kpi.cacheHitRateText} · ${kpi.cacheSavedCostText}`, kpi.cacheReadTokensText, "已节省", "#10B981"],
      ["Cache Creation", "写入提示缓存的上下文", kpi.cacheCreationTokensText, "写入", "#F59E0B"],
    ];
    for (const [title, sub, value, tag, color] of quadrants) {
      const box = node("div", null, { class: "composition-box", style: `--chip: ${color};` });
      const head = node("div", null, { class: "kpi-head" });
      head.append(node("span", title, { class: "composition-box-label" }), chip(tag, color));
      box.append(head, node("div", value, { class: "composition-box-value" }), node("div", sub, { class: "composition-box-sub", title: sub }));
      grid.append(box);
    }
    card.append(grid, node("div", null, { class: "wb-divider" }));

    const heat = node("div", null, { class: "wb-hours" });
    const head = node("div", null, { class: "wb-hours-head" });
    const probe = node("span", null, { class: "wb-hours-probe", id: "wb-hours-probe" });
    head.append(node("span", "今日 24 小时交互密度 (00:00 - 23:00)", { class: "wb-hours-title" }), node("span", null, { class: "wb-spacer" }), probe);
    const peak = Math.max(1, ...hours);
    const cells = node("div", null, { class: "wb-hour-cells" });
    const showProbe = () => {
      const hour = workbench.hoveredHour;
      probe.textContent = hour == null ? "鼠标悬停查看单时段用量" : `📍 ${String(hour).padStart(2, "0")}:00 : ${tokenCount(hours[hour] || 0)} Tokens`;
      probe.className = hour == null ? "wb-hours-probe" : "wb-hours-probe on";
    };
    hours.forEach((value, hour) => {
      const cell = node("i", null, {
        class: value ? "wb-hour" : "wb-hour zero",
        // mac accent.opacity(0.25 + 0.75 × 强度): 只作用于填充, 悬停描边不随之变淡
        style: value ? `background: color-mix(in srgb, var(--settings-accent) ${(25 + 75 * (value / peak)).toFixed(1)}%, transparent);` : "",
        title: `${String(hour).padStart(2, "0")}:00`,
      });
      cell.addEventListener("mouseenter", () => { workbench.hoveredHour = hour; showProbe(); });
      cell.addEventListener("mouseleave", () => { workbench.hoveredHour = null; showProbe(); });
      cells.append(cell);
    });
    const ticks = node("div", null, { class: "wb-hour-ticks" });
    for (const label of ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00", "23:00"]) ticks.append(node("span", label));
    heat.append(head, cells, ticks);
    card.append(heat);
    fillSlot("composition", card);
    showProbe();
  }

  function renderSessionProbes() {
    const host = byId("session-probes");
    if (!host) return;
    host.replaceChildren();

    const diagnostics = coreState.currentRuntimeInfo?.diagnostics || [];
    const usage = coreState.currentRuntimeInfo?.usage;
    const activeAgents = new Set((usage?.breakdown || []).map(b => b.agentId || b.label));

    for (const probe of SESSION_PROBES) {
      const line = node("div", null, { class: "probe-row" });
      const meta = node("div", null, { class: "probe-meta" });
      meta.append(node("span", probe.name, { class: "probe-name" }));
      meta.append(node("span", probe.sub, { class: "probe-sub" }));
      line.append(meta);

      const diag = diagnostics.find(d => d.agentId === probe.id || d.module === probe.id);
      const hasUsage = activeAgents.has(probe.id) || activeAgents.has(probe.name);

      let statusText = "就绪";
      let statusCls = "status-tag ok";

      if (diag) {
        if (diag.note && diag.note.includes("未发现会话")) {
          statusText = "未发现会话记录";
          statusCls = "status-tag neutral";
        } else if (diag.status === "not_found" || diag.status === "missing") {
          statusText = "未安装";
          statusCls = "status-tag neutral";
        } else if (diag.status === "unauthorized") {
          statusText = "未授权";
          statusCls = "status-tag warn";
        } else if (diag.note) {
          statusText = diag.note;
          statusCls = "status-tag neutral";
        }
      } else if (!hasUsage) {
        statusText = "未发现会话记录";
        statusCls = "status-tag neutral";
      }

      line.append(node("span", statusText, { class: statusCls }));
      host.append(line);
    }
  }

  // MARK: - 模型计费 (对齐 mac ModelPricingSettingsView)


  Object.assign(window.BruceSettingsSections, {
    buildAgentUsage, fixedEven, tokenCount, chip, markdownLine,
    segButtons, cardHeader, expandButton, renderAgentUsageWorkbench, drawWorkbench,
    fillSlot, workbenchToolbar, kpiTiles, chartSeries, niceTicks,
    axisLabel, drawTimeline, timelineChart, drawTimelineSummary, drawModels,
    modelRow, drawAgents, agentRow, drawComposition, renderSessionProbes,
  });
})();
