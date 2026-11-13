// 05 用量分析：Bruce「设置 › 模型用量」工作台 1:1 交互还原
(function () {
  "use strict";

  var host = document.getElementById("analysis-workbench");
  if (!host) return;

  var TIME_RANGES = [
    { key: "today", label: "今日", spanText: "今日 24 小时逐时统计（00:00 – 23:00）" },
    { key: "7d", label: "近 7 天", spanText: "按日汇总（10 月 29 日 – 11 月 4 日）" },
    { key: "30d", label: "近 30 天", spanText: "按日汇总（10 月 6 日 – 11 月 4 日）" },
    { key: "month", label: "本月", spanText: "按日汇总（11 月 1 日 – 11 月 4 日）" },
    { key: "all", label: "全部历史", spanText: "按月汇总（2026 年 5 月 – 11 月）" },
  ];

  var AGENTS_META = {
    "claude-code": {
      id: "claude-code",
      name: "Claude Code",
      color: "#D97757",
      tile: "#F2EEE6",
      mark: "#D97757",
      mono: "C",
      glyph: "claude",
      projects: ["bruce-app", "website-redesign", "rust-collector"],
      models: ["claude-sonnet-4-6", "claude-opus-4-6"],
    },
    "kimi-code-cli": {
      id: "kimi-code-cli",
      name: "Kimi Code",
      color: "#0A84FF",
      tile: "#0B0B0B",
      mark: "#FFFFFF",
      mono: "K",
      glyph: "kimi",
      projects: ["bruce-app", "agent-normalizer", "pricing-sync"],
      models: ["kimi-k3"],
    },
    codex: {
      id: "codex",
      name: "Codex",
      color: "#10A37F",
      tile: "#0A0A0A",
      mark: "#FFFFFF",
      mono: "X",
      glyph: "codex",
      projects: ["mihomo-guard", "bruce-win-shell", "ci-verify"],
      models: ["gpt-5-3-codex", "claude-sonnet-4-6"],
    },
    opencode: {
      id: "opencode",
      name: "OpenCode",
      color: "#8A63D2",
      tile: "#1C1C1E",
      mark: "#CFCECD",
      mono: "O",
      glyph: "opencode",
      projects: ["provider-probes", "website-redesign"],
      models: ["claude-sonnet-4-6", "kimi-k3", "gpt-5-3-codex"],
    },
    dsh: {
      id: "dsh",
      name: "DSH",
      color: "#4D6BFE",
      tile: "#FFFFFF",
      mark: "#4D6BFE",
      mono: "D",
      glyph: "deepseek",
      projects: ["zstd-parser", "batch-eval"],
      models: ["deepseek-v4-1"],
    },
    grok: {
      id: "grok",
      name: "Grok",
      color: "#6C63FF",
      tile: "#0B0B0B",
      mark: "#FFFFFF",
      mono: "G",
      glyph: "grok",
      projects: ["archive-scripts"],
      models: ["grok-4"],
    },
  };

  var MODELS_META = {
    "claude-sonnet-4-6": {
      key: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      vendor: "Anthropic",
      color: "#D97757",
      tile: "#F2EEE6",
      mark: "#D97757",
      glyph: "claude",
      usdPerM: 0.2793,
      channels: [
        { raw: "claude-sonnet-4-6-20260219", agentId: "claude-code", ratio: 0.7521 },
        { raw: "anthropic/claude-sonnet-4.6", agentId: "opencode", ratio: 0.1595 },
        { raw: "claude-sonnet-4-6@bedrock", agentId: "claude-code", ratio: 0.0884 },
      ],
    },
    "kimi-k3": {
      key: "kimi-k3",
      name: "Kimi K3",
      vendor: "Moonshot",
      color: "#0A84FF",
      tile: "#0B0B0B",
      mark: "#FFFFFF",
      glyph: "kimi",
      usdPerM: 0.1422,
      channels: [
        { raw: "kimi-k3-preview", agentId: "kimi-code-cli", ratio: 0.9439 },
        { raw: "moonshot/kimi-k3-turbo", agentId: "opencode", ratio: 0.0561 },
      ],
    },
    "gpt-5-3-codex": {
      key: "gpt-5-3-codex",
      name: "GPT-5.3 Codex",
      vendor: "OpenAI",
      color: "#10A37F",
      tile: "#0B0B0B",
      mark: "#FFFFFF",
      glyph: "codex",
      usdPerM: 0.2419,
      channels: [
        { raw: "gpt-5.3-codex", agentId: "codex", ratio: 0.9592 },
        { raw: "openai/gpt-5.3-codex-high", agentId: "opencode", ratio: 0.0408 },
      ],
    },
    "claude-opus-4-6": {
      key: "claude-opus-4-6",
      name: "Claude Opus 4.6",
      vendor: "Anthropic",
      color: "#B45309",
      tile: "#F2EEE6",
      mark: "#B45309",
      glyph: "claude",
      usdPerM: 0.3195,
      channels: [{ raw: "claude-opus-4-6", agentId: "claude-code", ratio: 1.0 }],
    },
    "deepseek-v4-1": {
      key: "deepseek-v4-1",
      name: "DeepSeek V4.1",
      vendor: "DeepSeek",
      color: "#4D6BFE",
      tile: "#FFFFFF",
      mark: "#4D6BFE",
      glyph: "deepseek",
      usdPerM: 0.1222,
      channels: [{ raw: "deepseek-chat-v4.1", agentId: "dsh", ratio: 1.0 }],
    },
    "grok-4": {
      key: "grok-4",
      name: "Grok 4",
      vendor: "xAI",
      color: "#6C63FF",
      tile: "#0B0B0B",
      mark: "#FFFFFF",
      glyph: "grok",
      usdPerM: 0.195,
      channels: [{ raw: "grok-4-fast-reasoning", agentId: "grok", ratio: 1.0 }],
    },
  };

  var GLYPHS = {
    claude:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.2l1.1 6.7 5.3-4.3-3.5 5.9 6.8-.9-6 3.1 6 3.1-6.8-.9 3.5 5.9-5.3-4.3L12 21.8l-1.1-6.7-5.3 4.3 3.5-5.9-6.8.9 6-3.1-6-3.1 6.8.9-3.5-5.9 5.3 4.3L12 2.2z" fill="currentColor"/></svg>',
    codex:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.3 10.1a4.7 4.7 0 0 0-.4-3.9 4.8 4.8 0 0 0-5.1-2.3A4.7 4.7 0 0 0 11.3 2a4.8 4.8 0 0 0-4.6 3.3 4.7 4.7 0 0 0-3.2 2.3 4.8 4.8 0 0 0 .6 5.6 4.7 4.7 0 0 0 .4 3.9 4.8 4.8 0 0 0 5.1 2.3A4.7 4.7 0 0 0 13.1 21a4.8 4.8 0 0 0 4.6-3.3 4.7 4.7 0 0 0 3.2-2.3 4.8 4.8 0 0 0-.6-5.3ZM13.1 19.6a3.5 3.5 0 0 1-2.2-.8l.1-.1 3.7-2.1a.6.6 0 0 0 .3-.5v-5.1l1.5.9v4.2a3.5 3.5 0 0 1-3.4 3.5ZM5.7 16.5a3.5 3.5 0 0 1-.4-2.3l.1.1 3.7 2.1a.6.6 0 0 0 .6 0l4.5-2.6v1.8l-3.7 2.1a3.5 3.5 0 0 1-4.8-1.2Zm-1-8.2a3.5 3.5 0 0 1 1.8-1.5v4.4a.6.6 0 0 0 .3.5l4.4 2.5-1.5.9L6 13a3.5 3.5 0 0 1-1.3-4.7Zm12.7 3-4.5-2.6 1.5-.9 3.7 2.1a3.5 3.5 0 0 1-.5 6.3V12a.6.6 0 0 0-.2-.7Zm1.5-2.3-.1-.1-3.7-2.1a.6.6 0 0 0-.6 0L10 9.4V7.6l3.7-2.1a3.5 3.5 0 0 1 5.2 3.5Zm-9.6 3.1-1.5-.9V7a3.5 3.5 0 0 1 5.7-2.7l-.1.1-3.7 2.1a.6.6 0 0 0-.3.5l-.1 5.1Zm.9-1.8 1.9-1.1 1.9 1.1v2.2L12 13.6l-1.9-1.1v-2.2Z" fill="currentColor"/></svg>',
    kimi:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.2 4.5v15M6.2 12.2l7.4-7.4M9.8 11.4l6.8 8.1" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="17.8" cy="6.2" r="1.8" fill="currentColor"/></svg>',
    deepseek:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4.2 14.2c0-3.7 3-6.6 6.8-6.6 2.2 0 4 .9 5.3 2.5.9-1.1 2-2.2 3.3-2.6.5 1.2.1 2.9-.8 4.1.6 1 .9 2.2.8 3.5-.3 3.4-3.3 5.5-7.4 5.5-4.7 0-8-2.6-8-6.4Zm10.6-.4a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4Z" fill-rule="evenodd" fill="currentColor"/></svg>',
    grok:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="7.2" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M5.2 18.8L18.8 5.2" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"/></svg>',
    opencode:
      '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="14" rx="3" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8.5 9.5 11.5 12l-3 2.5M12.5 14.5h3" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  };

  var SESSION_PROBES = [
    { id: "claude-code", name: "Claude Code", path: "~/.claude/projects", status: "ready", label: "就绪" },
    { id: "codex", name: "ChatGPT / Codex", path: "~/.codex/sessions（含 Orca）", status: "ready", label: "就绪" },
    { id: "kimi-code-cli", name: "Kimi Code", path: "~/.kimi/history", status: "ready", label: "就绪" },
    { id: "opencode", name: "OpenCode", path: "~/.local/share/opencode", status: "ready", label: "就绪" },
    { id: "dsh", name: "DSH", path: "~/.dsh/sessions（zstd JSONL）", status: "ready", label: "就绪" },
    { id: "grok", name: "Grok", path: "~/.grok", status: "empty", label: "未发现会话记录" },
    { id: "pi", name: "Pi", path: "~/.pi/agent/sessions", status: "empty", label: "未发现会话记录" },
    { id: "codebuddy", name: "CodeBuddy", path: "~/.codebuddy/sessions", status: "missing", label: "未安装" },
  ];

  // 今日 24 小时基础总量 (M)，总计精确等于 383.0M（与近 7 天最后一日 11/04 完全衔接）
  var TODAY_HOUR_M = [
    4.2, 2.4, 1.2, 0.4, 0.0, 0.0, 2.0, 5.8,
    12.6, 21.4, 29.8, 25.4, 15.2, 18.6, 28.4, 34.2,
    46.8, 38.6, 24.4, 17.8, 21.2, 18.4, 10.6, 3.6,
  ];

  // 近 7 天每日各 Agent 消耗 (M)，总计 1572.0M (1.57B)；11/04 合计 383.0M
  var SEVEN_DAYS_RAW = [
    { label: "10/29", date: "2026-10-29", byAgent: { "claude-code": 98.4, "kimi-code-cli": 72.1, codex: 46.2, opencode: 24.5, dsh: 8.8 } },
    { label: "10/30", date: "2026-10-30", byAgent: { "claude-code": 91.2, "kimi-code-cli": 66.8, codex: 41.0, opencode: 22.0, dsh: 7.0 } },
    { label: "10/31", date: "2026-10-31", byAgent: { "claude-code": 34.5, "kimi-code-cli": 25.0, codex: 14.2, opencode: 8.8, dsh: 2.5 } },
    { label: "11/1", date: "2026-11-01", byAgent: { "claude-code": 48.0, "kimi-code-cli": 34.4, codex: 21.6, opencode: 11.2, dsh: 3.8 } },
    { label: "11/2", date: "2026-11-02", byAgent: { "claude-code": 118.6, "kimi-code-cli": 84.5, codex: 52.4, opencode: 27.5, dsh: 11.0 } },
    { label: "11/3", date: "2026-11-03", byAgent: { "claude-code": 86.3, "kimi-code-cli": 61.2, codex: 38.6, opencode: 20.4, dsh: 6.5 } },
    { label: "11/4", date: "2026-11-04", byAgent: { "claude-code": 154.0, "kimi-code-cli": 110.0, codex: 68.0, opencode: 36.6, dsh: 14.4 } },
  ];

  // 近 30 天的前 23 天（10/06 – 10/28，十月中旬包含已归档的 Grok 历史用量），后接 SEVEN_DAYS_RAW 构成 30 天
  var EARLIER_23_TOTALS_M = [
    194, 212, 168, 122, 134, 224, 198,
    182, 236, 204, 146, 118, 248, 226,
    188, 262, 240, 138, 116, 254, 272,
    218, 196,
  ];

  var MONTHS_RAW = [
    { label: "05月", byAgent: { "claude-code": 980, "kimi-code-cli": 740, codex: 460, opencode: 210, dsh: 90, grok: 210 } },
    { label: "06月", byAgent: { "claude-code": 1190, "kimi-code-cli": 890, codex: 540, opencode: 260, dsh: 110, grok: 180 } },
    { label: "07月", byAgent: { "claude-code": 1340, "kimi-code-cli": 960, codex: 610, opencode: 310, dsh: 130, grok: 140 } },
    { label: "08月", byAgent: { "claude-code": 1460, "kimi-code-cli": 1080, codex: 690, opencode: 360, dsh: 150, grok: 110 } },
    { label: "09月", byAgent: { "claude-code": 1680, "kimi-code-cli": 1220, codex: 760, opencode: 410, dsh: 160, grok: 65 } },
    { label: "10月", byAgent: { "claude-code": 1920, "kimi-code-cli": 1380, codex: 880, opencode: 455, dsh: 175, grok: 34 } },
    { label: "11月", byAgent: { "claude-code": 406.9, "kimi-code-cli": 290.1, codex: 180.6, opencode: 95.7, dsh: 35.7, grok: 0 } },
  ];

  var AGENT_COLORS_BY_ID = Object.keys(AGENTS_META).reduce(function (acc, k) {
    acc[k] = AGENTS_META[k].color;
    return acc;
  }, {});

  function buildRangeBuckets(rangeKey) {
    if (rangeKey === "today") {
      // 各时段按主力 5 个 Agent 分配比例（Claude 40.2%, Kimi 28.7%, Codex 17.8%, OpenCode 9.6%, DSH 3.7% = 100%）
      return TODAY_HOUR_M.map(function (m, h) {
        var lbl = (h < 10 ? "0" : "") + h + ":00";
        if (m === 0) {
          return { label: lbl, byAgent: { "claude-code": 0, "kimi-code-cli": 0, codex: 0, opencode: 0, dsh: 0 } };
        }
        return {
          label: lbl,
          byAgent: {
            "claude-code": +(m * 0.4021).toFixed(2),
            "kimi-code-cli": +(m * 0.2872).toFixed(2),
            codex: +(m * 0.1775).toFixed(2),
            opencode: +(m * 0.0956).toFixed(2),
            dsh: +(m * 0.0376).toFixed(2),
          },
        };
      });
    }
    if (rangeKey === "7d") {
      return SEVEN_DAYS_RAW.map(function (d) {
        return { label: d.label, byAgent: Object.assign({}, d.byAgent) };
      });
    }
    if (rangeKey === "month") {
      return SEVEN_DAYS_RAW.slice(3).map(function (d) {
        return { label: d.label, byAgent: Object.assign({}, d.byAgent) };
      });
    }
    if (rangeKey === "30d") {
      var prefix = EARLIER_23_TOTALS_M.map(function (totalM, i) {
        var dayNum = 6 + i;
        var grokShare = i < 12 ? 0.025 : 0.0;
        var remain = 1 - grokShare;
        return {
          label: "10/" + dayNum,
          byAgent: {
            "claude-code": +(totalM * remain * 0.402).toFixed(2),
            "kimi-code-cli": +(totalM * remain * 0.289).toFixed(2),
            codex: +(totalM * remain * 0.179).toFixed(2),
            opencode: +(totalM * remain * 0.096).toFixed(2),
            dsh: +(totalM * remain * 0.034).toFixed(2),
            grok: +(totalM * grokShare).toFixed(2),
          },
        };
      });
      return prefix.concat(
        SEVEN_DAYS_RAW.map(function (d) {
          return {
            label: d.label,
            byAgent: Object.assign({ grok: 0 }, d.byAgent),
          };
        })
      );
    }
    return MONTHS_RAW.map(function (m) {
      return { label: m.label, byAgent: Object.assign({}, m.byAgent) };
    });
  }

  function buildRangeData(rangeKey) {
    var buckets = buildRangeBuckets(rangeKey);
    var agentTotals = {};
    var pointTotals = [];
    var grandM = 0;

    buckets.forEach(function (b) {
      var sum = 0;
      Object.keys(b.byAgent).forEach(function (aid) {
        var v = b.byAgent[aid] || 0;
        sum += v;
        agentTotals[aid] = (agentTotals[aid] || 0) + v;
      });
      pointTotals.push(sum);
      grandM += sum;
    });

    // 模型归并：依据每名 Agent 消耗的真实跨模型权重分拆（保证跨模型总和精确等于 grandM）
    var modelTotals = {
      "claude-sonnet-4-6": 0,
      "kimi-k3": 0,
      "gpt-5-3-codex": 0,
      "claude-opus-4-6": 0,
      "deepseek-v4-1": 0,
      "grok-4": 0,
    };

    var ccM = agentTotals["claude-code"] || 0;
    var kmM = agentTotals["kimi-code-cli"] || 0;
    var cxM = agentTotals.codex || 0;
    var ocM = agentTotals.opencode || 0;
    var dsM = agentTotals.dsh || 0;
    var gkM = agentTotals.grok || 0;

    // 精确拆分：Claude Code (93.5% Sonnet 4.6 + 6.5% Opus 4.6), OpenCode (74.17% Sonnet + 17.88% Kimi + 7.95% GPT), Codex (100% GPT-5.3), Kimi (100% Kimi K3), DSH (100% DeepSeek V4.1), Grok (100% Grok 4)
    var ccSonnet = +(ccM * 0.935).toFixed(2);
    var ccOpus = +(ccM - ccSonnet).toFixed(2);
    var ocSonnet = +(ocM * 0.7417).toFixed(2);
    var ocKimi = +(ocM * 0.1788).toFixed(2);
    var ocGpt = +(ocM - ocSonnet - ocKimi).toFixed(2);

    modelTotals["claude-sonnet-4-6"] = ccSonnet + ocSonnet;
    modelTotals["kimi-k3"] = kmM + ocKimi;
    modelTotals["gpt-5-3-codex"] = cxM + ocGpt;
    modelTotals["claude-opus-4-6"] = ccOpus;
    modelTotals["deepseek-v4-1"] = dsM;
    modelTotals["grok-4"] = gkM;

    var ccSonnetDirect = +(ccSonnet * 0.895).toFixed(2);
    var ccSonnetBedrock = +(ccSonnet - ccSonnetDirect).toFixed(2);

    var channelRecords = [
      { key: "claude-sonnet-4-6", raw: "claude-sonnet-4-6-20260219", agentId: "claude-code", m: ccSonnetDirect },
      { key: "claude-sonnet-4-6", raw: "anthropic/claude-sonnet-4.6", agentId: "opencode", m: ocSonnet },
      { key: "claude-sonnet-4-6", raw: "claude-sonnet-4-6@bedrock", agentId: "claude-code", m: ccSonnetBedrock },
      { key: "kimi-k3", raw: "kimi-k3-preview", agentId: "kimi-code-cli", m: kmM },
      { key: "kimi-k3", raw: "moonshot/kimi-k3-turbo", agentId: "opencode", m: ocKimi },
      { key: "gpt-5-3-codex", raw: "gpt-5.3-codex", agentId: "codex", m: cxM },
      { key: "gpt-5-3-codex", raw: "openai/gpt-5.3-codex-high", agentId: "opencode", m: ocGpt },
      { key: "claude-opus-4-6", raw: "claude-opus-4-6", agentId: "claude-code", m: ccOpus },
      { key: "deepseek-v4-1", raw: "deepseek-chat-v4.1", agentId: "dsh", m: dsM },
      { key: "grok-4", raw: "grok-4-fast-reasoning", agentId: "grok", m: gkM },
    ].filter(function (c) {
      return c.m > 0.05;
    });

    var models = Object.keys(MODELS_META)
      .filter(function (mk) {
        return modelTotals[mk] > 0.05;
      })
      .map(function (mk) {
        var meta = MODELS_META[mk];
        var mVal = modelTotals[mk];
        var cost = mVal * meta.usdPerM;
        var sources = channelRecords
          .filter(function (c) {
            return c.key === mk;
          })
          .map(function (c) {
            return {
              raw: c.raw,
              agentId: c.agentId,
              agentName: AGENTS_META[c.agentId].name,
              tokensM: c.m,
              cost: c.m * meta.usdPerM,
              shareOfModel: mVal > 0 ? (c.m / mVal) * 100 : 0,
            };
          })
          .sort(function (a, b) {
            return b.tokensM - a.tokensM;
          });
        return {
          key: mk,
          name: meta.name,
          vendor: meta.vendor,
          color: meta.color,
          tile: meta.tile,
          mark: meta.mark,
          glyph: meta.glyph,
          tokensM: mVal,
          cost: cost,
          share: grandM > 0 ? (mVal / grandM) * 100 : 0,
          sources: sources,
        };
      })
      .sort(function (a, b) {
        return b.tokensM - a.tokensM;
      });

    var rawChannels = channelRecords
      .map(function (c) {
        var meta = MODELS_META[c.key];
        return {
          raw: c.raw,
          agentId: c.agentId,
          agentName: AGENTS_META[c.agentId].name,
          tokensM: c.m,
          cost: c.m * meta.usdPerM,
        };
      })
      .sort(function (a, b) {
        return b.tokensM - a.tokensM;
      });

    var totalCost = models.reduce(function (s, m) {
      return s + m.cost;
    }, 0);

    // Token 构成比例与各 Agent 明细一致：Prompt 3.27%，Output 0.37%，Cache Read 96.36%，Cache Creation 2.71%
    var inputM = +(grandM * 0.0327).toFixed(2);
    var outputM = +(grandM * 0.0037).toFixed(2);
    var cacheReadM = +(grandM - inputM - outputM).toFixed(2);
    var cacheCreateM = +(grandM * 0.0271).toFixed(2);
    var cacheHitRate = inputM + cacheReadM > 0 ? Math.round((cacheReadM / (inputM + cacheReadM)) * 100) : 0;
    var cacheSaved = totalCost * 4.29;

    var agentList = Object.keys(agentTotals)
      .filter(function (aid) {
        return agentTotals[aid] > 0.05;
      })
      .map(function (aid) {
        var meta = AGENTS_META[aid];
        var mVal = agentTotals[aid];
        var ratio = grandM > 0 ? mVal / grandM : 0;
        var aIn = +(mVal * 0.0327).toFixed(2);
        var aOut = +(mVal * 0.0037).toFixed(2);
        var aCache = +(mVal - aIn - aOut).toFixed(2);
        var isHist = aid === "grok";
        var modelUsages = Object.keys(MODELS_META)
          .map(function (mk) {
            var chSum = channelRecords
              .filter(function (c) {
                return c.agentId === aid && c.key === mk;
              })
              .reduce(function (s, c) {
                return s + c.m;
              }, 0);
            return chSum > 0.05 ? { key: mk, name: MODELS_META[mk].name, color: MODELS_META[mk].color, tokensM: chSum } : null;
          })
          .filter(Boolean)
          .sort(function (a, b) {
            return b.tokensM - a.tokensM;
          });
        var projWeights = [0.54, 0.31, 0.15];
        var topProjects = meta.projects.map(function (pName, idx) {
          var pw = meta.projects.length === 1 ? 1 : projWeights[idx] || 0.2;
          return { name: pName, tokensM: +(mVal * pw).toFixed(2) };
        });
        return {
          id: aid,
          name: meta.name,
          color: meta.color,
          tile: meta.tile,
          mark: meta.mark,
          mono: meta.mono,
          glyph: meta.glyph,
          status: isHist ? "历史" : "活跃",
          note: isHist ? "历史残留记录（已卸载或停用）" : (aid === "claude-code" ? "主力编码 · 缓存命中 97%" : "本机只读自动采集"),
          tokensM: mVal,
          inputM: aIn,
          outputM: aOut,
          cacheReadM: aCache,
          cost: +(totalCost * ratio).toFixed(2),
          share: ratio * 100,
          topProjects: topProjects,
          topModels: modelUsages,
        };
      })
      .sort(function (a, b) {
        return b.tokensM - a.tokensM;
      });

    var activeCount = agentList.filter(function (a) {
      return a.status === "活跃";
    }).length;

    // 构造 4 组时序系列（Agent / 模型 / Token 构成 / 费用）
    var seriesAgents = agentList.slice(0, 5).map(function (a) {
      return {
        key: a.id,
        name: a.name,
        color: a.color,
        agentId: a.id,
        values: buckets.map(function (b) {
          return (b.byAgent[a.id] || 0) * 1e6;
        }),
      };
    });

    var seriesModels = models.slice(0, 5).map(function (mod) {
      var ratioOfGrand = grandM > 0 ? mod.tokensM / grandM : 0;
      return {
        key: "model_" + mod.key,
        name: mod.name,
        color: mod.color,
        modelKey: mod.key,
        values: buckets.map(function (b) {
          var bSum = Object.keys(b.byAgent).reduce(function (s, aid) {
            return s + (b.byAgent[aid] || 0);
          }, 0);
          // 利用轻微真实斜率微调让不同模型曲线呈现自然分化
          var drift = mod.key === "claude-sonnet-4-6" ? 1.03 : mod.key === "kimi-k3" ? 0.96 : 1.0;
          return bSum * ratioOfGrand * drift * 1e6;
        }),
      };
    });

    var seriesTypes = [
      {
        key: "type_cache",
        name: "缓存读取",
        color: "#10B981",
        values: pointTotals.map(function (v) { return v * 0.9636 * 1e6; }),
      },
      {
        key: "type_input",
        name: "Prompt 输入",
        color: "#4C9CFF",
        values: pointTotals.map(function (v) { return v * 0.0327 * 1e6; }),
      },
      {
        key: "type_create",
        name: "缓存写入",
        color: "#F59E0B",
        values: pointTotals.map(function (v) { return v * 0.0271 * 1e6; }),
      },
      {
        key: "type_output",
        name: "模型输出",
        color: "#A855F7",
        values: pointTotals.map(function (v) { return v * 0.0037 * 1e6; }),
      },
    ];

    var avgCostPerM = grandM > 0 ? totalCost / grandM : 0.22;
    var seriesCost = [
      {
        key: "cost",
        name: "预估费用 (USD)",
        color: "#10B981",
        values: pointTotals.map(function (v) {
          return +(v * avgCostPerM).toFixed(2);
        }),
      },
    ];

    return {
      rangeKey: rangeKey,
      buckets: buckets,
      labels: buckets.map(function (b) { return b.label; }),
      kpi: {
        totalTokensM: grandM,
        avgPerBucketM: buckets.length ? grandM / buckets.length : 0,
        inputM: inputM,
        outputM: outputM,
        cacheReadM: cacheReadM,
        cacheCreateM: cacheCreateM,
        cacheHitRate: cacheHitRate,
        cost: totalCost,
        avgUsdPerM: avgCostPerM,
        cacheSaved: cacheSaved,
        activeCount: activeCount,
        totalAgentCount: agentList.length,
        topAgent: agentList[0] || null,
      },
      series: {
        agent: seriesAgents,
        model: seriesModels,
        type: seriesTypes,
        cost: seriesCost,
      },
      models: models,
      rawChannels: rawChannels,
      agents: agentList,
    };
  }

  /* ---------- state ------------------------------------------------ */
  var state = {
    range: "7d",
    chartType: "area", // 'line' | 'area'
    seriesMode: "agent", // 'agent' | 'model' | 'type' | 'cost'
    hiddenSeries: {}, // key -> true
    zoom: 1,
    pan: 1, // 1 = anchor right (latest dates)
    hoverIdx: null,
    hoveredHour: null,
    modelView: "canonical", // 'canonical' | 'raw'
    expandedModels: { "claude-sonnet-4-6": true },
    expandedAgents: { "claude-code": true },
    exportNotice: null, // { filename, kind, preview, open }
    probing: false,
    probeNote: "可用",
    dataCache: {},
  };

  function getSnapshot() {
    if (!state.dataCache[state.range]) {
      state.dataCache[state.range] = buildRangeData(state.range);
    }
    return state.dataCache[state.range];
  }

  /* ---------- formatters ------------------------------------------- */
  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmtTokens(n) {
    if (!n || n <= 0) return "0";
    if (n < 1e3) return String(Math.round(n));
    if (n < 1e6) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "K";
    if (n < 1e9) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
    return (n / 1e9).toFixed(2) + "B";
  }

  function fmtTokensFromM(m) {
    return fmtTokens(m * 1e6);
  }

  function fmtUsd(n) {
    if (!Number.isFinite(n)) return "$0.00";
    var abs = Math.abs(n);
    var frac = abs > 0 && abs < 0.01 ? 4 : 2;
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: frac, maximumFractionDigits: frac });
  }

  function fmtPct(v) {
    return v >= 10 || v === 0 ? Math.round(v) + "%" : v.toFixed(1) + "%";
  }

  function readAppVersion() {
    var el = document.querySelector(".masthead__meta .ver");
    if (el) {
      var t = el.textContent.trim();
      if (t && t.indexOf("{{") === -1) return t;
    }
    return "预览版";
  }

  function brandBadgeHtml(opts) {
    var size = opts.size || 18;
    var tile = opts.tile || opts.color || "#0A84FF";
    var mark = opts.mark || "#FFFFFF";
    var ring = opts.color ? "box-shadow: 0 0 0 1.5px " + opts.color + ", inset 0 0 0 0.5px rgba(0,0,0,0.08);" : "box-shadow: inset 0 0 0 0.5px rgba(0,0,0,0.1);";
    var glyph = GLYPHS[opts.glyph];
    var inner = glyph ? glyph : '<span style="font-size:' + Math.max(9, Math.round(size * 0.54)) + 'px;font-weight:700">' + esc(opts.mono || "?") + "</span>";
    return (
      '<span class="wb-brand" style="width:' +
      size +
      "px;height:" +
      size +
      "px;background:" +
      tile +
      ";color:" +
      mark +
      ";" +
      ring +
      '" aria-hidden="true">' +
      inner +
      "</span>"
    );
  }

  /* ---------- chart math (1:1 Catmull-Rom + niceTicks) -------------- */
  function niceTicks(maxVal, count) {
    if (!maxVal || maxVal <= 0) return [0, 1, 2, 3];
    var roughStep = maxVal / (count - 1);
    var pow10 = Math.pow(10, Math.floor(Math.log10(roughStep)));
    var norm = roughStep / pow10;
    var niceNorm = norm <= 1.2 ? 1 : norm <= 2.2 ? 2 : norm <= 5.2 ? 5 : 10;
    var step = niceNorm * pow10;
    var ticks = [];
    for (var i = 0; i < count; i++) ticks.push(i * step);
    return ticks;
  }

  function catmullRom(points, baseH) {
    if (!points.length) return { line: "", area: "" };
    if (points.length === 1) {
      var p = points[0];
      return {
        line: "M " + p.x.toFixed(1) + "," + p.y.toFixed(1),
        area: "M " + p.x.toFixed(1) + "," + p.y.toFixed(1) + " L " + p.x.toFixed(1) + "," + baseH + " Z",
      };
    }
    var d = "M " + points[0].x.toFixed(1) + "," + points[0].y.toFixed(1);
    for (var i = 0; i < points.length - 1; i++) {
      var p0 = points[Math.max(0, i - 1)];
      var p1 = points[i];
      var p2 = points[i + 1];
      var p3 = points[Math.min(points.length - 1, i + 2)];
      var cp1x = p1.x + (p2.x - p0.x) / 6;
      var cp1y = Math.max(4, Math.min(baseH, p1.y + (p2.y - p0.y) / 6));
      var cp2x = p2.x - (p3.x - p1.x) / 6;
      var cp2y = Math.max(4, Math.min(baseH, p2.y - (p3.y - p1.y) / 6));
      d += " C " + cp1x.toFixed(1) + "," + cp1y.toFixed(1) + " " + cp2x.toFixed(1) + "," + cp2y.toFixed(1) + " " + p2.x.toFixed(1) + "," + p2.y.toFixed(1);
    }
    var area = d + " L " + points[points.length - 1].x.toFixed(1) + "," + baseH + " L " + points[0].x.toFixed(1) + "," + baseH + " Z";
    return { line: d, area: area };
  }

  function getViewport(totalCount) {
    if (totalCount <= 4 || state.zoom <= 1.001) {
      return { start: 0, end: Math.max(0, totalCount - 1), count: totalCount };
    }
    var visCount = Math.max(4, Math.min(totalCount, Math.round(totalCount / state.zoom)));
    var maxStart = totalCount - visCount;
    var start = Math.round(maxStart * Math.max(0, Math.min(1, state.pan)));
    return { start: start, end: start + visCount - 1, count: visCount };
  }

  /* ---------- render sections -------------------------------------- */
  function renderSidebar() {
    var items = [
      { id: "general", label: "通用", glyph: '<circle cx="7" cy="7" r="2.2"/><path d="M7 1.6v1.4M7 11v1.4M1.6 7H3M11 7h1.4M3.1 3.1l1 1M9.9 9.9l1 1M10.9 3.1l-1 1M4.1 9.9l-1 1"/>' },
      { id: "agentUsage", label: "模型用量", active: true, glyph: '<path d="M2.2 12V8.2M5.6 12V4.6M9 12V6.8M12.4 12V2.6"/><path d="M1.4 12.6h12"/>' },
      { id: "modelPricing", label: "模型计费", glyph: '<circle cx="7" cy="7" r="5.3"/><path d="M7 4v6M8.7 5.2c0-.7-.8-1.2-1.7-1.2s-1.7.5-1.7 1.2.8 1.2 1.7 1.2 1.7.5 1.7 1.2-.8 1.2-1.7 1.2-1.7-.5-1.7-1.2"/>' },
      { id: "subscription", label: "订阅额度", glyph: '<path d="M4.2 10.6a2.3 2.3 0 0 1 .4-4.6 3.2 3.2 0 0 1 6.1-.6 2.1 2.1 0 0 1 .4 4.2H4.6z"/>' },
      { id: "consent", label: "授权与隐私", glyph: '<path d="M7 1.6 2.6 3.3v3.4c0 2.6 1.8 4.6 4.4 5.7 2.6-1.1 4.4-3.1 4.4-5.7V3.3L7 1.6z"/><path d="m5 6.9 1.4 1.5L9.2 5.6"/>' },
      { id: "maintenance", label: "维护", glyph: '<path d="M9.7 1.9a3.1 3.1 0 0 0-3.9 4l-4 4 1.4 1.4 4-4a3.1 3.1 0 0 0 4-3.9l-2 2-1.5-1.5 2-2z"/>' },
    ];
    var navHtml = items
      .map(function (it) {
        var icon = '<svg viewBox="0 0 14 14" aria-hidden="true">' + it.glyph + "</svg>";
        if (it.active) {
          return '<div class="wb-navitem is-active" aria-current="page">' + icon + "<span>" + it.label + "</span></div>";
        }
        return '<div class="wb-navitem is-muted" title="此样张专注展示「模型用量」工作台">' + icon + "<span>" + it.label + "</span></div>";
      })
      .join("");
    return (
      '<aside class="wb-sidebar" aria-label="Bruce 设置导航栏">' +
      '<div class="wb-navlist">' + navHtml + "</div>" +
      '<div class="wb-sidebar__foot"><span>本机只读</span><span>' + esc(readAppVersion()) + "</span></div>" +
      "</aside>"
    );
  }

  function renderToolbar() {
    var rangesHtml = TIME_RANGES.map(function (r) {
      var on = state.range === r.key;
      return (
        '<button type="button" class="wb-seg__btn' + (on ? " is-on" : "") + '" data-wb-range="' + r.key + '" aria-pressed="' + on + '">' +
        r.label +
        "</button>"
      );
    }).join("");

    var dlSvg = '<svg width="12" height="12" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 2v7.2M4.2 6.8 7 9.6l2.8-2.8M2.2 11.8h9.6"/></svg>';

    var noticeHtml = "";
    if (state.exportNotice) {
      var n = state.exportNotice;
      noticeHtml =
        '<div class="wb-export-bar">' +
        '<span class="wb-export-bar__msg">✓ 已生成 <code>' + esc(n.filename) + "</code>（" + esc(n.desc) + "）</span>" +
        '<span class="wb-export-bar__acts">' +
        '<button type="button" class="wb-link-btn" data-wb-exp-toggle>' + (n.open ? "收起内容 ▴" : "预览文件内容 ▾") + "</button>" +
        '<button type="button" class="wb-link-btn is-muted" data-wb-exp-close>关闭</button>' +
        "</span>" +
        (n.open ? '<pre class="wb-export-pre">' + esc(n.preview) + "</pre>" : "") +
        "</div>";
    }

    return (
      '<div class="wb-toolbar">' +
      '<div class="wb-seg" role="group" aria-label="统计时间范围">' + rangesHtml + "</div>" +
      '<div class="wb-toolbar__right">' +
      '<button type="button" class="wb-btn" data-wb-export="csv">' + dlSvg + "<span>导出 CSV 账单</span></button>" +
      '<button type="button" class="wb-btn" data-wb-export="json">' + dlSvg + "<span>导出 JSON 明细</span></button>" +
      "</div>" +
      "</div>" +
      noticeHtml
    );
  }

  function renderKpis(snap) {
    var k = snap.kpi;
    var unitLabel = state.range === "today" ? "时均" : state.range === "all" ? "月均" : "日均";
    var topAgentText = k.topAgent ? "主力 " + k.topAgent.name + " (" + Math.round(k.topAgent.share) + "%)" : "暂无活跃 Agent";
    var tiles = [
      {
        title: "总 Token",
        tag: "Σ",
        color: "#4C9CFF",
        val: fmtTokensFromM(k.totalTokensM),
        sub: unitLabel + " " + fmtTokensFromM(k.avgPerBucketM) + " · 输入 " + fmtTokensFromM(k.inputM) + " / 输出 " + fmtTokensFromM(k.outputM),
      },
      {
        title: "费用",
        tag: "$",
        color: "#10B981",
        val: fmtUsd(k.cost),
        sub: "折合均价 " + fmtUsd(k.avgUsdPerM) + " / 1M",
      },
      {
        title: "缓存收益",
        tag: "⚡",
        color: "#F59E0B",
        val: k.cacheHitRate + "%",
        sub: '<b class="is-ok">已省 ' + fmtUsd(k.cacheSaved) + "</b> · 读取 " + fmtTokensFromM(k.cacheReadM),
        rawSub: true,
      },
      {
        title: "活跃 Agent",
        tag: "◈",
        color: "#A855F7",
        val: k.activeCount + " 个",
        sub: topAgentText,
      },
    ];
    return (
      '<div class="wb-kpis">' +
      tiles
        .map(function (t) {
          return (
            '<div class="wb-kpi">' +
            '<div class="wb-kpi__head"><span>' + t.title + '</span><i class="wb-kpi__ico" style="color:' + t.color + '">' + t.tag + "</i></div>" +
            '<div class="wb-kpi__val num">' + t.val + "</div>" +
            '<div class="wb-kpi__sub">' + (t.rawSub ? t.sub : esc(t.sub)) + "</div>" +
            "</div>"
          );
        })
        .join("") +
      "</div>"
    );
  }

  function renderTimeline(snap) {
    var metaRange = TIME_RANGES.find(function (r) { return r.key === state.range; }) || TIME_RANGES[1];
    var allSeries = snap.series[state.seriesMode] || [];
    var visibleSeries = allSeries.filter(function (s) {
      return !state.hiddenSeries[s.key];
    });
    if (!visibleSeries.length) visibleSeries = allSeries;

    var totalPts = snap.labels.length;
    var vp = getViewport(totalPts);
    var sliceLabels = snap.labels.slice(vp.start, vp.end + 1);
    var sliceSeries = visibleSeries.map(function (s) {
      return {
        key: s.key,
        name: s.name,
        color: s.color,
        values: s.values.slice(vp.start, vp.end + 1),
      };
    });

    // 视图内峰值索引与总值（用于 X 轴 🔥 峰值胶囊 + 多系列合集排序）
    var combinedPerIdx = sliceLabels.map(function (_, i) {
      return sliceSeries.reduce(function (acc, s) {
        return acc + (s.values[i] || 0);
      }, 0);
    });
    var peakLocalIdx = 0;
    var peakSumVal = -1;
    combinedPerIdx.forEach(function (v, idx) {
      if (v > peakSumVal) {
        peakSumVal = v;
        peakLocalIdx = idx;
      }
    });
    var peakDomSeries = sliceSeries.reduce(function (best, s) {
      if (!best || (s.values[peakLocalIdx] || 0) > (best.values[peakLocalIdx] || 0)) return s;
      return best;
    }, sliceSeries[0]);

    var singleMax = 1;
    sliceSeries.forEach(function (s) {
      s.values.forEach(function (v) {
        if (v > singleMax) singleMax = v;
      });
    });

    var yTicks = niceTicks(singleMax, 4);
    var yTop = Math.max(1e-6, yTicks[yTicks.length - 1]);

    var W = 1000;
    var H = 200;
    var PAD_T = 12;
    var PAD_B = 8;
    var plotW = W;
    var plotH = H - PAD_T - PAD_B;
    var baseY = PAD_T + plotH;

    var isCost = state.seriesMode === "cost";
    var fmtVal = function (v) {
      return isCost ? fmtUsd(v) : fmtTokens(v);
    };
    var fmtAxisVal = function (v) {
      if (!v) return "0";
      if (!isCost) return fmtTokens(v);
      return v >= 10 ? "$" + Math.round(v) : fmtUsd(v);
    };

    var yAxisHtml = "";
    var gridHtml = "";
    yTicks.forEach(function (tk) {
      var y = baseY - (tk / yTop) * plotH;
      var yPct = ((y / H) * 100).toFixed(2);
      gridHtml += '<line x1="0" y1="' + y.toFixed(1) + '" x2="' + W + '" y2="' + y.toFixed(1) + '" class="wb-grid-line" vector-effect="non-scaling-stroke" />';
      yAxisHtml += '<span class="wb-ylabel" style="top:' + yPct + '%">' + fmtAxisVal(tk) + "</span>";
    });

    var nPts = sliceLabels.length;
    var xAt = function (i) {
      if (nPts <= 1) return plotW / 2;
      return (i / (nPts - 1)) * plotW;
    };
    var yAt = function (v) {
      return Math.max(PAD_T, Math.min(baseY, baseY - (v / yTop) * plotH));
    };

    var defsHtml = "<defs>";
    var pathsHtml = "";
    var dotsHtml = "";
    sliceSeries.forEach(function (s, sIdx) {
      var pts = s.values.map(function (v, i) {
        return { x: xAt(i), y: yAt(v) };
      });
      var geo = catmullRom(pts, baseY);
      var gradId = "wb-grad-" + state.range + "-" + state.seriesMode + "-" + sIdx;
      defsHtml +=
        '<linearGradient id="' + gradId + '" x1="0" y1="0" x2="0" y2="1">' +
        '<stop offset="0%" stop-color="' + s.color + '" stop-opacity="0.28"/>' +
        '<stop offset="100%" stop-color="' + s.color + '" stop-opacity="0.02"/>' +
        "</linearGradient>";
      if (state.chartType === "area" && geo.area) {
        pathsHtml += '<path d="' + geo.area + '" fill="url(#' + gradId + ')" class="wb-series-area"/>';
      }
      if (geo.line) {
        pathsHtml += '<path d="' + geo.line + '" fill="none" stroke="' + s.color + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" class="wb-series-line"/>';
      }
      if (nPts <= 14) {
        pts.forEach(function (pt, i) {
          var active = state.hoverIdx === i;
          dotsHtml +=
            '<i class="wb-pt' + (active ? " is-active" : "") + '" style="left:' + ((pt.x / W) * 100).toFixed(2) + "%;top:" + ((pt.y / H) * 100).toFixed(2) + "%;--pt:" + s.color + '"></i>';
        });
      } else if (state.hoverIdx != null && pts[state.hoverIdx]) {
        var hpt = pts[state.hoverIdx];
        dotsHtml +=
          '<i class="wb-pt is-active" style="left:' + ((hpt.x / W) * 100).toFixed(2) + "%;top:" + ((hpt.y / H) * 100).toFixed(2) + "%;--pt:" + s.color + '"></i>';
      }
    });
    defsHtml += "</defs>";

    var hoverHtml = "";
    if (state.hoverIdx != null && state.hoverIdx >= 0 && state.hoverIdx < nPts) {
      var hxPct = ((xAt(state.hoverIdx) / W) * 100).toFixed(2);
      hoverHtml = '<span class="wb-crosshair-v" style="left:' + hxPct + '%"></span>';
    }

    var svgHtml =
      '<svg class="wb-svg" id="wb-chart-svg" viewBox="0 0 ' + W + " " + H + '" preserveAspectRatio="none" role="img" aria-label="时序用量趋势图">' +
      defsHtml +
      gridHtml +
      pathsHtml +
      "</svg>";

    // X 轴稀疏刻度 + 🔥 峰值胶囊 (S2)；首尾坐标向内贴齐避免窄屏截断
    var step = nPts <= 7 ? 1 : nPts <= 16 ? 2 : 5;
    var xAxisHtml = "";
    sliceLabels.forEach(function (lbl, i) {
      var isPeak = i === peakLocalIdx && peakSumVal > 0;
      var show = isPeak || i === 0 || i === nPts - 1 || i % step === 0;
      if (!show) return;
      if (!isPeak && peakLocalIdx !== i && Math.abs(i - peakLocalIdx) <= (nPts > 14 ? 1 : 0)) return;
      var pctLeft = nPts <= 1 ? 50 : (xAt(i) / plotW) * 100;
      var tx = pctLeft <= 8 ? "0%" : pctLeft >= 92 ? "-100%" : "-50%";
      if (isPeak) {
        xAxisHtml +=
          '<span class="wb-xtick is-peak" style="left:' + pctLeft.toFixed(1) + "%;transform:translateX(" + tx + ");background:" + (peakDomSeries ? peakDomSeries.color : "#0B5CBB") + '">' +
          "🔥 " + esc(lbl) +
          "</span>";
      } else {
        xAxisHtml += '<span class="wb-xtick" style="left:' + pctLeft.toFixed(1) + "%;transform:translateX(" + tx + ')">' + esc(lbl) + "</span>";
      }
    });

    // 底部探针 / 汇总栏
    var probeHtml = "";
    if (state.hoverIdx != null && state.hoverIdx >= 0 && state.hoverIdx < nPts) {
      var hLbl = sliceLabels[state.hoverIdx];
      var hTotal = combinedPerIdx[state.hoverIdx] || 0;
      var parts = sliceSeries
        .map(function (s) {
          return { name: s.name, color: s.color, v: s.values[state.hoverIdx] || 0 };
        })
        .sort(function (a, b) {
          return b.v - a.v;
        })
        .slice(0, 4);
      probeHtml =
        '<span class="wb-probe-active">📍 <strong>' + esc(hLbl) + "</strong> · " +
        parts
          .map(function (p) {
            return '<span class="wb-probe-item"><i style="background:' + p.color + '"></i>' + esc(p.name) + " " + fmtVal(p.v) + "</span>";
          })
          .join("") +
        (sliceSeries.length > 1 ? '<span class="wb-probe-sum">合计 ' + fmtVal(hTotal) + "</span>" : "") +
        "</span>";
    } else {
      var totalAllPts = combinedPerIdx.reduce(function (a, b) { return a + b; }, 0);
      var avgAllPts = combinedPerIdx.length ? totalAllPts / combinedPerIdx.length : 0;
      var peakLbl = sliceLabels[peakLocalIdx] || "";
      probeHtml =
        '<span class="wb-probe-stat"><i style="background:#F59E0B"></i>峰值 <b>' + fmtVal(Math.max(0, peakSumVal)) + "</b> (" + esc(peakLbl) + ")</span>" +
        '<span class="wb-probe-stat"><i style="background:#0B5CBB"></i>均值 <b>' + fmtVal(avgAllPts) + "</b></span>" +
        (isCost ? '<span class="wb-probe-stat">区间累计 <b>' + fmtUsd(totalAllPts) + "</b></span>" : "") +
        '<span class="wb-probe-hint">悬停读取节点 · 双击或 +/- 缩放</span>';
    }

    var chartSeg = [
      { k: "line", label: "折线" },
      { k: "area", label: "面积" },
    ]
      .map(function (o) {
        var on = state.chartType === o.k;
        return '<button type="button" class="wb-seg__btn' + (on ? " is-on" : "") + '" data-wb-ctype="' + o.k + '" aria-pressed="' + on + '">' + o.label + "</button>";
      })
      .join("");

    var modeSeg = [
      { k: "agent", label: "Agent" },
      { k: "model", label: "模型" },
      { k: "type", label: "Token 构成" },
      { k: "cost", label: "费用" },
    ]
      .map(function (o) {
        var on = state.seriesMode === o.k;
        return '<button type="button" class="wb-seg__btn' + (on ? " is-on" : "") + '" data-wb-smode="' + o.k + '" aria-pressed="' + on + '">' + o.label + "</button>";
      })
      .join("");

    var legendHtml = allSeries
      .map(function (s) {
        var off = Boolean(state.hiddenSeries[s.key]);
        var badge = "";
        if (s.agentId && AGENTS_META[s.agentId]) {
          badge = brandBadgeHtml(Object.assign({ size: 12, color: s.color }, AGENTS_META[s.agentId]));
        } else if (s.modelKey && MODELS_META[s.modelKey]) {
          badge = brandBadgeHtml(Object.assign({ size: 12, color: s.color }, MODELS_META[s.modelKey]));
        } else {
          badge = '<i class="wb-ldot" style="background:' + s.color + '"></i>';
        }
        return (
          '<button type="button" class="wb-legend__item' + (off ? " is-off" : "") + '" data-wb-series="' + esc(s.key) + '" aria-pressed="' + (!off) + '" title="点击切换该系列显示">' +
          badge +
          "<span>" + esc(s.name) + "</span>" +
          "</button>"
        );
      })
      .join("");

    return (
      '<section class="wb-card">' +
      '<div class="wb-card__head">' +
      '<div class="wb-card__titlewrap">' +
      '<h4 class="wb-card__title">时序趋势</h4>' +
      '<p class="wb-card__sub">' + esc(metaRange.spanText) + "</p>" +
      "</div>" +
      '<div class="wb-card__ctrls">' +
      '<div class="wb-zoom-pill" role="group" aria-label="图表缩放">' +
      '<button type="button" class="wb-zoom-btn" data-wb-zoom="-" ' + (state.zoom <= 1 ? "disabled" : "") + ' aria-label="缩小">−</button>' +
      '<span class="wb-zoom-val num">' + state.zoom.toFixed(1) + "x</span>" +
      '<button type="button" class="wb-zoom-btn" data-wb-zoom="+" ' + (state.zoom >= 4 || totalPts <= 4 ? "disabled" : "") + ' aria-label="放大">+</button>' +
      (state.zoom > 1 ? '<button type="button" class="wb-zoom-reset" data-wb-zoom="reset">↺ 全景</button>' : "") +
      "</div>" +
      '<div class="wb-seg wb-seg--sm">' + chartSeg + "</div>" +
      '<div class="wb-seg wb-seg--sm">' + modeSeg + "</div>" +
      "</div>" +
      "</div>" +
      '<div class="wb-legend">' + legendHtml + "</div>" +
      '<div class="wb-chart-box' + (state.zoom > 1 ? " can-pan" : "") + '" id="wb-chart-box">' +
      '<div class="wb-chart-row">' +
      '<div class="wb-yaxis" aria-hidden="true">' + yAxisHtml + "</div>" +
      '<div class="wb-plotwrap">' +
      '<div class="wb-plot" id="wb-plot">' + svgHtml + hoverHtml + dotsHtml + "</div>" +
      '<div class="wb-xaxis"><div class="wb-xaxis__track">' + xAxisHtml + "</div></div>" +
      "</div>" +
      "</div>" +
      "</div>" +
      '<div class="wb-probe-strip">' + probeHtml + "</div>" +
      "</section>"
    );
  }

  function renderModels(snap) {
    var models = snap.models;
    var totalSources = snap.rawChannels.length;
    var seg = [
      { k: "canonical", label: "合并视图" },
      { k: "raw", label: "原始渠道" },
    ]
      .map(function (o) {
        var on = state.modelView === o.k;
        return '<button type="button" class="wb-seg__btn' + (on ? " is-on" : "") + '" data-wb-mview="' + o.k + '" aria-pressed="' + on + '">' + o.label + "</button>";
      })
      .join("");

    var bodyHtml = "";
    if (state.modelView === "canonical") {
      bodyHtml = models
        .map(function (m) {
          var multi = m.sources.length > 1;
          var exp = multi && Boolean(state.expandedModels[m.key]);
          var barW = Math.max(2, Math.min(100, m.share)).toFixed(1);
          var treeHtml = "";
          if (exp) {
            treeHtml =
              '<div class="wb-sources">' +
              m.sources
                .map(function (src) {
                  return (
                    '<div class="wb-source">' +
                    '<span class="wb-source__arr">↳</span>' +
                    '<span class="wb-mono-name">' + esc(src.raw) + "</span>" +
                    '<span class="wb-tag">' + esc(src.agentName) + "</span>" +
                    '<span class="wb-spacer"></span>' +
                    '<span class="wb-source__share num">' + fmtTokensFromM(src.tokensM) + " (" + fmtPct(src.shareOfModel) + ")</span>" +
                    '<span class="wb-cost num">' + fmtUsd(src.cost) + "</span>" +
                    "</div>"
                  );
                })
                .join("") +
              "</div>";
          }
          return (
            '<div class="wb-group">' +
            '<div class="wb-row">' +
            brandBadgeHtml({ size: 20, tile: m.tile, mark: m.mark, glyph: m.glyph, color: m.color, mono: m.name[0] }) +
            '<div class="wb-row__meta">' +
            '<div class="wb-row__titleline">' +
            '<span class="wb-row__name">' + esc(m.name) + "</span>" +
            '<span class="wb-tag">' + esc(m.vendor) + "</span>" +
            (multi ? '<span class="wb-chip">合并 ' + m.sources.length + " 个渠道</span>" : "") +
            "</div>" +
            '<div class="wb-row__sub wb-mono">规范键: ' + esc(m.key) + "</div>" +
            "</div>" +
            '<div class="wb-row__figs">' +
            '<div class="wb-shareline"><span class="wb-bar"><i style="width:' + barW + "%;background:" + m.color + '"></i></span><span class="wb-share num">' + fmtPct(m.share) + "</span></div>" +
            '<div class="wb-amtline"><span class="wb-tokens num">' + fmtTokensFromM(m.tokensM) + '</span><span class="wb-cost num">' + fmtUsd(m.cost) + "</span></div>" +
            "</div>" +
            (multi
              ? '<button type="button" class="wb-expbtn' + (exp ? " is-open" : "") + '" data-wb-expmodel="' + esc(m.key) + '" aria-expanded="' + exp + '" aria-label="展开渠道明细">' +
                '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3 2l4 3-4 3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
                "</button>"
              : '<span class="wb-exp-spacer" aria-hidden="true"></span>') +
            "</div>" +
            treeHtml +
            "</div>"
          );
        })
        .join("");
    } else {
      bodyHtml = snap.rawChannels
        .map(function (src, idx) {
          return (
            '<div class="wb-row wb-raw-row">' +
            '<span class="wb-rank num">#' + (idx + 1) + "</span>" +
            '<div class="wb-row__meta">' +
            '<div class="wb-mono-name">' + esc(src.raw) + "</div>" +
            '<div class="wb-row__sub">来源 Agent: ' + esc(src.agentName) + "</div>" +
            "</div>" +
            '<span class="wb-spacer"></span>' +
            '<span class="wb-tokens num">' + fmtTokensFromM(src.tokensM) + "</span>" +
            '<span class="wb-cost num">' + fmtUsd(src.cost) + "</span>" +
            "</div>"
          );
        })
        .join("");
    }

    return (
      '<section class="wb-card">' +
      '<div class="wb-card__head">' +
      '<div class="wb-card__titlewrap">' +
      '<div class="wb-card__titleline"><h4 class="wb-card__title">模型分布</h4><span class="wb-chip">' + models.length + " 款主模型 · " + totalSources + " 个渠道</span></div>" +
      '<p class="wb-card__sub">按规范型号跨 Agent 归并算力消费，支持一键透视底层原始渠道</p>' +
      "</div>" +
      '<div class="wb-card__ctrls"><div class="wb-seg wb-seg--sm">' + seg + "</div></div>" +
      "</div>" +
      '<div class="wb-list">' + bodyHtml + "</div>" +
      "</section>"
    );
  }

  function renderAgents(snap) {
    var folderLabel = state.range === "today" ? "📁 今日 Top 工程:" : "📁 Top 工程:";
    var listHtml = snap.agents
      .map(function (a) {
        var exp = Boolean(state.expandedAgents[a.id]);
        var tot = Math.max(0.01, a.inputM + a.outputM + a.cacheReadM);
        var wIn = Math.max(2, (a.inputM / tot) * 100).toFixed(1);
        var wOut = Math.max(2, (a.outputM / tot) * 100).toFixed(1);
        var wCache = Math.max(4, 100 - parseFloat(wIn) - parseFloat(wOut)).toFixed(1);

        var detailHtml = "";
        if (exp) {
          var projTags = a.topProjects
            .map(function (p) {
              return '<span class="wb-flow-tag"><span class="wb-mono-name">' + esc(p.name) + '</span><span class="wb-flow-dim">(' + fmtTokensFromM(p.tokensM) + ")</span></span>";
            })
            .join("");
          var modTags = a.topModels
            .map(function (m) {
              var meta = MODELS_META[m.key];
              return (
                '<span class="wb-flow-tag">' +
                brandBadgeHtml({ size: 12, tile: m.color, mark: "#FFFFFF", glyph: meta ? meta.glyph : null, color: m.color, mono: m.name[0] }) +
                "<span>" + esc(m.name) + '</span><span class="wb-flow-dim">(' + fmtTokensFromM(m.tokensM) + ")</span>" +
                "</span>"
              );
            })
            .join("");
          detailHtml =
            '<div class="wb-agent-detail">' +
            '<div class="wb-detail-row"><span class="wb-detail-lbl">' + folderLabel + '</span><div class="wb-flow">' + projTags + "</div></div>" +
            '<div class="wb-detail-row"><span class="wb-detail-lbl">⚡️ 主要消耗模型:</span><div class="wb-flow">' + modTags + "</div></div>" +
            "</div>";
        }

        return (
          '<div class="wb-group">' +
          '<div class="wb-row">' +
          brandBadgeHtml({ size: 22, tile: a.tile, mark: a.mark, glyph: a.glyph, color: a.color, mono: a.mono }) +
          '<div class="wb-row__meta">' +
          '<div class="wb-row__titleline"><span class="wb-row__name">' + esc(a.name) + '</span><span class="wb-tag' + (a.status === "活跃" ? " is-ok" : "") + '">' + a.status + "</span></div>" +
          '<div class="wb-row__sub">' + esc(a.note) + "</div>" +
          "</div>" +
          '<div class="wb-row__figs wb-row__figs--agent">' +
          '<span class="wb-stack" title="输入 ' + fmtTokensFromM(a.inputM) + " · 输出 " + fmtTokensFromM(a.outputM) + " · 缓存读 " + fmtTokensFromM(a.cacheReadM) + '">' +
          '<i style="width:' + wIn + '%;background:#4C9CFF"></i>' +
          '<i style="width:' + wOut + '%;background:#A855F7"></i>' +
          '<i style="width:' + wCache + '%;background:#10B981"></i>' +
          "</span>" +
          '<div class="wb-amtline"><span class="wb-tokens num">' + fmtTokensFromM(a.tokensM) + '</span><span class="wb-cost num">' + fmtUsd(a.cost) + '</span><span class="wb-share num">' + fmtPct(a.share) + "</span></div>" +
          "</div>" +
          '<button type="button" class="wb-expbtn' + (exp ? " is-open" : "") + '" data-wb-expagent="' + esc(a.id) + '" aria-expanded="' + exp + '" aria-label="展开关联工程与模型">' +
          '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3 2l4 3-4 3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
          "</button>" +
          "</div>" +
          detailHtml +
          "</div>"
        );
      })
      .join("");

    return (
      '<section class="wb-card">' +
      '<div class="wb-card__head">' +
      '<div class="wb-card__titlewrap">' +
      '<div class="wb-card__titleline"><h4 class="wb-card__title">Agent 表现</h4><span class="wb-chip">' + snap.kpi.activeCount + " 个活跃</span></div>" +
      '<p class="wb-card__sub">透视各 Agent 用量占比、Token 结构与关联工程</p>' +
      "</div>" +
      '<div class="wb-stack-legend" aria-hidden="true">' +
      '<span><i style="background:#4C9CFF"></i>输入</span>' +
      '<span><i style="background:#A855F7"></i>输出</span>' +
      '<span><i style="background:#10B981"></i>缓存读</span>' +
      "</div>" +
      "</div>" +
      '<div class="wb-list">' + listHtml + "</div>" +
      "</section>"
    );
  }

  function renderComposition(snap) {
    var k = snap.kpi;
    var quadrants = [
      ["Prompt Input", "用户提示词与工程上下文", fmtTokensFromM(k.inputM), "输入基础", "#4C9CFF"],
      ["Model Output", "大模型生成与代码产出", fmtTokensFromM(k.outputM), "高单价", "#A855F7"],
      ["Prompt Cache Read", "命中率 " + k.cacheHitRate + "% · 已省 " + fmtUsd(k.cacheSaved), fmtTokensFromM(k.cacheReadM), "已节省", "#10B981"],
      ["Cache Creation", "写入提示缓存的上下文", fmtTokensFromM(k.cacheCreateM), "写入", "#F59E0B"],
    ];

    var quadHtml = quadrants
      .map(function (q) {
        return (
          '<div class="wb-comp-box">' +
          '<div class="wb-comp-box__head"><span>' + q[0] + '</span><span class="wb-chip" style="color:' + q[4] + ";background:color-mix(in srgb," + q[4] + ' 13%,transparent)">' + q[3] + "</span></div>" +
          '<div class="wb-comp-box__val num">' + q[2] + "</div>" +
          '<div class="wb-comp-box__sub">' + esc(q[1]) + "</div>" +
          "</div>"
        );
      })
      .join("");

    var peakH = Math.max.apply(null, TODAY_HOUR_M) || 1;
    var cellsHtml = TODAY_HOUR_M.map(function (val, h) {
      var lbl = (h < 10 ? "0" : "") + h + ":00";
      var opacityPct = val > 0 ? (25 + 75 * (val / peakH)).toFixed(1) : 0;
      var style = val > 0 ? "background:rgba(11,92,187," + (parseFloat(opacityPct) / 100).toFixed(3) + ");" : "";
      var isCur = state.hoveredHour === h;
      return (
        '<button type="button" class="wb-hour' + (val === 0 ? " is-zero" : "") + (isCur ? " is-hot" : "") + '" style="' + style + '" data-wb-hour="' + h + '" aria-label="' + lbl + " 用量 " + fmtTokensFromM(val) + '"></button>'
      );
    }).join("");

    var hourReadout = state.hoveredHour != null
      ? "📍 " + (state.hoveredHour < 10 ? "0" : "") + state.hoveredHour + ":00 : " + fmtTokensFromM(TODAY_HOUR_M[state.hoveredHour]) + " Tokens"
      : "鼠标悬停查看单时段用量";

    return (
      '<section class="wb-card">' +
      '<div class="wb-card__head">' +
      '<div class="wb-card__titlewrap">' +
      '<div class="wb-card__titleline"><h4 class="wb-card__title">Token 构成与时段</h4><span class="wb-chip is-ok">Prompt Cache 专项分析</span></div>' +
      '<p class="wb-card__sub">所选范围的输入、输出与缓存读写结构，以及今日 24 小时活跃分布</p>' +
      "</div>" +
      "</div>" +
      '<div class="wb-comp-grid">' + quadHtml + "</div>" +
      '<div class="wb-divider"></div>' +
      '<div class="wb-hours">' +
      '<div class="wb-hours__head"><span>今日 24 小时交互密度 (00:00 - 23:00)</span><span class="wb-hours__probe' + (state.hoveredHour != null ? " is-on" : "") + '" id="wb-hour-probe">' + esc(hourReadout) + "</span></div>" +
      '<div class="wb-hour-cells" id="wb-hour-cells">' + cellsHtml + "</div>" +
      '<div class="wb-hour-ticks"><span>00:00</span><span>04:00</span><span>08:00</span><span>12:00</span><span>16:00</span><span>20:00</span><span>23:00</span></div>' +
      "</div>" +
      "</section>"
    );
  }

  function renderProbeFooter() {
    var rowsHtml = SESSION_PROBES.map(function (p) {
      var cls = p.status === "ready" ? "is-ok" : "is-neutral";
      return (
        '<div class="wb-probe-row">' +
        '<div class="wb-probe-row__meta"><span class="wb-probe-row__name">' + esc(p.name) + '</span><span class="wb-probe-row__path wb-mono">' + esc(p.path) + "</span></div>" +
        '<span class="wb-tag ' + cls + '">' + esc(p.label) + "</span>" +
        "</div>"
      );
    }).join("");

    return (
      '<section class="wb-card">' +
      '<div class="wb-card__head">' +
      '<div class="wb-card__titlewrap">' +
      '<div class="wb-card__titleline"><h4 class="wb-card__title">会话来源与采集探针</h4><span class="wb-tag is-ok">Rust Collector · ' + esc(state.probeNote) + "</span></div>" +
      '<p class="wb-card__sub">扫描本机各 Agent 只读历史日志目录，支持卸载后保留历史账目</p>' +
      "</div>" +
      '<div class="wb-card__ctrls"><button type="button" class="wb-btn' + (state.probing ? " is-spinning" : "") + '" data-wb-reprobe>' +
      '<svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13.5 8a5.5 5.5 0 1 1-1.4-3.67M13.5 2.5v2.8h-2.8"/></svg>' +
      "<span>" + (state.probing ? "检查中…" : "重新检查") + "</span>" +
      "</button></div>" +
      "</div>" +
      '<div class="wb-probes-grid">' + rowsHtml + "</div>" +
      '<div class="wb-privacy-note">' +
      '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" aria-hidden="true"><rect x="3.2" y="7" width="9.6" height="7" rx="1.6"/><path d="M5.2 7V5a2.8 2.8 0 0 1 5.6 0v2"/></svg>' +
      "<span>所有会话仅在本机分析，绝不上报远程服务器</span>" +
      "</div>" +
      "</section>"
    );
  }

  /* ---------- export helpers --------------------------------------- */
  function buildCsv(snap) {
    var lines = ["range,canonical_model,display_name,vendor,raw_channel,agent,tokens_m,share_pct,estimated_usd"];
    snap.models.forEach(function (m) {
      m.sources.forEach(function (s) {
        lines.push([
          state.range,
          m.key,
          '"' + m.name + '"',
          m.vendor,
          '"' + s.raw + '"',
          '"' + s.agentName + '"',
          s.tokensM.toFixed(2),
          s.shareOfModel.toFixed(1) + "%",
          s.cost.toFixed(2),
        ].join(","));
      });
    });
    return lines.join("\n");
  }

  function triggerDownload(filename, content, mime) {
    try {
      var blob = new Blob([content], { type: mime });
      var url = URL.createObjectURL(blob);
      var a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    } catch (_) {
      // ignore if sandbox restricts synthetic downloads
    }
  }

  function handleExport(kind) {
    var snap = getSnapshot();
    if (kind === "csv") {
      var csv = buildCsv(snap);
      var fn = "bruce_agent_usage_" + state.range + ".csv";
      triggerDownload(fn, csv, "text/csv;charset=utf-8;");
      state.exportNotice = {
        filename: fn,
        kind: "csv",
        desc: "共 " + snap.rawChannels.length + " 条渠道明细",
        preview: csv.split("\n").slice(0, 7).join("\n"),
        open: true,
      };
    } else {
      var payload = {
        range: state.range,
        currency: "USD",
        kpi: {
          totalTokens: Math.round(snap.kpi.totalTokensM * 1e6),
          estimatedCostUsd: +snap.kpi.cost.toFixed(2),
          cacheHitRate: snap.kpi.cacheHitRate,
          cacheSavedUsd: +snap.kpi.cacheSaved.toFixed(2),
        },
        models: snap.models.map(function (m) {
          return { key: m.key, name: m.name, tokensM: +m.tokensM.toFixed(2), costUsd: +m.cost.toFixed(2), channels: m.sources.length };
        }),
      };
      var json = JSON.stringify(payload, null, 2);
      var jfn = "bruce_agent_usage_" + state.range + ".json";
      triggerDownload(jfn, json, "application/json;charset=utf-8;");
      state.exportNotice = {
        filename: jfn,
        kind: "json",
        desc: snap.models.length + " 款主模型",
        preview: json.split("\n").slice(0, 14).join("\n") + "\n  ...",
        open: true,
      };
    }
    render();
  }

  /* ---------- interaction wiring & render -------------------------- */
  var dragInfo = null;

  function onGlobalPointerMove(e) {
    if (!dragInfo) return;
    var dx = (e.clientX - dragInfo.startX) / Math.max(120, dragInfo.width);
    state.pan = Math.max(0, Math.min(1, dragInfo.startPan - dx));
    updateTimelineSlot();
  }

  function onGlobalPointerUp() {
    if (!dragInfo) return;
    dragInfo = null;
    window.removeEventListener("pointermove", onGlobalPointerMove);
    window.removeEventListener("pointerup", onGlobalPointerUp);
    window.removeEventListener("pointercancel", onGlobalPointerUp);
  }

  function bindTimelineControls(container, snap) {
    container.querySelectorAll("[data-wb-ctype]").forEach(function (b) {
      b.addEventListener("click", function () {
        state.chartType = b.getAttribute("data-wb-ctype");
        updateTimelineSlot();
      });
    });

    container.querySelectorAll("[data-wb-smode]").forEach(function (b) {
      b.addEventListener("click", function () {
        state.seriesMode = b.getAttribute("data-wb-smode");
        state.hiddenSeries = {};
        state.hoverIdx = null;
        updateTimelineSlot();
      });
    });

    container.querySelectorAll("[data-wb-zoom]").forEach(function (b) {
      b.addEventListener("click", function () {
        var act = b.getAttribute("data-wb-zoom");
        if (act === "+") state.zoom = Math.min(4, +(state.zoom + 0.6).toFixed(1));
        else if (act === "-") state.zoom = Math.max(1, +(state.zoom - 0.6).toFixed(1));
        else { state.zoom = 1; state.pan = 1; }
        state.hoverIdx = null;
        updateTimelineSlot();
      });
    });

    container.querySelectorAll("[data-wb-series]").forEach(function (b) {
      b.addEventListener("click", function () {
        var key = b.getAttribute("data-wb-series");
        var list = snap.series[state.seriesMode] || [];
        if (state.hiddenSeries[key]) {
          delete state.hiddenSeries[key];
        } else {
          var visibleLeft = list.filter(function (s) {
            return s.key !== key && !state.hiddenSeries[s.key];
          }).length;
          if (visibleLeft === 0) state.hiddenSeries = {};
          else state.hiddenSeries[key] = true;
        }
        updateTimelineSlot();
      });
    });

    var box = container.querySelector("#wb-plot");
    if (!box) return;

    var vp = getViewport(snap.labels.length);
    var nPts = vp.count;

    function idxFromClientX(clientX) {
      var rect = box.getBoundingClientRect();
      if (!rect.width) return null;
      var rel = (clientX - rect.left) / rect.width;
      if (rel < -0.05 || rel > 1.05) return null;
      var clamped = Math.max(0, Math.min(1, rel));
      return Math.round(clamped * Math.max(0, nPts - 1));
    }

    box.addEventListener("pointermove", function (e) {
      if (dragInfo) return;
      var idx = idxFromClientX(e.clientX);
      if (idx !== state.hoverIdx) {
        state.hoverIdx = idx;
        updateTimelineSlot();
      }
    });

    box.addEventListener("pointerleave", function () {
      if (dragInfo) return;
      if (state.hoverIdx != null) {
        state.hoverIdx = null;
        updateTimelineSlot();
      }
    });

    box.addEventListener("dblclick", function () {
      if (snap.labels.length <= 4) return;
      state.zoom = state.zoom > 1.05 ? 1 : 2.2;
      state.hoverIdx = null;
      updateTimelineSlot();
    });

    if (state.zoom > 1) {
      box.addEventListener("pointerdown", function (e) {
        if (e.button !== 0) return;
        var rect = box.getBoundingClientRect();
        dragInfo = { startX: e.clientX, startPan: state.pan, width: rect.width };
        window.addEventListener("pointermove", onGlobalPointerMove);
        window.addEventListener("pointerup", onGlobalPointerUp);
        window.addEventListener("pointercancel", onGlobalPointerUp);
      });
    }
  }

  function updateTimelineSlot() {
    var slot = document.getElementById("wb-timeline-slot");
    if (!slot) {
      render();
      return;
    }
    var snap = getSnapshot();
    slot.innerHTML = renderTimeline(snap);
    bindTimelineControls(slot, snap);
  }

  function render() {
    var snap = getSnapshot();

    var html =
      '<div class="wb-win">' +
      '<div class="wb-titlebar">' +
      '<div class="wb-lights" aria-hidden="true"><i></i><i></i><i></i></div>' +
      '<span class="wb-titlebar__name">Bruce 设置</span>' +
      '<span class="wb-titlebar__crumb">设置 › 模型用量</span>' +
      "</div>" +
      '<div class="wb-body">' +
      renderSidebar() +
      '<div class="wb-pane">' +
      '<div class="wb-pane__head">' +
      '<div><p class="wb-crumb">设置 › 模型用量</p><h3 class="wb-pane__title">模型用量</h3></div>' +
      '<span class="wb-live-pill"><i></i>本机样例数据 · USD 计价</span>' +
      "</div>" +
      renderToolbar() +
      renderKpis(snap) +
      '<div id="wb-timeline-slot">' + renderTimeline(snap) + "</div>" +
      renderModels(snap) +
      renderAgents(snap) +
      renderComposition(snap) +
      renderProbeFooter() +
      "</div>" +
      "</div>" +
      "</div>";

    host.innerHTML = html;

    host.querySelectorAll("[data-wb-range]").forEach(function (b) {
      b.addEventListener("click", function () {
        var r = b.getAttribute("data-wb-range");
        if (!r || r === state.range) return;
        state.range = r;
        state.zoom = 1;
        state.pan = 1;
        state.hoverIdx = null;
        state.exportNotice = null;
        render();
      });
    });

    host.querySelectorAll("[data-wb-mview]").forEach(function (b) {
      b.addEventListener("click", function () {
        state.modelView = b.getAttribute("data-wb-mview");
        render();
      });
    });

    host.querySelectorAll("[data-wb-expmodel]").forEach(function (b) {
      b.addEventListener("click", function () {
        var k = b.getAttribute("data-wb-expmodel");
        if (state.expandedModels[k]) delete state.expandedModels[k];
        else state.expandedModels[k] = true;
        render();
      });
    });

    host.querySelectorAll("[data-wb-expagent]").forEach(function (b) {
      b.addEventListener("click", function () {
        var id = b.getAttribute("data-wb-expagent");
        if (state.expandedAgents[id]) delete state.expandedAgents[id];
        else state.expandedAgents[id] = true;
        render();
      });
    });

    host.querySelectorAll("[data-wb-export]").forEach(function (b) {
      b.addEventListener("click", function () {
        handleExport(b.getAttribute("data-wb-export"));
      });
    });

    var expToggle = host.querySelector("[data-wb-exp-toggle]");
    if (expToggle) {
      expToggle.addEventListener("click", function () {
        if (state.exportNotice) {
          state.exportNotice.open = !state.exportNotice.open;
          render();
        }
      });
    }

    var expClose = host.querySelector("[data-wb-exp-close]");
    if (expClose) {
      expClose.addEventListener("click", function () {
        state.exportNotice = null;
        render();
      });
    }

    var reprobeBtn = host.querySelector("[data-wb-reprobe]");
    if (reprobeBtn && !state.probing) {
      reprobeBtn.addEventListener("click", function () {
        state.probing = true;
        render();
        window.setTimeout(function () {
          state.probing = false;
          state.probeNote = "可用 · 刚刚已复检 (38ms)";
          render();
        }, 420);
      });
    }

    var cellsHost = document.getElementById("wb-hour-cells");
    if (cellsHost) {
      function applyHourHighlight(activeH) {
        var pr = document.getElementById("wb-hour-probe");
        if (activeH == null) {
          if (pr) {
            pr.textContent = "鼠标悬停查看单时段用量";
            pr.className = "wb-hours__probe";
          }
          cellsHost.querySelectorAll(".wb-hour.is-hot").forEach(function (el) {
            el.classList.remove("is-hot");
          });
          return;
        }
        if (pr) {
          pr.textContent = "📍 " + (activeH < 10 ? "0" : "") + activeH + ":00 : " + fmtTokensFromM(TODAY_HOUR_M[activeH]) + " Tokens";
          pr.className = "wb-hours__probe is-on";
        }
        cellsHost.querySelectorAll(".wb-hour").forEach(function (el) {
          var eh = parseInt(el.getAttribute("data-wb-hour"), 10);
          el.classList.toggle("is-hot", eh === activeH);
        });
      }

      if (state.lockedHour != null) applyHourHighlight(state.lockedHour);

      cellsHost.addEventListener("mouseover", function (e) {
        var btn = e.target.closest("[data-wb-hour]");
        if (!btn) return;
        var h = parseInt(btn.getAttribute("data-wb-hour"), 10);
        if (state.hoveredHour === h) return;
        state.hoveredHour = h;
        applyHourHighlight(h);
      });
      cellsHost.addEventListener("mouseleave", function () {
        state.hoveredHour = null;
        applyHourHighlight(state.lockedHour != null ? state.lockedHour : null);
      });
      cellsHost.querySelectorAll("[data-wb-hour]").forEach(function (btn) {
        btn.addEventListener("click", function () {
          var h = parseInt(btn.getAttribute("data-wb-hour"), 10);
          state.lockedHour = state.lockedHour === h ? null : h;
          applyHourHighlight(state.lockedHour != null ? state.lockedHour : state.hoveredHour);
        });
      });
    }

    var tSlot = document.getElementById("wb-timeline-slot");
    if (tSlot) bindTimelineControls(tSlot, snap);
  }

  // 若 preview-fallback.js 在异步 fetch 到根 VERSION 后替换了页眉版本文本，同步更新设置侧栏底部版本号
  var verNode = document.querySelector(".masthead__meta .ver");
  if (verNode && typeof MutationObserver !== "undefined") {
    var obs = new MutationObserver(function () {
      var sideFoot = host.querySelector(".wb-sidebar__foot span:last-child");
      if (sideFoot) sideFoot.textContent = readAppVersion();
    });
    obs.observe(verNode, { childList: true, characterData: true, subtree: true });
  }

  render();
})();
