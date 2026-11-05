/* ============================================================
   BRUCE — official site
   data.js : one coherent sample dataset for every figure.
   Numbers follow the app's own sample (panel-spec.md §5); the
   formatters follow PanelFormat / UsageMapping.
   ============================================================ */
(function () {
  "use strict";

  /* ---------- 26-week heatmap: 0–5 scale, nulls after today ---- */
  var WEEKS = [
    [4, 4, 3, 2, 4, 2, 2], [4, 3, 4, 3, 4, 2, 2], [3, 4, 3, 3, 4, 2, 2],
    [3, 4, 4, 3, 3, 2, 1], [2, 3, 4, 3, 3, 2, 2], [2, 4, 4, 4, 4, 2, 2],
    [2, 3, 4, 3, 3, 1, 2], [3, 4, 3, 4, 4, 1, 2], [4, 4, 3, 3, 4, 1, 2],
    [4, 4, 3, 3, 4, 0, 0], [0, 3, 3, 4, 4, 2, 1], [3, 3, 2, 4, 2, 2, 2],
    [3, 4, 3, 3, 3, 2, 1], [3, 2, 3, 4, 4, 1, 2], [3, 4, 4, 4, 2, 2, 1],
    [3, 4, 4, 2, 4, 2, 2], [3, 3, 4, 3, 4, 1, 0], [3, 2, 4, 3, 4, 2, 2],
    [4, 4, 4, 3, 3, 2, 2], [4, 3, 4, 3, 3, 2, 2], [4, 4, 4, 4, 3, 1, 2],
    [4, 2, 3, 4, 3, 2, 1], [3, 4, 4, 4, 3, 1, 2], [3, 4, 4, 4, 4, 2, 2],
    [4, 3, 4, 4, 4, 2, 2], [4, 3, 5, null, null, null, null],
  ];

  var DAY_MS = 86400000;
  var HEAT_START = new Date(2026, 4, 11); /* Monday 11 May 2026 */
  var HEAT_END = new Date(2026, 10, 4); /* Wednesday 4 Nov 2026 */

  var heatCells = [];
  WEEKS.forEach(function (week, w) {
    week.forEach(function (level, d) {
      if (level === null) return;
      heatCells.push({
        level: level,
        date: new Date(HEAT_START.getTime() + (w * 7 + d) * DAY_MS),
      });
    });
  });

  /* ---------- agents & 14 days ---------------------------------- */
  var agentSeries = [
    { id: "kimi-code-cli", name: "Kimi Code", color: "#0a84ff" },
    { id: "claude-code", name: "Claude Code", color: "#ff7a59" },
    { id: "codex", name: "Codex", color: "#bf5af2" },
    { id: "kimi-work", name: "Kimi Work", color: "#5ac8fa" },
    { id: "grok", name: "Grok", color: "#6c63ff" },
    { id: "opencode", name: "OpenCode", color: "#30d158" },
  ];

  var dailyRaw = [
    ["2026-10-22", [172.1, 98.0, 63.3, 42.8]],
    ["2026-10-23", [158.6, 90.3, 58.3, 39.4]],
    ["2026-10-24", [81.1, 46.3, 29.9, 20.2]],
    ["2026-10-25", [83.5, 47.5, 30.7, 20.7]],
    ["2026-10-26", [149.1, 85.0, 54.8, 37.1]],
    ["2026-10-27", [112.5, 64.1, 41.3, 27.9]],
    ["2026-10-28", [138.7, 79.0, 51.0, 34.5]],
    ["2026-10-29", [175.3, 99.8, 64.4, 43.6]],
    ["2026-10-30", [162.8, 92.7, 59.8, 40.4]],
    ["2026-10-31", [51.5, 29.3, 18.9, 12.8]],
    ["2026-11-01", [74.9, 42.7, 27.6, 18.6]],
    ["2026-11-02", [179.7, 102.3, 66.0, 44.6]],
    ["2026-11-03", [126.9, 72.3, 46.7, 31.5]],
    ["2026-11-04", [268.4, 152.9, 98.7, 66.6]],
  ];

  var SHARES = [0.36, 0.22, 0.16, 0.11, 0.09, 0.06];
  var bars = dailyRaw.map(function (d) {
    var dayTotal = d[1].reduce(function (a, b) { return a + b; }, 0) * 1e6;
    var parts = agentSeries.map(function (a, i) {
      return { id: a.id, color: a.color, tokens: dayTotal * SHARES[i] };
    });
    return {
      date: new Date(d[0] + "T00:00:00"),
      parts: parts,
      total: parts.reduce(function (a, p) { return a + p.tokens; }, 0),
    };
  });

  var hourlyRaw = [
    [4.2, 2.6, 1.4, 0.8, 0.6, 0.9, 2.1, 5.4, 9.8, 14.6, 18.2, 16.8, 11.4, 12.6, 18.4, 20.8, 21.6, 19.4, 15.2, 13.8, 16.6, 18.2, 14.4, 8.6],
    [0.4, 0.2, 0.1, 0, 0, 0.1, 0.6, 1.8, 4.2, 7.6, 12.4, 9.2, 5.8, 6.4, 9.6, 13.8, 15.4, 13.4, 10.1, 7.2, 9.4, 12.6, 8.2, 4.4],
    [0.1, 0, 0, 0, 0, 0, 0.3, 1.2, 2.8, 5.2, 7.4, 7.2, 3.8, 4.2, 6.8, 8.4, 10.5, 8.2, 5.4, 4.6, 6.2, 7.8, 5.4, 3.2],
    [0.2, 0.1, 0, 0, 0, 0.1, 0.4, 1.4, 3.2, 4.8, 5.6, 5.2, 3.4, 3.6, 4.8, 5.4, 6.2, 5.8, 3.5, 2.8, 3.2, 3.0, 2.0, 1.9],
  ];

  var scale4 = hourlyRaw.slice(0, 4).map(function (pts) {
    return pts.map(function (v) { return v * 0.9; });
  });
  var grokPts = hourlyRaw[2].map(function (v) { return v * (38 / 98.7); });
  var openPts = hourlyRaw[3].map(function (v) { return v * (20 / 66.6); });
  hourlyRaw = scale4.concat([grokPts, openPts]);

  var hourly = agentSeries.map(function (a, i) {
    return {
      id: a.id,
      name: a.name,
      color: a.color,
      total: 0,
      points: hourlyRaw[i].map(function (v) { return v * 1e6; }),
    };
  });
  hourly.forEach(function (h) {
    h.total = h.points.reduce(function (x, y) { return x + y; }, 0);
  });

  /* ---------- subscriptions -------------------------------------- */
  var subscriptions = {
    updated: "最后更新 17:13",
    sections: [
      {
        id: "kimi",
        icon: "kimi",
        name: "Kimi",
        color: "#0a84ff",
        monogram: "K",
        windows: [
          { k: "每 5 小时", used: 68, reset: "15:00" },
          { k: "每周", used: 39, reset: "3 天后" },
          { k: "每月", used: 52, reset: "18 天后" },
        ],
      },
      {
        id: "codex",
        icon: "openai-icon",
        name: "ChatGPT",
        color: "#10a37f",
        monogram: "C",
        accounts: [
          {
            name: "sivan…",
            tag: "International",
            windows: [
              { k: "每 5 小时", used: 57, reset: "16:00" },
              { k: "每周", used: 96, reset: "2 天后" },
            ],
          },
          {
            name: "work…",
            windows: [
              { k: "每 5 小时", used: 92, reset: "13:30" },
              { k: "每周", used: 36, reset: "4 天后" },
            ],
          },
        ],
        collapsed: { k: "每 5 小时", used: 92, reset: "13:30" },
        accountCount: 2,
      },
      {
        id: "cline",
        name: "Cline",
        color: "#18181b",
        icon: "cline",
        monogram: "C",
        windows: [
          { k: "5 小时", used: 22, reset: "18:05" },
          { k: "7 天", used: 41, reset: "5 天后" },
          { k: "30 天", used: 64, reset: "23 天后" },
        ],
      },
      {
        id: "claude",
        icon: "claude",
        name: "Claude",
        color: "#d97757",
        monogram: "C",
        windows: [
          { k: "每 5 小时", used: 43, reset: "17:40" },
          { k: "每周", used: 61, reset: "4 天后" },
        ],
      },
      {
        id: "zhipu",
        icon: "zai-mark",
        name: "Z.ai",
        color: "#2d2d2d",
        monogram: "Z",
        windows: [
          { k: "每 5 小时", used: 12, reset: "16:20" },
          { k: "每周", used: 88, reset: "2 天后" },
        ],
      },
      {
        id: "grok",
        icon: "grok-icon",
        name: "Grok",
        color: "#111111",
        monogram: "G",
        windows: [{ k: "每月", used: 35, reset: "12 天后" }],
      },
      {
        id: "deepseek",
        icon: "deepseek",
        name: "DeepSeek",
        color: "#4d6bfe",
        monogram: "D",
        balance: 38.21,
        status: "正常",
        payAsYouGo: true,
      },
    ],
  };

  /* ---------- section 05 credit lists ---------------------------- */
  var agentSources = [
    "Kimi Work",
    "Kimi Code CLI",
    "Claude Code",
    "Codex",
    "Grok",
    "OpenCode",
    "Pi",
    "ZCode",
    "CodeBuddy",
    "DeepSeek Harness",
  ];

  var providerSources = [
    { name: "Kimi", tag: "5 小时 · 每周" },
    { name: "DeepSeek", tag: "按量付费" },
    { name: "Volcengine", tag: "5 小时 · 每周 · 每月" },
    { name: "Codex", tag: "多账号" },
    { name: "Claude", tag: "5 小时 · 每周" },
    { name: "Grok", tag: "每月" },
    { name: "OpenCode Go", tag: "5 小时 · 每周 · 每月" },
    { name: "Z.ai", tag: "5 小时 · 每周" },
    { name: "StepFun", tag: "按量付费" },
    { name: "Cline", tag: "5 小时 · 7 天 · 30 天" },
  ];

  /* ---------- pricing rows, from the built-in catalog ------------ */
  var pricing = [
    { id: "claude-fable-5-1", name: "Claude Fable 5.1", vendor: "Anthropic", tile: "#f2eee6", mark: "#d97757", mono: "C", inn: 10, out: 50, cache: 0.25, used: 41.2e6 },
    { id: "gpt-6.1-sol", name: "GPT-6.1 Sol", vendor: "OpenAI / Codex", tile: "#ffffff", mark: "#0b0b0b", mono: "G", inn: 2, out: 10, cache: 0.1, used: 126.8e6 },
    { id: "k3", name: "Kimi K3", vendor: "Moonshot Kimi", tile: "#0b0b0b", mark: "#ffffff", mono: "K", inn: 3, out: 15, cache: 0.3, used: 208.4e6 },
    { id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", vendor: "DeepSeek", tile: "#ffffff", mark: "#4d6bfe", mono: "D", inn: 0.3, out: 1.2, cache: 0.006, used: 152.9e6 },
    { id: "glm-5.3", name: "GLM-5.3", vendor: "Zhipu", tile: "#ffffff", mark: "#1f63ec", mono: "G", inn: 1.4, out: 4.4, cache: 0.26, used: 33.1e6 },
    { id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", vendor: "Google", tile: "#ffffff", mark: "#0b0b0b", mono: "G", inn: 0.1, out: 0.4, cache: 0.025, used: 24.2e6 },
  ];

  window.BRUCE_DATA = {
    updated: "17:13",
    agentsActive: 3,
    token: {
      total: 586.6e6,
      input: 18.4e6,
      output: 1.7e6,
      cacheRead: 566.5e6,
      cacheCreation: 0,
      hitRate: 97,
      cost: 334.146,
      tier: "forest",
      live: true,
      halfYear: "44.33B",
      monthlyAvg: "7.39B",
      months: [
        { k: "6月", v: "7.38B", current: false },
        { k: "7月", v: "7.35B", current: false },
        { k: "8月", v: "7.10B", current: false },
        { k: "9月", v: "7.71B", current: false },
        { k: "10月", v: "7.97B", current: false },
        { k: "11月", v: "1.42B", current: true },
      ],
    },
    heatmap: { weeks: WEEKS, cells: heatCells, start: HEAT_START, end: HEAT_END },
    hourly: { agents: agentSeries, bars: bars, hourly: hourly },
    subscriptions: subscriptions,
    sources: { agents: agentSources, providers: providerSources },
    pricing: pricing,
  };
})();
