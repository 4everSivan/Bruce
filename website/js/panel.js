/* ============================================================
   BRUCE — official site
   panel.js : 1:1 DOM reconstruction & choreographed transitions for
              the 22pt menu-bar status item, hero 3-card deck, and
              Section 01 interactive popover.
   ============================================================ */
(function () {
  "use strict";

  var D = window.BRUCE_DATA;
  var deck = document.getElementById("panel-deck");
  if (!deck || !D) return;

  var THEMES = ["classic", "liquid", "nothing"];
  var slotOrder = ["nothing", "liquid", "classic"]; /* slot 0 (back) -> slot 2 (front) */
  var DECK_W = 776;
  var STEP_Y = 42;
  var CARD_LABEL = { token: "Token 用量", quota: "订阅用量", hourly: "Agent 用量" };
  var CARD_INDEX = { token: 0, quota: 1, hourly: 2 };
  var narrowMq = window.matchMedia("(max-width: 720px)");
  var reduceMq = window.matchMedia("(prefers-reduced-motion: reduce)");
  var front = "classic";

  var switcher = document.getElementById("deck-switcher");
  var switcherBtns = Array.prototype.slice.call(
    document.querySelectorAll("[data-focus-theme]")
  );
  var switcherGlider = null;

  function slot(theme) {
    return document.getElementById("panel-" + theme);
  }

  function item(theme) {
    var el = slot(theme);
    return el ? el.closest(".deck__item") : null;
  }

  function sheet(theme) {
    var el = slot(theme);
    return el ? el.closest(".deck__sheet") : null;
  }

  var M = "classic";
  var CARD = { nothing: "token", liquid: "hourly", classic: "quota" };

  /* ---------- 01 看板：可交互的卡片预览 ----------------------------- */
  var ANATOMY_THEMES = { token: "nothing", quota: "classic", hourly: "liquid" };
  var anatomyPanel = document.getElementById("anatomy-panel");
  var anatomyBox = document.getElementById("anatomy-panelbox");
  var anatomyStage = document.getElementById("anatomy-stage");
  var anatomyMenubar = document.getElementById("anatomy-menubar");
  var heroMenubar = document.getElementById("hero-menubar");
  var anatomyTabsWrap = document.querySelector(".anatomy__tabs");
  var anatomyTabs = Array.prototype.slice.call(
    document.querySelectorAll(".anatomy__tabs [data-anatomy-card]")
  );
  var anatomyGlider = null;
  var anatomyCard = "token";
  var activeLayer = null;

  /* ---------- formatters ------------------------------------------ */
  function trim(s) {
    return String(parseFloat(s));
  }
  function fmtTokens(n) {
    if (n < 1e3) return String(Math.round(n));
    if (n < 1e6) return trim((n / 1e3).toFixed(1)) + "K";
    if (n < 1e9) return trim((n / 1e6).toFixed(1)) + "M";
    return trim((n / 1e9).toFixed(2)) + "B";
  }
  function fmtCost(n) {
    var s = n.toFixed(3);
    if (s.endsWith("0")) s = n.toFixed(2);
    return "≈ ¥" + s;
  }

  /* ---------- 22pt 菜单栏状态项（system-spec.md §1.3–1.8） ---------- */
  function orbitGaugeSvg(ratio) {
    var r = 6.4;
    var cx = 11;
    var cy = 11;
    var circ = 2 * Math.PI * r;
    var dash = (ratio * circ).toFixed(2);
    var angle = -Math.PI / 2 + ratio * Math.PI * 2;
    var sx = (cx + r * Math.cos(angle)).toFixed(2);
    var sy = (cy + r * Math.sin(angle)).toFixed(2);
    return (
      '<svg class="mb-orbit" width="22" height="22" viewBox="0 0 22 22" aria-hidden="true">' +
      '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="rgba(22,21,15,0.18)" stroke-width="1.4"/>' +
      '<circle class="mb-orbit__arc" cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="#15803d" stroke-width="1.4" stroke-linecap="round"' +
      ' style="--arc-circ:' + circ.toFixed(2) + ';--arc-dash:' + dash + '"' +
      ' stroke-dasharray="' + dash + " " + circ.toFixed(2) + '" transform="rotate(-90 ' + cx + " " + cy + ')"/>' +
      '<circle class="mb-orbit__sat" cx="' + sx + '" cy="' + sy + '" r="1.9" fill="#15803d"/>' +
      '<circle class="mb-orbit__core" cx="' + sx + '" cy="' + sy + '" r="0.75" fill="#ffffff"/>' +
      "</svg>"
    );
  }

  function statusItemPillHtml(theme, active) {
    var isNothing = theme === "nothing";
    var sep = isNothing ? '<span class="mb-sep">/</span>' : '<span class="mb-gap"></span>';
    return (
      '<span class="mb-pill' + (isNothing ? " is-nothing" : "") + (active ? " is-open" : "") + '">' +
      orbitGaugeSvg(0.62) +
      '<span class="mb-metrics num">' +
      "<span>62%</span>" + sep +
      "<span>586.6M</span>" + sep +
      "<span>$46.41</span>" +
      "</span>" +
      "</span>"
    );
  }

  function renderHeroMenubar() {
    if (!heroMenubar) return;
    heroMenubar.innerHTML = statusItemPillHtml("classic", false);
  }

  function updateAnatomyMenubar(theme) {
    if (!anatomyMenubar) return;
    var skinText = theme === "nothing" ? "Nothing" : theme === "liquid" ? "液态玻璃" : "经典";
    var isNothing = theme === "nothing";

    if (!anatomyMenubar.dataset.mounted) {
      var wifiSvg =
        '<svg width="13" height="10" viewBox="0 0 15 11" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" aria-hidden="true">' +
        '<path d="M1.4 3.6a9.2 9.2 0 0 1 12.2 0"/><path d="M3.6 6a6 6 0 0 1 7.8 0"/><path d="M5.9 8.4a2.8 2.8 0 0 1 3.2 0"/><circle cx="7.5" cy="10.1" r="0.7" fill="currentColor" stroke="none"/></svg>';
      var batSvg =
        '<svg width="19" height="10" viewBox="0 0 21 11" fill="none" aria-hidden="true">' +
        '<rect x="0.7" y="1" width="17.2" height="9" rx="2.2" stroke="currentColor" stroke-width="1.1" opacity="0.55"/>' +
        '<rect x="2.2" y="2.5" width="12.6" height="6" rx="1.1" fill="currentColor" opacity="0.75"/>' +
        '<path d="M19.2 3.8a1.6 1.6 0 0 1 0 3.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" opacity="0.5"/></svg>';
      anatomyMenubar.innerHTML =
        '<span class="menubar-bar__tag">macOS 菜单栏 · <b class="menubar-bar__skin">' + skinText + "</b></span>" +
        '<div class="menubar-bar__right">' +
        statusItemPillHtml(theme, true) +
        '<span class="menubar-bar__sys" aria-hidden="true">' + wifiSvg + batSvg + '<span class="num">15:52</span></span>' +
        "</div>";
      anatomyMenubar.dataset.mounted = "1";
      return;
    }

    var skinNode = anatomyMenubar.querySelector(".menubar-bar__skin");
    var pillNode = anatomyMenubar.querySelector(".mb-pill");
    if (skinNode && skinNode.textContent !== skinText) {
      skinNode.classList.remove("is-swap");
      void skinNode.offsetWidth;
      skinNode.textContent = skinText;
      skinNode.classList.add("is-swap");
    }
    if (pillNode) {
      pillNode.classList.toggle("is-nothing", isNothing);
      var metricsNode = pillNode.querySelector(".mb-metrics");
      if (metricsNode) {
        var sep = isNothing ? '<span class="mb-sep">/</span>' : '<span class="mb-gap"></span>';
        metricsNode.innerHTML = "<span>62%</span>" + sep + "<span>586.6M</span>" + sep + "<span>$46.41</span>";
      }
      pillNode.classList.remove("is-pulse");
      void pillNode.offsetWidth;
      pillNode.classList.add("is-pulse");
    }
  }

  /* ---------- icons ------------------------------------------------ */
  var ICON = {
    refresh:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M10 6a4 4 0 1 1-1.2-2.9"/><path d="M10 1.6V4h-2.4"/></svg>',
    appearance:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="6" cy="6" r="4.4"/><path d="M6 1.6a4.4 4.4 0 0 1 0 8.8z" fill="currentColor" stroke="none"/></svg>',
    gear:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round"><path d="M2 3.6h8M2 8.4h8"/><circle cx="4.3" cy="3.6" r="1.25"/><circle cx="7.7" cy="8.4" r="1.25"/></svg>',
    power:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M4 2.6a4.2 4.2 0 1 0 4 0"/><path d="M6 1.4v4.2"/></svg>',
    chevron:
      '<svg viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 1.6 6 4.5 3 7.4"/></svg>',
    chevdown:
      '<svg viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1.6 3.2 4.5 6.2 7.4 3.2"/></svg>',
    bar:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M2 10V7M6 10V3M10 10V5"/></svg>',
    card:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="1.2" y="2.4" width="9.6" height="7.2" rx="1.4"/><path d="M1.2 5h9.6"/></svg>',
    wave:
      '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M1 6.4h1.6l1.2-3 1.6 6 1.4-4 1.2 2h2.9"/></svg>',
  };

  /* ---------- shared fragments ------------------------------------- */
  function cardHead(title, opts) {
    opts = opts || {};
    return (
      '<header class="bp-card__head">' +
      '<h3 class="bp-card__title">' + title + "</h3>" +
      (opts.aside || "") +
      "</header>"
    );
  }

  function card(key, head, body) {
    return (
      '<section class="bp-card" data-card="' + key + '">' +
      head +
      '<div class="bp-card__body"><div><div class="bp-fade">' + body + "</div></div></div>" +
      "</section>"
    );
  }

  /* ---------- 模型用量（token 卡第 6 行） -------------------------- */
  function modelBlock() {
    var rows = D.pricing.slice().sort(function (a, b) { return b.used - a.used; });
    var k = 1;
    var max = Math.max.apply(null, rows.map(function (r) { return r.used * k; }));
    var total = rows.reduce(function (a, r) { return a + r.used * k; }, 0);
    var list = rows.slice(0, 4);
    var body = list
      .map(function (r, idx) {
        var v = r.used * k;
        var share = Math.round((v / total) * 100);
        var tint = r.mark && r.mark.toLowerCase() !== "#ffffff" ? r.mark : r.tile;
        return (
          '<div class="bp-model">' +
          '<span class="bp-model__swatch" style="background:' + tint + '"></span>' +
          '<span class="bp-model__name">' + (r.id || r.name).toUpperCase() + "</span>" +
          '<span class="bp-model__bar"><i style="width:' + (v / max) * 100 +
          "%;background:" + tint + ";--d:" + (60 + idx * 45) + 'ms"></i></span>' +
          '<span class="bp-model__pct">' + share + "%</span>" +
          '<span class="bp-model__val">' + fmtTokens(v) + "</span>" +
          "</div>"
        );
      })
      .join("");
    var wins = [["1m", "本月"], ["3m", "3 月"], ["6m", "6 月"]]
      .map(function (w) {
        return '<span class="bp-win' + (w[0] === "3m" ? " is-on" : "") + '">' + w[1] + "</span>";
      })
      .join("");
    var more = '<span class="bp-models__more">共 ' + rows.length + " 款 · 按用量排序</span>";
    return (
      '<div class="bp-models">' +
      '<div class="bp-models__head"><span class="bp-models__title">模型用量' + ICON.chevdown + "</span>" +
      '<span class="bp-seg bp-seg--xs" role="group" aria-label="模型用量时间跨度">' + wins + "</span></div>" +
      body +
      more +
      "</div>"
    );
  }

  /* ---------- token card ------------------------------------------- */
  function tokenCard() {
    var t = D.token;
    var cells = [
      ["输入", fmtTokens(t.input)],
      ["输出", fmtTokens(t.output)],
      ["缓存读取", fmtTokens(t.cacheRead)],
      ["缓存命中率", t.hitRate + "%"],
    ]
      .map(function (c) {
        return "<div><dt>" + c[0] + "</dt><dd>" + c[1] + "</dd></div>";
      })
      .join("");

    var months = t.months
      .map(function (m) {
        return (
          '<div class="bp-month' + (m.current ? " is-current" : "") + '">' +
          '<span class="bp-month__k">' + m.k + "</span>" +
          '<span class="bp-month__v">' + m.v + "</span></div>"
        );
      })
      .join("");

    var cellsHt = "";
    D.heatmap.weeks.forEach(function (week, cIdx) {
      week.forEach(function (level, rIdx) {
        var delay = cIdx * 8 + rIdx * 4;
        cellsHt +=
          level === null
            ? '<span class="bp-heatmap__cell"></span>'
            : '<span class="bp-heatmap__cell" data-level="' + level + '" style="--cd:' + delay + 'ms" title="' + level + '/5"></span>';
      });
    });

    var legendSwatches = "";
    for (var l = 0; l <= 5; l += 1) {
      legendSwatches += '<i data-level="' + l + '"></i>';
    }

    var body =
      '<div class="bp-hero">' +
      '<span class="bp-hero__num">' + fmtTokens(t.total) + "</span>" +
      '<span class="bp-hero__unit">tokens</span>' +
      '<span class="bp-hero__cost">' + fmtCost(t.cost) + "</span>" +
      "</div>" +
      '<div class="bp-divider"></div>' +
      '<dl class="bp-breakdown">' + cells + "</dl>" +
      '<div class="bp-section"><span class="bp-section__title">按月 · 近 6 个月</span>' +
      '<span class="bp-section__meta">近半年 <b>' + t.halfYear + "</b> · 月均 <b>" + t.monthlyAvg + "</b></span></div>" +
      '<div class="bp-months">' + months + "</div>" +
      modelBlock() +
      '<div class="bp-heatmap"><div class="bp-heatmap__head"><span class="bp-section__title">热力图 · 近半年</span></div>' +
      '<div class="bp-heatmap__grid">' + cellsHt + "</div>" +
      '<div class="bp-heatmap__axis"><span>26/05/11</span>' +
      '<span class="bp-heatmap__legend">少' + legendSwatches + "多</span>" +
      "<span>26/11/04</span></div></div>";

    return card(
      "token",
      cardHead("Token 用量", {
        key: "token",
        aside: '<span class="bp-live"><i></i>LIVE</span>',
      }),
      body
    );
  }

  /* ---------- hourly card ------------------------------------------ */
  function hourlyCard(uid) {
    var H = D.hourly;
    var max = 0;
    H.bars.forEach(function (d) {
      if (d.total > max) max = d.total;
    });

    var cols;
    if (M === "nothing") {
      cols = H.bars
        .map(function (d) {
          var on = Math.max(1, Math.round((d.total / max) * 24));
          var cells = "";
          for (var i = 0; i < 24; i += 1) {
            cells += '<i class="bp-dot-cell' + (i >= 24 - on ? " is-on" : "") + '"></i>';
          }
          return (
            '<div class="bp-bars__col bp-bars__col--dots" title="' +
            fmtTokens(d.total) + ' tokens">' + cells + "</div>"
          );
        })
        .join("");
    } else {
      cols = H.bars
        .map(function (d, i) {
          var segs = "";
          d.parts
            .slice()
            .reverse()
            .forEach(function (p) {
              var h = Math.max(1, (p.tokens / max) * 65);
              segs +=
                '<span class="bp-bars__seg" style="height:' + h + "px;background:" + p.color +
                ";--d:" + i * 24 + 'ms"></span>';
            });
          return '<div class="bp-bars__col" title="' + fmtTokens(d.total) + ' tokens">' + segs + "</div>";
        })
        .join("");
    }

    var legend = H.agents
      .map(function (a) {
        return '<span><i style="background:' + a.color + '"></i>' + a.name + "</span>";
      })
      .join("");

    var rows = H.hourly
      .map(function (h, idx) {
        var open = idx === 0;
        var maxP = Math.max.apply(null, h.points);
        var pts = h.points.map(function (v, i) {
          var x = (i / 23) * 386;
          var y = 25 - (v / maxP) * 23;
          return x.toFixed(1) + "," + y.toFixed(1);
        });
        var gid = (uid || M) + "-ag" + idx;
        var lineColor = M === "nothing" ? "#1c8c3d" : h.color;
        var line =
          '<svg class="bp-agent__line" style="--d:' + (50 + idx * 45) + 'ms" viewBox="0 0 386 26" preserveAspectRatio="none" aria-hidden="true">' +
          "<defs><linearGradient id='" + gid + "' x1='0' y1='0' x2='0' y2='1'>" +
          "<stop offset='0' stop-color='" + lineColor + "' stop-opacity='0.18'/>" +
          "<stop offset='1' stop-color='" + lineColor + "' stop-opacity='0.02'/>" +
          "</linearGradient></defs>" +
          "<polygon fill='url(#" + gid + ")' points='0,26 " + pts.join(" ") + " 386,26'/>" +
          "<polyline fill='none' stroke='" + lineColor + "' stroke-width='1.5' stroke-linejoin='round' points='" + pts.join(" ") + "'/>" +
          "</svg>";

        var shares = [
          ["主模型", 58],
          ["次模型", 27],
          ["其他", 15],
        ];
        var shareBar = shares
          .map(function (s, i) {
            var c = [h.color, "#7bc6d9", "#c9c9c9"];
            return '<i style="width:' + s[1] + "%;background:" + c[i] + '"></i>';
          })
          .join("");
        var shareRows = shares
          .map(function (s) {
            return (
              '<div class="bp-share-row"><span>' + s[0] + "</span><b>" + s[1] + "% · " +
              fmtTokens((h.total * s[1]) / 100) + "</b></div>"
            );
          })
          .join("");

        return (
          '<div class="bp-agent' + (open ? " is-open" : "") + '">' +
          '<div class="bp-agent__head">' +
          '<span class="bp-badge" style="width:14px;height:14px;border-radius:3.8px;background:' +
          h.color + '">' + h.name.charAt(0) + "</span>" +
          '<span class="bp-agent__name">' + h.name + "</span>" +
          '<span class="bp-agent__chev">' + ICON.chevron + "</span>" +
          '<span class="bp-agent__total">' + fmtTokens(h.total) + "</span></div>" +
          line +
          '<div class="bp-agent__detail"><div><div class="bp-share">' + shareBar + "</div>" +
          shareRows + "</div></div></div>"
        );
      })
      .join("");

    var body =
      '<div class="bp-bars">' + cols + "</div>" +
      '<div class="bp-axis"><span>14 天前</span><span>7 天前</span><span>今天</span></div>' +
      '<div class="bp-legend">' + legend + "</div>" +
      '<div class="bp-hr-head"><span>逐小时</span><span>0 – 23 时</span></div>' +
      rows;

    return card("hourly", cardHead("Agent 用量", { key: "hourly" }), body);
  }

  /* ---------- subscription card ------------------------------------ */
  function windowRow(w, delayMs) {
    var level = w.used >= 80 ? "critical" : w.used >= 50 ? "warning" : "normal";
    var meter;
    var dStyle = delayMs != null ? ";--d:" + delayMs + "ms" : "";
    if (M === "nothing") {
      var total = 24;
      var on = Math.round((Math.min(100, w.used) / 100) * total);
      var cells = "";
      for (var i = 0; i < total; i += 1) {
        var cls = i < on ? " is-on" : "";
        if (i === on - 1 && on > 0) cls += " is-frontier";
        cells += '<i class="bp-seg-cell' + cls + '"></i>';
      }
      meter = '<span class="bp-meter bp-meter--seg" data-level="' + level + '">' + cells + "</span>";
    } else {
      meter =
        '<span class="bp-meter"><span class="bp-meter__fill" data-level="' + level +
        '" style="width:' + Math.min(100, w.used) + "%" + dStyle + '"></span></span>';
    }
    return (
      '<div class="bp-window">' +
      '<span class="bp-window__k">' + w.k + "</span>" +
      meter +
      '<span class="bp-window__pct">' + w.used + "%</span>" +
      '<span class="bp-window__when">' + (w.reset || "") + "</span>" +
      "</div>"
    );
  }

  function badge(p) {
    if (!p.icon) {
      return '<span class="bp-badge" style="background:' + p.color + '">' + p.monogram + "</span>";
    }
    return (
      '<span class="bp-badge" style="background:' + p.color + '">' +
      '<img class="bp-badge__glyph" src="assets/provider-icons/' + p.icon + '.svg" alt="" ' +
      'onerror="this.style.display=\'none\';this.nextElementSibling.style.display=\'block\'">' +
      '<span class="bp-badge__mono">' + p.monogram + "</span>" +
      "</span>"
    );
  }

  function providerBlock(p, pIdx) {
    var baseDelay = 30 + (pIdx || 0) * 45;
    var head =
      '<div class="bp-prov__head">' +
      badge(p) +
      '<span class="bp-prov__name">' + p.name + "</span>" +
      (p.accounts ? '<span class="bp-prov__chev">' + ICON.chevdown + "</span>" : "") +
      (p.accounts ? '<span class="bp-prov__count">' + p.accountCount + " 个账号</span>" : "") +
      '<span class="bp-icon">' + ICON.refresh + "</span></div>";

    var body = "";

    if (p.balance != null) {
      body =
        '<div class="bp-balance">' +
        '<div class="bp-balance__slot"><span class="bp-balance__k">可用余额</span>' +
        '<span class="bp-balance__v">¥ ' + p.balance.toFixed(2) + "</span></div>" +
        '<div class="bp-balance__slot"><span class="bp-balance__k">订阅状态</span>' +
        '<span class="bp-balance__status"><i></i>' + p.status + "</span></div>" +
        "</div>";
    } else if (p.accounts) {
      var accounts = p.accounts
        .map(function (a) {
          return (
            '<div class="bp-account"><div class="bp-account__head">' +
            '<span class="bp-account__name">' + a.name + "</span>" +
            (a.tag ? '<span class="bp-account__tag">' + a.tag + "</span>" : "") +
            "</div>" +
            a.windows.map(function (w, wIdx) { return windowRow(w, wIdx * 35); }).join("") +
            "</div>"
          );
        })
        .join("");

      body =
        windowRow(p.collapsed, baseDelay) +
        '<div class="bp-accounts"><div><div class="bp-accounts__inner">' + accounts + "</div></div></div>";
    } else {
      body = p.windows
        .map(function (w, wIdx) { return windowRow(w, baseDelay + wIdx * 30); })
        .join("");
    }

    return '<div class="bp-prov' + (p.accounts ? " bp-prov--multi" : "") + '">' + head + body + "</div>";
  }

  function quotaCard() {
    var s = D.subscriptions;
    var body =
      s.sections.map(providerBlock).join("") +
      '<div class="bp-subfoot"><span>' + s.updated + "</span></div>";
    return card("quota", cardHead("订阅用量", { key: "quota" }), body);
  }

  /* ---------- shell ------------------------------------------------- */
  var TABS = [
    ["token", "bar", "Token 用量"],
    ["quota", "card", "订阅用量"],
    ["hourly", "wave", "Agent 用量"],
  ];

  function header(cardName, interactive) {
    var tabs = TABS.map(function (t) {
      var active = t[0] === cardName;
      if (interactive) {
        return (
          '<button type="button" class="bp-tab' + (active ? " is-active" : "") + '"' +
          ' role="tab" aria-selected="' + (active ? "true" : "false") + '"' +
          ' data-anatomy-card="' + t[0] + '" aria-label="' + t[2] + '">' +
          ICON[t[1]] + "</button>"
        );
      }
      return (
        '<span class="bp-tab' + (active ? " is-active" : "") + '">' +
        ICON[t[1]] + "</span>"
      );
    }).join("");
    return (
      '<header class="bp-head"><span class="bp-dot"></span><span class="bp-brand">Bruce</span>' +
      '<div class="bp-head__right"><div class="bp-tabs"' +
      (interactive ? ' role="tablist" aria-label="切换卡片"' : ' aria-hidden="true"') +
      ">" +
      tabs +
      "</div></div></header>"
    );
  }

  function footer() {
    return (
      '<footer class="bp-foot">' +
      '<span class="bp-btn">' + ICON.refresh + "</span>" +
      '<span class="bp-btn">' + ICON.appearance + "</span>" +
      '<span class="bp-foot__spacer"></span>' +
      '<span class="bp-btn">' + ICON.gear + "</span>" +
      '<span class="bp-btn">' + ICON.power + "</span>" +
      "</footer>"
    );
  }

  var uidSeq = 0;
  function surface(material, cardName, opts) {
    M = material;
    uidSeq += 1;
    var body =
      cardName === "quota"
        ? quotaCard()
        : cardName === "hourly"
          ? hourlyCard("u" + uidSeq)
          : tokenCard();
    return (
      '<div class="bp-surface" data-material="' + material + '" data-layout="tabs">' +
      header(cardName, opts && opts.interactive) +
      '<div class="bp-cards">' + body + "</div>" +
      footer() +
      "</div>"
    );
  }

  /* ---------- Switcher & Anatomy Glider Indicators ------------------ */
  function ensureSwitcherGlider() {
    if (!switcher || switcherGlider) return;
    switcherGlider = document.createElement("span");
    switcherGlider.className = "deck-switcher__glider";
    switcherGlider.setAttribute("aria-hidden", "true");
    switcher.insertBefore(switcherGlider, switcher.firstChild);
  }

  function syncSwitcher() {
    ensureSwitcherGlider();
    var activeBtn = null;
    switcherBtns.forEach(function (btn) {
      var on = btn.getAttribute("data-focus-theme") === front;
      btn.classList.toggle("is-active", on);
      btn.setAttribute("aria-pressed", on ? "true" : "false");
      if (on) activeBtn = btn;
    });
    if (switcherGlider && activeBtn && switcher.offsetParent !== null) {
      switcherGlider.style.width = activeBtn.offsetWidth + "px";
      switcherGlider.style.height = activeBtn.offsetHeight + "px";
      switcherGlider.style.transform =
        "translate3d(" + activeBtn.offsetLeft + "px, " + activeBtn.offsetTop + "px, 0)";
      switcherGlider.style.opacity = "1";
    }
  }

  function ensureAnatomyGlider() {
    if (!anatomyTabsWrap || anatomyGlider) return;
    anatomyGlider = document.createElement("span");
    anatomyGlider.className = "anatomy__glider";
    anatomyGlider.setAttribute("aria-hidden", "true");
    anatomyTabsWrap.insertBefore(anatomyGlider, anatomyTabsWrap.firstChild);
  }

  function syncAnatomyGlider() {
    ensureAnatomyGlider();
    var currentTab = null;
    anatomyTabs.forEach(function (tab) {
      var on = tab.getAttribute("data-anatomy-card") === anatomyCard;
      tab.classList.toggle("is-current", on);
      tab.setAttribute("aria-selected", on ? "true" : "false");
      if (on) currentTab = tab;
    });
    if (anatomyGlider && currentTab) {
      anatomyGlider.style.height = currentTab.offsetHeight + "px";
      anatomyGlider.style.transform = "translate3d(0, " + currentTab.offsetTop + "px, 0)";
      anatomyGlider.style.opacity = "1";
    }
  }

  /* ---------- 首屏渲染与三档布局 ------------------------------------ */
  function render() {
    THEMES.forEach(function (theme) {
      var el = slot(theme);
      if (el) el.innerHTML = surface(theme, CARD[theme]);
      var it = item(theme);
      if (it) {
        var sIdx = slotOrder.indexOf(theme);
        it.setAttribute("data-slot", String(sIdx));
        it.style.setProperty("--slot", String(sIdx));
        it.classList.toggle("is-front", theme === front);
        it.classList.toggle("is-focus", theme === front);
        var label = it.querySelector(".deck__peek-v");
        if (label) label.textContent = CARD_LABEL[CARD[theme]] || "";
      }
    });
    syncSwitcher();
  }

  function layoutDeck() {
    var host = deck.parentElement;
    if (!host) return;

    if (narrowMq.matches) {
      host.setAttribute("data-mode", "thumb");
      var avail = host.clientWidth;
      var scale = Math.min(1, avail / 440);
      THEMES.forEach(function (theme) {
        var it = item(theme);
        var sh = sheet(theme);
        var panel = slot(theme);
        var on = theme === front;
        if (it) {
          it.classList.toggle("is-front", on);
          it.classList.remove("is-focus");
          var btn = it.querySelector(".deck__peek");
          if (btn) btn.setAttribute("aria-expanded", on ? "true" : "false");
        }
        if (!sh || !panel) return;
        if (!on) {
          sh.style.width = "";
          sh.style.height = "";
          panel.style.transform = "";
          return;
        }
        var h = panel.offsetHeight;
        sh.style.width = Math.round(440 * scale) + "px";
        sh.style.height = h ? Math.round(h * scale) + "px" : "";
        panel.style.transform = "scale(" + scale + ")";
      });
      deck.style.width = "";
      deck.style.height = "";
      deck.style.transform = "";
      host.style.height = "";
      syncSwitcher();
      return;
    }

    host.setAttribute("data-mode", "stack");
    var maxH = 0;
    THEMES.forEach(function (theme) {
      var it = item(theme);
      var sh = sheet(theme);
      var panel = slot(theme);
      var sIdx = slotOrder.indexOf(theme);
      if (it) {
        it.classList.remove("is-front");
        it.classList.toggle("is-focus", theme === front);
        it.setAttribute("data-slot", String(sIdx));
        it.style.setProperty("--slot", String(sIdx));
        var btn = it.querySelector(".deck__peek");
        if (btn) btn.setAttribute("aria-expanded", "false");
      }
      if (sh) {
        sh.style.width = "";
        sh.style.height = "";
      }
      if (panel) {
        panel.style.transform = "";
        maxH = Math.max(maxH, panel.offsetHeight);
      }
    });
    if (!maxH) maxH = 734;
    var naturalH = maxH + STEP_Y * 2;
    var deckScale = Math.min(1, host.clientWidth / DECK_W);
    deck.style.width = "";
    deck.style.height = naturalH + "px";
    deck.style.transform = "scale(" + deckScale + ")";
    host.style.height = Math.round(naturalH * deckScale) + "px";
    syncSwitcher();
  }

  function setFrontTheme(theme) {
    if (!theme || THEMES.indexOf(theme) === -1 || theme === front) return;
    front = theme;
    /* 将选中的主题顺滑发牌至前景槽位 (slot 2)，其余两张保持相对层级退居 0 / 1 */
    slotOrder = slotOrder.filter(function (t) { return t !== theme; }).concat([theme]);
    var promoted = item(theme);
    if (promoted && !narrowMq.matches && !reduceMq.matches) {
      promoted.classList.remove("is-promoting");
      void promoted.offsetWidth;
      promoted.classList.add("is-promoting");
      window.setTimeout(function () {
        promoted.classList.remove("is-promoting");
      }, 560);
    }
    layoutDeck();
  }

  /* ---------- 01 看板：丝滑双向切换 + 手风琴联动 ------------------- */
  function getAnatomyScale() {
    if (!anatomyStage) return 1;
    return Math.min(1, anatomyStage.clientWidth / 440);
  }

  function fitAnatomy() {
    if (!anatomyPanel || !anatomyBox || !anatomyStage) return;
    var scale = getAnatomyScale();
    var targetEl = activeLayer || anatomyPanel;
    anatomyPanel.style.setProperty("--panel-scale", "scale(" + scale + ")");
    if (activeLayer) {
      activeLayer.style.transform = "scale(" + scale + ")";
    } else {
      anatomyPanel.style.transform = "scale(" + scale + ")";
    }
    var rawH = targetEl.offsetHeight;
    anatomyBox.style.width = Math.round(440 * scale) + "px";
    anatomyBox.style.height = Math.round(rawH * scale) + "px";
    if (anatomyMenubar) {
      anatomyMenubar.style.width = Math.round(440 * scale) + "px";
    }
    syncAnatomyGlider();
  }

  function mountAnatomyCard(direction) {
    if (!anatomyPanel) return;
    var theme = ANATOMY_THEMES[anatomyCard] || "nothing";
    var scale = getAnatomyScale();

    /* anatomyPanel 本身不再整体缩放，改由内部 layer 承载缩放与进退场位移 */
    anatomyPanel.style.transform = "none";
    anatomyPanel.style.setProperty("--panel-scale", "scale(" + scale + ")");

    var nextLayer = document.createElement("div");
    nextLayer.className = "anatomy__panel-layer";
    nextLayer.style.transform = "scale(" + scale + ")";
    nextLayer.innerHTML = surface(theme, anatomyCard, { interactive: true });

    if (activeLayer && direction && !reduceMq.matches) {
      var prevLayer = activeLayer;
      prevLayer.classList.remove("is-entering-next", "is-entering-prev");
      prevLayer.classList.add(direction > 0 ? "is-leaving-next" : "is-leaving-prev");
      nextLayer.classList.add(direction > 0 ? "is-entering-next" : "is-entering-prev");
      anatomyPanel.appendChild(nextLayer);
      window.setTimeout(function () {
        if (prevLayer.parentNode === anatomyPanel) {
          anatomyPanel.removeChild(prevLayer);
        }
      }, 270);
      window.setTimeout(function () {
        nextLayer.classList.remove("is-entering-next", "is-entering-prev");
      }, 380);
    } else {
      anatomyPanel.innerHTML = "";
      anatomyPanel.appendChild(nextLayer);
    }

    activeLayer = nextLayer;
    updateAnatomyMenubar(theme);
    syncAnatomyGlider();

    if (anatomyStage) {
      anatomyStage.setAttribute("data-material", theme);
      anatomyStage.setAttribute("aria-labelledby", "anatomy-tab-" + anatomyCard);
    }
    fitAnatomy();
  }

  function selectAnatomy(cardName) {
    if (!cardName || cardName === anatomyCard) return;
    var prevIdx = CARD_INDEX[anatomyCard] || 0;
    var nextIdx = CARD_INDEX[cardName] || 0;
    var dir = nextIdx >= prevIdx ? 1 : -1;
    anatomyCard = cardName;
    mountAnatomyCard(dir);
  }

  anatomyTabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      selectAnatomy(tab.getAttribute("data-anatomy-card"));
    });
  });

  if (anatomyPanel) {
    anatomyPanel.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-anatomy-card]");
      if (btn && anatomyPanel.contains(btn)) {
        selectAnatomy(btn.getAttribute("data-anatomy-card"));
        return;
      }
      /* Agent 行展开/收起手风琴 */
      var agentHead = e.target.closest(".bp-agent__head");
      if (agentHead && anatomyPanel.contains(agentHead)) {
        var agentRow = agentHead.closest(".bp-agent");
        if (agentRow) {
          agentRow.classList.toggle("is-open");
          syncHeightDuringTransition();
        }
        return;
      }
      /* 刷新微图标点按旋转反馈 */
      var refreshIcon = e.target.closest(".bp-icon");
      if (refreshIcon && anatomyPanel.contains(refreshIcon)) {
        e.stopPropagation();
        refreshIcon.classList.add("is-spinning");
        window.setTimeout(function () {
          refreshIcon.classList.remove("is-spinning");
        }, 620);
        return;
      }
      /* 多账号订阅行展开/收起手风琴 */
      var provHead = e.target.closest(".bp-prov--multi .bp-prov__head");
      if (provHead && anatomyPanel.contains(provHead)) {
        var provBlock = provHead.closest(".bp-prov");
        if (provBlock) {
          provBlock.classList.toggle("is-open");
          syncHeightDuringTransition();
        }
      }
    });
  }

  var heightRaf = null;
  function syncHeightDuringTransition() {
    var start = performance.now();
    if (heightRaf) cancelAnimationFrame(heightRaf);
    if (anatomyBox) anatomyBox.classList.add("is-tracking-height");
    function step(now) {
      fitAnatomy();
      if (now - start < 340) {
        heightRaf = requestAnimationFrame(step);
      } else if (anatomyBox) {
        anatomyBox.classList.remove("is-tracking-height");
      }
    }
    heightRaf = requestAnimationFrame(step);
  }

  /* 移动端顶条切换 + 桌面端点击后排卡片发牌至前景 */
  deck.addEventListener("click", function (e) {
    var peek = e.target.closest(".deck__peek");
    if (peek && deck.contains(peek) && narrowMq.matches) {
      setFrontTheme(peek.getAttribute("data-deck-theme"));
      return;
    }
    if (!narrowMq.matches) {
      var clickedItem = e.target.closest(".deck__item");
      if (clickedItem && deck.contains(clickedItem)) {
        setFrontTheme(clickedItem.getAttribute("data-theme"));
      }
    }
  });

  switcherBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      setFrontTheme(btn.getAttribute("data-focus-theme"));
    });
  });

  function relayout() {
    layoutDeck();
    fitAnatomy();
  }

  window.addEventListener("resize", relayout);
  if (narrowMq.addEventListener) narrowMq.addEventListener("change", relayout);
  else if (narrowMq.addListener) narrowMq.addListener(relayout);

  renderHeroMenubar();
  render();
  layoutDeck();
  mountAnatomyCard(0);

  /* 首屏牌堆初始扇面入场完成后释放入场锁，避免干扰后续切换过渡 */
  deck.classList.add("is-booting");
  window.setTimeout(function () {
    deck.classList.remove("is-booting");
  }, 620);

  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(relayout);
  }
})();
