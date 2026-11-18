// 04 网络出口保护：运行时拦截样张（丝滑收放与前后换牌）+ 设置页出口通道交互配置
(function () {
  "use strict";

  var PROVIDERS = {
    codex: {
      id: "codex",
      name: "ChatGPT",
      color: "#10a37f",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.3 10.1a4.7 4.7 0 0 0-.4-3.9 4.8 4.8 0 0 0-5.1-2.3A4.7 4.7 0 0 0 11.3 2a4.8 4.8 0 0 0-4.6 3.3 4.7 4.7 0 0 0-3.2 2.3 4.8 4.8 0 0 0 .6 5.6 4.7 4.7 0 0 0 .4 3.9 4.8 4.8 0 0 0 5.1 2.3A4.7 4.7 0 0 0 13.1 21a4.8 4.8 0 0 0 4.6-3.3 4.7 4.7 0 0 0 3.2-2.3 4.8 4.8 0 0 0-.6-5.3ZM13.1 19.6a3.5 3.5 0 0 1-2.2-.8l.1-.1 3.7-2.1a.6.6 0 0 0 .3-.5v-5.1l1.5.9v4.2a3.5 3.5 0 0 1-3.4 3.5ZM5.7 16.5a3.5 3.5 0 0 1-.4-2.3l.1.1 3.7 2.1a.6.6 0 0 0 .6 0l4.5-2.6v1.8l-3.7 2.1a3.5 3.5 0 0 1-4.8-1.2Zm-1-8.2a3.5 3.5 0 0 1 1.8-1.5v4.4a.6.6 0 0 0 .3.5l4.4 2.5-1.5.9L6 13a3.5 3.5 0 0 1-1.3-4.7Zm12.7 3-4.5-2.6 1.5-.9 3.7 2.1a3.5 3.5 0 0 1-.5 6.3V12a.6.6 0 0 0-.2-.7Zm1.5-2.3-.1-.1-3.7-2.1a.6.6 0 0 0-.6 0L10 9.4V7.6l3.7-2.1a3.5 3.5 0 0 1 5.2 3.5Zm-9.6 3.1-1.5-.9V7a3.5 3.5 0 0 1 5.7-2.7l-.1.1-3.7 2.1a.6.6 0 0 0-.3.5l-.1 5.1Zm.9-1.8 1.9-1.1 1.9 1.1v2.2L12 13.6l-1.9-1.1v-2.2Z" fill="currentColor"/></svg>',
    },
    claude: {
      id: "claude",
      name: "Claude",
      color: "#d97757",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.2l1.1 6.7 5.3-4.3-3.5 5.9 6.8-.9-6 3.1 6 3.1-6.8-.9 3.5 5.9-5.3-4.3L12 21.8l-1.1-6.7-5.3 4.3 3.5-5.9-6.8.9 6-3.1-6-3.1 6.8.9-3.5-5.9 5.3 4.3L12 2.2z" fill="currentColor"/></svg>',
    },
    cline: {
      id: "cline",
      name: "Cline",
      color: "#18181b",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="11" y="2.2" width="2" height="3.2" rx="1" fill="currentColor"/><path d="M5 7.5A3.5 3.5 0 0 1 8.5 4h7A3.5 3.5 0 0 1 19 7.5v8A3.5 3.5 0 0 1 15.5 19h-7A3.5 3.5 0 0 1 5 15.5v-8Zm3.4 3.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3Zm7.2 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3Z" fill-rule="evenodd" fill="currentColor"/></svg>',
    },
    grok: {
      id: "grok",
      name: "Grok",
      color: "#111111",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="7.2" fill="none" stroke="currentColor" stroke-width="2.4"/><path d="M5.2 18.8L18.8 5.2" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"/></svg>',
    },
    kimi: {
      id: "kimi",
      name: "Kimi",
      color: "#0a84ff",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.2 4.5v15M6.2 12.2l7.4-7.4M9.8 11.4l6.8 8.1" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="17.8" cy="6.2" r="1.8" fill="currentColor"/></svg>',
    },
    deepseek: {
      id: "deepseek",
      name: "DeepSeek",
      color: "#4d6bfe",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4.2 14.2c0-3.7 3-6.6 6.8-6.6 2.2 0 4 .9 5.3 2.5.9-1.1 2-2.2 3.3-2.6.5 1.2.1 2.9-.8 4.1.6 1 .9 2.2.8 3.5-.3 3.4-3.3 5.5-7.4 5.5-4.7 0-8-2.6-8-6.4Zm10.6-.4a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4Z" fill-rule="evenodd" fill="currentColor"/></svg>',
    },
    zhipu: {
      id: "zhipu",
      name: "Z.ai",
      color: "#2d2d2d",
      glyph:
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6.2h12l-12 11.6h12" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    },
  };

  var PROVIDER_LIST = ["codex", "claude", "cline", "grok", "kimi", "deepseek", "zhipu"];

  var COUNTRIES = [
    { code: "JP", name: "日本", flag: "🇯🇵" },
    { code: "US", name: "美国", flag: "🇺🇸" },
    { code: "SG", name: "新加坡", flag: "🇸🇬" },
    { code: "GB", name: "英国", flag: "🇬🇧" },
    { code: "DE", name: "德国", flag: "🇩🇪" },
    { code: "KR", name: "韩国", flag: "🇰🇷" },
  ];

  var EXTRA_FLAGS = {
    FR: { name: "法国", flag: "🇫🇷" },
    CA: { name: "加拿大", flag: "🇨🇦" },
    HK: { name: "中国香港", flag: "🇭🇰" },
  };

  var SCENARIOS = {
    mismatch: {
      cardTitle: "出口 IP 泄漏",
      desc: "已拦截查额以保护账号 · 保持历史快照",
      maskedIp: "104.28.***.***",
      channelLevel: "danger",
      channelStatus: "出口国家不匹配 · 104.28.***.*** (US)",
      blocked: true,
    },
    ok: {
      cardTitle: "出口 IP 泄漏",
      desc: "已拦截查额以保护账号 · 保持历史快照",
      maskedIp: "203.104.***.***",
      channelLevel: "ok",
      channelStatus: "线路探测匹配 · 203.104.***.*** (JP)",
      blocked: false,
    },
  };

  var SPEC_CARDS = [
    {
      pid: "claude",
      windows: [
        ["5 小时", 43, "17:40"],
        ["每周", 61, "4 天后"],
      ],
    },
    {
      pid: "codex",
      windows: [
        ["5 小时", 74, "14:22"],
        ["每周", 41, "6 天后"],
      ],
    },
  ];

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function countryMeta(code) {
    var upper = String(code || "").toUpperCase();
    var preset = COUNTRIES.find(function (c) {
      return c.code === upper;
    });
    if (preset) return preset;
    if (EXTRA_FLAGS[upper]) {
      return { code: upper, name: EXTRA_FLAGS[upper].name, flag: EXTRA_FLAGS[upper].flag };
    }
    return { code: upper || "??", name: upper || "自定义国家", flag: "🌐" };
  }

  var state = {
    scenario: "mismatch",
    frontPid: "codex",
    channels: [
      {
        country: "JP",
        name: "日本",
        flag: "🇯🇵",
        port: "18081",
        defaultPort: "18081",
        providers: ["codex", "claude", "cline", "grok"],
        statusLevel: SCENARIOS.mismatch.channelLevel,
        statusText: SCENARIOS.mismatch.channelStatus,
        maskedIp: SCENARIOS.mismatch.maskedIp,
      },
      {
        country: "US",
        name: "美国",
        flag: "🇺🇸",
        port: "18083",
        defaultPort: "18083",
        providers: [],
        statusLevel: "off",
        statusText: "127.0.0.1:18083 · 点击右侧重测",
        maskedIp: null,
      },
    ],
    highlightSettings: false,
    openPopoverCountry: null,
    modalOpen: false,
    probingCountry: null,
    wizard: { country: "SG", customIso: "", port: "7897", providers: ["cline"], error: "" },
  };

  var highlightTimer = null;

  var RETEST_SVG =
    '<svg width="10" height="10" viewBox="0 0 16 16" aria-hidden="true"><path d="M13.5 8a5.5 5.5 0 1 1-1.4-3.67M13.5 2.5v2.8h-2.8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var TRASH_SVG =
    '<svg width="11" height="11" viewBox="0 0 14 14" aria-hidden="true"><path d="M2.5 3.8h9M5.2 3.8V2.6c0-.4.3-.7.7-.7h2.2c.4 0 .7.3.7.7v1.2M3.6 3.8l.5 7.4c0 .5.4.9.9.9h4c.5 0 .9-.4.9-.9l.5-7.4" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var SCAN_SVG =
    '<svg width="11" height="11" viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="4.8" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="7" cy="7" r="1.5" fill="currentColor"/></svg>';
  var WARN_SVG =
    '<svg class="eg-issue__ico" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M7.14 2.45a1 1 0 0 1 1.72 0l5.42 9.35A1 1 0 0 1 13.42 13.3H2.58a1 1 0 0 1-.86-1.5L7.14 2.45Z" fill="currentColor" fill-opacity="0.18" stroke="currentColor" stroke-width="1.35" stroke-linejoin="round"/><path d="M8 6.1v3.2" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.2" r="0.85" fill="currentColor"/></svg>';

  function findChannel(pid) {
    return (
      state.channels.find(function (c) {
        return c.providers.indexOf(pid) !== -1;
      }) || null
    );
  }

  function infoFor(pid) {
    var ch = findChannel(pid);
    if (!ch) return null;
    if (ch.country === "JP" && ch.port === ch.defaultPort) {
      return Object.assign({ channel: ch }, SCENARIOS[state.scenario]);
    }
    var ok = ch.statusLevel !== "danger" && ch.statusLevel !== "warn";
    return {
      channel: ch,
      blocked: !ok,
      cardTitle: "探测失败",
      desc: "已拦截查额以保护账号 · 保持历史快照",
      maskedIp: ch.maskedIp,
    };
  }

  function meterTier(pct) {
    var c = Math.max(0, Math.min(100, pct));
    return c >= 80 ? "crit" : c >= 50 ? "warn" : "ok";
  }

  function meterHtml(pct) {
    var c = Math.max(0, Math.min(100, pct));
    return '<div class="eg-pmeter" data-tier="' + meterTier(c) + '"><i style="width:' + c + '%"></i></div>';
  }

  function badgeHtml(pid, sz) {
    var p = PROVIDERS[pid];
    var dim = sz ? "width:" + sz + "px;height:" + sz + "px;border-radius:" + (sz >= 18 ? 4 : 3) + "px;" : "";
    return '<span class="eg-pbadge" style="' + dim + "background:" + p.color + ';color:#fff">' + p.glyph + "</span>";
  }

  function testRoute(country) {
    var ch = state.channels.find(function (c) {
      return c.country === country;
    });
    if (!ch) return;
    state.probingCountry = country;
    ch.statusLevel = "warn";
    ch.statusText = "正在探测出口线路…";
    updateAll();

    window.setTimeout(function () {
      state.probingCountry = null;
      var p = parseInt(ch.port, 10);
      if (isNaN(p) || p < 1 || p > 65535) {
        ch.statusLevel = "danger";
        ch.statusText = "代理端口无效";
      } else if (ch.country === "JP") {
        /* 点击重测：模拟节点修复后通过，若已通过则依然稳定匹配 */
        state.scenario = "ok";
        ch.statusLevel = "ok";
        ch.maskedIp = "203.104.***.***";
        ch.statusText = "线路探测匹配 · 203.104.***.*** (JP)";
      } else {
        ch.statusLevel = "ok";
        ch.maskedIp = ch.country === "US" ? "104.28.***.***" : "45.76.***.***";
        ch.statusText = "线路探测匹配 · " + ch.maskedIp + " (" + ch.country + ")";
      }
      updateAll();
    }, 440);
  }

  function focusSettings() {
    var el = document.getElementById("eg-settings");
    if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
    state.highlightSettings = true;
    syncSettingsHighlight();
    window.clearTimeout(highlightTimer);
    highlightTimer = window.setTimeout(function () {
      state.highlightSettings = false;
      syncSettingsHighlight();
    }, 1800);
  }

  function openModal() {
    var used = state.channels.map(function (c) {
      return c.country;
    });
    var firstFree = COUNTRIES.find(function (c) {
      return used.indexOf(c.code) === -1;
    });
    state.wizard = {
      country: firstFree ? firstFree.code : "",
      customIso: firstFree ? "" : "FR",
      port: "7897",
      providers: [],
      error: "",
    };
    state.modalOpen = true;
    state.openPopoverCountry = null;
    updateSettingsView(true);
  }

  function closeModal() {
    state.modalOpen = false;
    syncModalState(false);
  }

  /* ---------- Persistent Specimen Cards (Smooth Collapse & Swap) ---- */
  function ensureSpecimenMounted() {
    var host = document.getElementById("eg-specimen");
    if (!host || host.dataset.mounted) return;

    var cardsHtml = SPEC_CARDS.map(function (spec) {
      var p = PROVIDERS[spec.pid];
      var rowsHtml = spec.windows
        .map(function (w, idx) {
          return (
            '<div class="eg-pwin" data-win-idx="' + idx + '">' +
            '<span class="eg-pwin__label">' + w[0] + "</span>" +
            meterHtml(w[1]) +
            '<span class="eg-pwin__pct">' + w[1] + "%</span>" +
            '<span class="eg-pwin__when" data-normal="' + esc(w[2]) + '">' + w[2] + "</span>" +
            "</div>"
          );
        })
        .join("");

      return (
        '<div class="eg-deck__item" data-spec-pid="' + spec.pid + '">' +
        '<div class="eg-pcard">' +
        '<div class="eg-pprov">' +
        '<div class="eg-pprov__head">' +
        '<span class="eg-pprov__title">' +
        badgeHtml(spec.pid, 15) +
        '<span class="eg-pprov__name">' + p.name + "</span>" +
        "</span>" +
        '<span class="eg-pprov__right"></span>' +
        "</div>" +
        '<div class="eg-issue-wrap"><div class="eg-issue-inner">' +
        '<div class="eg-issue">' +
        WARN_SVG +
        '<span class="eg-issue__title">出口 IP 泄漏</span>' +
        '<span class="eg-issue__sep"></span>' +
        '<span class="eg-issue__desc">已拦截查额以保护账号 · 保持历史快照</span>' +
        '<span class="eg-issue__actions">' +
        '<button type="button" data-act="settings">去设置</button>' +
        '<span class="eg-issue__act-sep"></span>' +
        '<button type="button" data-act="retest">重测</button>' +
        "</span>" +
        "</div></div></div>" +
        rowsHtml +
        '<div class="eg-psubfoot"></div>' +
        "</div></div></div>"
      );
    }).join("");

    host.innerHTML = '<div class="eg-deck">' + cardsHtml + "</div>";
    host.dataset.mounted = "1";

    host.addEventListener("click", function (e) {
      var actBtn = e.target.closest("[data-act]");
      if (actBtn) {
        e.stopPropagation();
        var act = actBtn.getAttribute("data-act");
        if (act === "settings") {
          focusSettings();
        } else if (act === "retest") {
          var cardEl = actBtn.closest("[data-spec-pid]");
          var pid = cardEl ? cardEl.getAttribute("data-spec-pid") : "codex";
          var ch = findChannel(pid);
          if (ch) testRoute(ch.country);
        }
        return;
      }
      var pingBtn = e.target.closest("[data-direct-ping]");
      if (pingBtn) {
        e.stopPropagation();
        pingBtn.classList.add("is-spinning");
        window.setTimeout(function () {
          pingBtn.classList.remove("is-spinning");
        }, 500);
        return;
      }
      var cardItem = e.target.closest("[data-spec-pid]");
      if (cardItem) {
        var clickedPid = cardItem.getAttribute("data-spec-pid");
        if (clickedPid && clickedPid !== state.frontPid) {
          state.frontPid = clickedPid;
          updateSpecimen();
        }
      }
    });
  }

  function updateSpecimen() {
    ensureSpecimenMounted();
    var host = document.getElementById("eg-specimen");
    if (!host) return;

    SPEC_CARDS.forEach(function (spec) {
      var itemEl = host.querySelector('[data-spec-pid="' + spec.pid + '"]');
      if (!itemEl) return;
      var isFront = spec.pid === state.frontPid;
      itemEl.classList.toggle("is-front", isFront);
      itemEl.classList.toggle("is-back", !isFront);

      var info = infoFor(spec.pid);
      var isBlocked = Boolean(info && info.blocked && info.channel);

      var provEl = itemEl.querySelector(".eg-pprov");
      var rightEl = itemEl.querySelector(".eg-pprov__right");
      var issueWrap = itemEl.querySelector(".eg-issue-wrap");
      var issueTitle = itemEl.querySelector(".eg-issue__title");
      var issueDesc = itemEl.querySelector(".eg-issue__desc");
      var subfoot = itemEl.querySelector(".eg-psubfoot");

      if (provEl) provEl.classList.toggle("eg-pprov--blocked", isBlocked);
      if (issueWrap) issueWrap.classList.toggle("is-open", isBlocked);
      if (info && info.cardTitle && issueTitle) issueTitle.textContent = info.cardTitle;
      if (info && info.desc && issueDesc) issueDesc.textContent = info.desc;

      if (rightEl) {
        if (info && info.channel) {
          var spin = state.probingCountry === info.channel.country ? " is-spinning" : "";
          rightEl.innerHTML =
            '<span class="eg-pflag' + (isBlocked ? " is-blocked" : "") + '">' + info.channel.flag + "</span>" +
            '<button type="button" class="eg-picon' + spin + '" data-act="retest" aria-label="重测出口">' +
            RETEST_SVG +
            "</button>";
        } else {
          rightEl.innerHTML =
            '<button type="button" class="eg-picon" data-direct-ping="' + spec.pid + '" aria-label="刷新">' +
            RETEST_SVG +
            "</button>";
        }
      }

      itemEl.querySelectorAll(".eg-pwin__when").forEach(function (whenEl) {
        var normal = whenEl.getAttribute("data-normal") || "";
        whenEl.textContent = isBlocked ? "已拦截" : normal;
        whenEl.classList.toggle("eg-pwin__when--blocked", isBlocked);
      });

      if (subfoot) {
        if (isBlocked) {
          subfoot.className = "eg-psubfoot";
          subfoot.textContent = "上次成功 17:13";
        } else {
          var ip = info && (info.maskedIp || (info.channel && info.channel.maskedIp));
          if (info && info.channel && ip) {
            subfoot.className = "eg-psubfoot eg-psubfoot--pass";
            subfoot.textContent = "出口校验通过 · " + info.channel.flag + " " + ip;
          } else {
            subfoot.className = "eg-psubfoot";
            subfoot.textContent = "未启用出口校验 · 直连放行";
          }
        }
      }
    });
  }

  /* ---------- Persistent Fluent Settings Window & Smooth Sheet ------ */
  function renderWizardBodyHtml() {
    var d = state.wizard;
    var used = state.channels.map(function (c) {
      return c.country;
    });
    var code = (d.customIso || d.country || "").toUpperCase();

    var countries = COUNTRIES.map(function (c) {
      var dis = used.indexOf(c.code) !== -1;
      var sel = !d.customIso && d.country === c.code;
      return (
        '<button type="button" class="eg-country-btn' + (sel ? " is-selected" : "") + '"' + (dis ? " disabled" : "") + ' data-wc="' + c.code + '">' +
        '<span class="flag">' + c.flag + "</span>" +
        '<span class="meta"><b>' + c.name + "</b><span>" + c.code + "</span></span>" +
        (sel ? '<span class="chk">✓</span>' : "") +
        "</button>"
      );
    }).join("");

    var svcs = PROVIDER_LIST.map(function (pid) {
      var p = PROVIDERS[pid];
      var pk = d.providers.indexOf(pid) !== -1;
      var ch = findChannel(pid);
      return (
        '<button type="button" class="eg-svc-pick' + (pk ? " is-picked" : "") + '" data-ws="' + pid + '">' +
        '<span class="eg-svc-pick__box">' + (pk ? "✓" : "") + "</span>" +
        badgeHtml(pid, 16) +
        "<span>" + p.name + "</span>" +
        '<span class="eg-svc-pick__tag' + (ch ? " is-assigned" : "") + '">' + (ch ? ch.flag + " " + ch.country : "未分配") + "</span>" +
        "</button>"
      );
    }).join("");

    return (
      '<div class="eg-sheet__head"><h4 id="eg-w-title">新建出口通道</h4><button type="button" data-w-act="close" aria-label="关闭">✕</button></div>' +
      '<div><div class="eg-step-head"><span class="eg-step-title">1. 目标出口国家</span><label class="eg-custom-iso">自定义代码: <input id="eg-w-iso" maxlength="2" placeholder="FR" value="' + esc(d.customIso) + '" /></label></div><div class="eg-country-grid">' + countries + "</div></div>" +
      '<div><div class="eg-step-head"><span class="eg-step-title">2. 代理端口</span><span class="eg-step-hint" id="eg-w-port-hint">目标 ' + esc(code || "??") + '</span></div><div class="eg-port-row"><div class="eg-port"><span class="eg-port__k">PORT</span><input class="eg-port__in" id="eg-w-port" value="' + esc(d.port) + '" /></div><button type="button" class="eg-scan-pill" data-w-act="scan">' + SCAN_SVG + "<span>填入本机监听端口 7897</span></button></div></div>" +
      '<div><div class="eg-step-head"><span class="eg-step-title">3. 保护服务 (可选)</span><span class="eg-step-hint">勾选的服务将强制经此通道查额</span></div><div class="eg-svc-grid">' + svcs + "</div></div>" +
      (d.error ? '<p class="eg-sheet__err" id="eg-w-err">' + esc(d.error) + "</p>" : "") +
      '<div class="eg-sheet__foot"><button type="button" class="eg-fbtn" data-w-act="close">取消</button><button type="button" class="eg-fbtn eg-fbtn--primary" data-w-act="submit">创建并测试通道</button></div>'
    );
  }

  function renderTilesHtml() {
    if (!state.channels.length) {
      return '<div style="padding:14px;text-align:center;color:#7a7a7a">暂无通道，点击下方新建。</div>';
    }
    return state.channels
      .map(function (ch) {
        var vis = ch.providers.slice(0, 3);
        var over = ch.providers.length - vis.length;
        var cand = PROVIDER_LIST.filter(function (pid) {
          return ch.providers.indexOf(pid) === -1;
        });
        var pop = state.openPopoverCountry === ch.country;

        var badges =
          vis
            .map(function (pid) {
              var p = PROVIDERS[pid];
              return (
                '<button type="button" class="eg-svc-badge" style="background:' + p.color + ';color:#fff" data-rem="' + ch.country + ":" + pid + '" title="' + esc(p.name) + ' · 点击移出通道" aria-label="从 ' + ch.country + " 通道移出 " + esc(p.name) + '">' +
                p.glyph +
                '<span class="eg-svc-badge__x" aria-hidden="true">×</span></button>'
              );
            })
            .join("") + (over > 0 ? '<span class="eg-svc-overflow">+' + over + "</span>" : "");

        var popHtml = pop
          ? '<div class="eg-popover is-entering"><div class="eg-popover__title">分配受保护服务</div>' +
            (cand.length
              ? cand
                  .map(function (pid) {
                    var p = PROVIDERS[pid];
                    var other = findChannel(pid);
                    return (
                      '<button type="button" class="eg-popover__item" data-ass="' + ch.country + ":" + pid + '">' +
                      badgeHtml(pid, 16) +
                      "<span>" + p.name + "</span>" +
                      (other ? '<span class="eg-popover__hint">移自 ' + other.country + "</span>" : "") +
                      "</button>"
                    );
                  })
                  .join("")
              : '<div style="font-size:12px;color:#777;padding:4px 6px">已全部分配至此通道</div>') +
            "</div>"
          : "";

        return (
          '<div class="eg-tile" data-channel="' + ch.country + '">' +
          '<span class="eg-tile__flag">' + ch.flag + "</span>" +
          '<div class="eg-tile__info"><div class="eg-tile__name">' + ch.name + " (" + ch.country + ')</div><div class="eg-tile__status" data-level="' + ch.statusLevel + '"><span class="eg-dot"></span><span>' + esc(ch.statusText) + "</span></div></div>" +
          '<div class="eg-tile__right">' +
          '<div class="eg-port"><span class="eg-port__k">PORT</span><input class="eg-port__in" aria-label="' + ch.name + '通道端口" value="' + esc(ch.port) + '" data-port="' + ch.country + '" /></div>' +
          '<span class="eg-vsep" aria-hidden="true"></span>' +
          '<div class="eg-cluster">' + badges + '<button type="button" class="eg-svc-add" data-pop="' + ch.country + '" aria-label="向 ' + ch.country + ' 通道添加服务">+</button>' + popHtml + "</div>" +
          '<span class="eg-vsep" aria-hidden="true"></span>' +
          '<div class="eg-actions"><button type="button" class="eg-btn' + (state.probingCountry === ch.country ? " is-spinning" : "") + '" data-test="' + ch.country + '" title="探测通道" aria-label="探测 ' + ch.country + ' 通道">' + RETEST_SVG + '</button><button type="button" class="eg-btn eg-btn--danger" data-del="' + ch.country + '" title="删除通道" aria-label="删除 ' + ch.country + ' 通道">' + TRASH_SVG + "</button></div>" +
          "</div>" +
          "</div>"
        );
      })
      .join("");
  }

  function ensureSettingsMounted() {
    var host = document.getElementById("eg-settings");
    if (!host || host.dataset.mounted) return;

    host.innerHTML =
      '<div class="eg-fl-win" id="eg-fl-win">' +
      '<div class="eg-fl-titlebar"><div class="eg-fl-lights" aria-hidden="true"><i></i><i></i><i></i></div><span class="eg-fl-titlebar__name">Bruce 设置</span><span class="eg-fl-titlebar__crumb">订阅额度 › 出口IP检查</span></div>' +
      '<div class="eg-fl-pane">' +
      '<div class="eg-win-toprow"><div><p class="eg-fl-crumb">设置 › 订阅额度</p><h3 class="eg-fl-h1">订阅额度与网络出口保护</h3></div><span class="eg-cred-inline"><i></i>云端凭据有效 · 拦截不伤登录态</span></div>' +
      '<div class="eg-sec" id="eg-sec">' +
      '<div class="eg-sec__head"><span class="eg-sec__title">出口IP检查</span><span class="eg-sec__count" id="eg-sec-count"></span></div>' +
      '<p class="eg-sec__desc">受保护的订阅服务通过出口校验后方可查询余额。</p>' +
      '<div class="eg-fl-card" id="eg-tiles-box"></div>' +
      '<button type="button" class="eg-dashed-add" id="eg-btn-create"><span class="eg-dashed-add__plus">+</span><span class="eg-dashed-add__text"><b>新建出口通道</b><span>配置国家、代理端口与受保护服务</span></span><span class="eg-dashed-add__chev" aria-hidden="true">›</span></button>' +
      "</div>" +
      "</div>" +
      '<div class="eg-sheet-backdrop" id="eg-backdrop" aria-hidden="true">' +
      '<div class="eg-sheet" id="eg-sheet" role="dialog" aria-modal="true" aria-labelledby="eg-w-title"></div>' +
      "</div>" +
      "</div>";

    host.dataset.mounted = "1";

    /* Event delegation on persistent settings window */
    host.addEventListener("click", function (e) {
      if (e.target.closest("#eg-btn-create")) {
        openModal();
        return;
      }
      var testBtn = e.target.closest("[data-test]");
      if (testBtn) {
        testRoute(testBtn.getAttribute("data-test"));
        return;
      }
      var delBtn = e.target.closest("[data-del]");
      if (delBtn) {
        var delCode = delBtn.getAttribute("data-del");
        state.channels = state.channels.filter(function (x) {
          return x.country !== delCode;
        });
        updateAll();
        return;
      }
      var remBtn = e.target.closest("[data-rem]");
      if (remBtn) {
        var pts = remBtn.getAttribute("data-rem").split(":");
        var ch = state.channels.find(function (c) {
          return c.country === pts[0];
        });
        if (ch) {
          ch.providers = ch.providers.filter(function (p) {
            return p !== pts[1];
          });
        }
        updateAll();
        return;
      }
      var popBtn = e.target.closest("[data-pop]");
      if (popBtn) {
        e.stopPropagation();
        var c = popBtn.getAttribute("data-pop");
        state.openPopoverCountry = state.openPopoverCountry === c ? null : c;
        updateSettingsView(false);
        return;
      }
      var assBtn = e.target.closest("[data-ass]");
      if (assBtn) {
        e.stopPropagation();
        var apts = assBtn.getAttribute("data-ass").split(":");
        state.channels.forEach(function (chItem) {
          chItem.providers = chItem.providers.filter(function (p) {
            return p !== apts[1];
          });
        });
        var target = state.channels.find(function (chItem) {
          return chItem.country === apts[0];
        });
        if (target) target.providers.push(apts[1]);
        state.openPopoverCountry = null;
        updateAll();
        return;
      }

      /* Wizard modal actions */
      var backdrop = document.getElementById("eg-backdrop");
      if (state.modalOpen && e.target === backdrop) {
        closeModal();
        return;
      }
      var wAct = e.target.closest("[data-w-act]");
      if (wAct) {
        var kind = wAct.getAttribute("data-w-act");
        if (kind === "close") {
          closeModal();
        } else if (kind === "scan") {
          state.wizard.port = "7897";
          state.wizard.error = "";
          refreshWizardSheet();
        } else if (kind === "submit") {
          submitWizard();
        }
        return;
      }
      var wcBtn = e.target.closest("[data-wc]");
      if (wcBtn && !wcBtn.disabled) {
        state.wizard.country = wcBtn.getAttribute("data-wc");
        state.wizard.customIso = "";
        state.wizard.error = "";
        refreshWizardSheet();
        return;
      }
      var wsBtn = e.target.closest("[data-ws]");
      if (wsBtn) {
        var sid = wsBtn.getAttribute("data-ws");
        var arr = state.wizard.providers;
        var idx = arr.indexOf(sid);
        if (idx === -1) arr.push(sid);
        else arr.splice(idx, 1);
        refreshWizardSheet();
      }
    });

    host.addEventListener("input", function (e) {
      var inp = e.target;
      if (inp.hasAttribute("data-port")) {
        var code = inp.getAttribute("data-port");
        var clean = inp.value.replace(/\D/g, "").slice(0, 5);
        if (inp.value !== clean) inp.value = clean;
        var ch = state.channels.find(function (c) {
          return c.country === code;
        });
        if (!ch) return;
        ch.port = clean;
        ch.statusLevel = "off";
        ch.statusText = "127.0.0.1:" + (ch.port || "----") + " · 点击右侧重测";
        ch.maskedIp = null;
        var tile = inp.closest(".eg-tile");
        var st = tile && tile.querySelector(".eg-tile__status");
        if (st) {
          st.setAttribute("data-level", "off");
          st.innerHTML = '<span class="eg-dot"></span><span>' + esc(ch.statusText) + "</span>";
        }
        updateSpecimen();
        syncNoteVisibility();
        return;
      }
      if (inp.id === "eg-w-iso") {
        var val = inp.value.replace(/[^a-zA-Z]/g, "").toUpperCase().slice(0, 2);
        if (inp.value !== val) inp.value = val;
        state.wizard.customIso = val;
        state.wizard.error = "";
        var hint = document.getElementById("eg-w-port-hint");
        if (hint) hint.textContent = "目标 " + (val || state.wizard.country || "??").toUpperCase();
        var err = document.getElementById("eg-w-err");
        if (err) err.remove();
        host.querySelectorAll("[data-wc]").forEach(function (b) {
          var on = !val && b.getAttribute("data-wc") === state.wizard.country;
          b.classList.toggle("is-selected", on);
          var chk = b.querySelector(".chk");
          if (on && !chk) {
            chk = document.createElement("span");
            chk.className = "chk";
            chk.textContent = "✓";
            b.appendChild(chk);
          } else if (!on && chk) {
            chk.remove();
          }
        });
        return;
      }
      if (inp.id === "eg-w-port") {
        var pval = inp.value.replace(/\D/g, "").slice(0, 5);
        if (inp.value !== pval) inp.value = pval;
        state.wizard.port = pval;
        state.wizard.error = "";
        var perr = document.getElementById("eg-w-err");
        if (perr) perr.remove();
      }
    });
  }

  function refreshWizardSheet() {
    var sheet = document.getElementById("eg-sheet");
    if (sheet) sheet.innerHTML = renderWizardBodyHtml();
  }

  function syncModalState(refreshBody) {
    var win = document.getElementById("eg-fl-win");
    var backdrop = document.getElementById("eg-backdrop");
    if (refreshBody) refreshWizardSheet();
    if (win) win.classList.toggle("has-modal", state.modalOpen);
    if (backdrop) {
      backdrop.classList.toggle("is-open", state.modalOpen);
      backdrop.setAttribute("aria-hidden", state.modalOpen ? "false" : "true");
    }
  }

  function syncSettingsHighlight() {
    var sec = document.getElementById("eg-sec");
    if (sec) sec.classList.toggle("is-highlighted", state.highlightSettings);
  }

  function submitWizard() {
    var d = state.wizard;
    var iso = (d.customIso || d.country || "").trim().toUpperCase();
    if (!/^[A-Z]{2}$/.test(iso)) {
      d.error = "请输入 2 位国家代码（如 SG / FR）";
      refreshWizardSheet();
      return;
    }
    if (
      state.channels.some(function (c) {
        return c.country === iso;
      })
    ) {
      d.error = iso + " 通道已存在";
      refreshWizardSheet();
      return;
    }
    var pn = parseInt(d.port, 10);
    if (isNaN(pn) || pn < 1 || pn > 65535) {
      d.error = "端口必须为 1–65535 的整数";
      refreshWizardSheet();
      return;
    }
    d.providers.forEach(function (pid) {
      state.channels.forEach(function (c) {
        c.providers = c.providers.filter(function (x) {
          return x !== pid;
        });
      });
    });
    var meta = countryMeta(iso);
    state.channels.push({
      country: iso,
      name: meta.name,
      flag: meta.flag,
      port: String(pn),
      defaultPort: String(pn),
      providers: d.providers.slice(),
      statusLevel: "warn",
      statusText: "正在探测出口线路…",
      maskedIp: null,
    });
    state.modalOpen = false;
    updateAll();
    testRoute(iso);
  }

  function updateSettingsView(refreshModalBody) {
    ensureSettingsMounted();
    var countEl = document.getElementById("eg-sec-count");
    var tilesBox = document.getElementById("eg-tiles-box");
    if (countEl) countEl.textContent = "已激活 " + state.channels.length + " 个通道";
    if (tilesBox) tilesBox.innerHTML = renderTilesHtml();
    syncSettingsHighlight();
    syncModalState(Boolean(refreshModalBody));
  }

  function syncNoteVisibility() {
    var note = document.getElementById("eg-sync-note");
    if (!note) return;
    var jp = state.channels.find(function (c) {
      return c.country === "JP";
    });
    var show = state.scenario === "ok" && jp && jp.statusLevel === "ok";
    if (show) {
      if (note.hasAttribute("hidden")) {
        note.removeAttribute("hidden");
        requestAnimationFrame(function () {
          note.classList.add("is-visible");
        });
      } else {
        note.classList.add("is-visible");
      }
    } else {
      note.classList.remove("is-visible");
      note.setAttribute("hidden", "");
    }
  }

  function updateAll() {
    updateSpecimen();
    updateSettingsView(false);
    syncNoteVisibility();
  }

  document.addEventListener("click", function (e) {
    if (state.openPopoverCountry && !e.target.closest(".eg-popover") && !e.target.closest("[data-pop]")) {
      state.openPopoverCountry = null;
      updateSettingsView(false);
    }
  });

  if (document.getElementById("eg-specimen") && document.getElementById("eg-settings")) {
    updateAll();
  }
})();
