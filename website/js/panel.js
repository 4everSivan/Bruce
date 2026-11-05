/* ============================================================
   BRUCE — official site
   panel.js : static rebuild of the menu bar panel (three skins, three cards)
   Constants follow panel-spec.md: 440 panel, 14 radius,
   8 card radius, 15/13 card padding, 10 card gap.
   ============================================================ */
(function () {
  "use strict";

  var D = window.BRUCE_DATA;
  var deck = document.getElementById("panel-deck");
  if (!deck || !D) return;

  var THEMES = ["classic", "liquid", "nothing"];
  var DECK_W = 776;
  var STEP_X = 168;
  var STEP_Y = 42;
  var root = deck; /* 事件委托挂在整个牌堆上 */

  function slot(theme) {
    return document.getElementById("panel-" + theme);
  }

  var M = "classic";
  var CARD = { nothing: "token", liquid: "hourly", classic: "quota" };


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

  /* ---------- 模型用量（token 卡第 6 行，位置同源码） --------------- */
  function modelBlock() {
    var rows = D.pricing.slice().sort(function (a, b) { return b.used - a.used; });
    var k = 1; /* 固定 3 月窗口 */
    var max = Math.max.apply(null, rows.map(function (r) { return r.used * k; }));
    var total = rows.reduce(function (a, r) { return a + r.used * k; }, 0);
    var list = rows.slice(0, 4);
    var body = list
      .map(function (r) {
        var v = r.used * k;
        var share = Math.round((v / total) * 100);
        var tint = r.mark && r.mark.toLowerCase() !== "#ffffff" ? r.mark : r.tile;
        return (
          '<div class="bp-model">' +
          '<span class="bp-model__swatch" style="background:' + tint + '"></span>' +
          '<span class="bp-model__name">' + (r.id || r.name).toUpperCase() + "</span>" +
          '<span class="bp-model__bar"><i style="width:' + (v / max) * 100 +
          "%;background:" + tint + '"></i></span>' +
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
    var more = '<span class="bp-models__more">共 ' + rows.length + ' 款 · 按用量排序</span>';
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
          '<span class="bp-month__k">' + m.k + '</span>' +
          '<span class="bp-month__v">' + m.v + "</span></div>"
        );
      })
      .join("");

    /* heatmap: 26 columns × 7 rows, 0–5 scale, nulls after today */
    var cellsHt = "";
    D.heatmap.weeks.forEach(function (week) {
      week.forEach(function (level) {
        cellsHt +=
          level === null
            ? '<span class="bp-heatmap__cell"></span>'
            : '<span class="bp-heatmap__cell" data-level="' + level + '" title="' + level + '/5"></span>';
      });
    });

    var legendSwatches = "";
    for (var l = 1; l <= 5; l += 1) {
      legendSwatches += '<i data-level="' + l + '" style="background:' + levelColor(l) + '"></i>';
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

  function levelColor(l) {
    return ["", "#cbd9c7", "#a6c0a2", "#7ba077", "#4e7a52", "#2a4a31"][l];
  }

  /* ---------- hourly card ------------------------------------------ */
  function hourlyCard() {
    var H = D.hourly;
    var max = 0;
    H.bars.forEach(function (d) {
      if (d.total > max) max = d.total;
    });

    var cols;
    if (M === "nothing") {
      /* Nothing：每天 3×8 = 24 格点阵，从底往上填 */
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
          /* first agent sits at the bottom of the stack */
          d.parts
            .slice()
            .reverse()
            .forEach(function (p) {
              var h = Math.max(1, (p.tokens / max) * 65);
              segs +=
                '<span class="bp-bars__seg" style="height:' + h + 'px;background:' + p.color +
                ";--d:" + i * 30 + 'ms"></span>';
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
        var open = idx === 0; /* 第一行展开，卡片高度与其余两张对齐 */
        var maxP = Math.max.apply(null, h.points);
        var pts = h.points.map(function (v, i) {
          var x = (i / 23) * 386;
          var y = 25 - (v / maxP) * 23;
          return x.toFixed(1) + "," + y.toFixed(1);
        });
        var gid = "ag" + idx;
        var lineColor = M === "nothing" ? "#1c8c3d" : h.color;
        var line =
          '<svg class="bp-agent__line" viewBox="0 0 386 26" preserveAspectRatio="none" aria-hidden="true">' +
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
            var cols = [h.color, "#7bc6d9", "#c9c9c9"];
            return '<i style="width:' + s[1] + "%;background:" + cols[i] + '"></i>';
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
  function windowRow(w) {
    var level = w.used >= 80 ? "critical" : w.used >= 50 ? "warning" : "normal";
    var meter;
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
        '" style="width:' + Math.min(100, w.used) + '%"></span></span>';
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

  function providerBlock(p) {
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
            a.windows.map(windowRow).join("") +
            "</div>"
          );
        })
        .join("");

      body =
        windowRow(p.collapsed) +
        '<div class="bp-accounts"><div><div class="bp-accounts__inner">' + accounts + "</div></div></div>";
    } else {
      body = p.windows.map(windowRow).join("");
    }

    return (
      '<div class="bp-prov">' + head + body + "</div>"
    );
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

  function header(cardName) {
    return (
      '<header class="bp-head"><span class="bp-dot"></span><span class="bp-brand">Bruce</span>' +
      '<div class="bp-head__right"><div class="bp-tabs" aria-hidden="true">' +
      TABS.map(function (t) {
        return (
          '<span class="bp-tab' + (t[0] === cardName ? " is-active" : "") + '">' +
          ICON[t[1]] + "</span>"
        );
      }).join("") +
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

  function surface(material, cardName) {
    M = material;
    var body =
      cardName === "quota" ? quotaCard() : cardName === "hourly" ? hourlyCard() : tokenCard();
    return (
      '<div class="bp-surface" data-material="' + material + '" data-layout="tabs">' +
      header(cardName) +
      '<div class="bp-cards">' + body + "</div>" +
      footer() +
      "</div>"
    );
  }

  /* ---------- 静态渲染 ---------------------------------------------- */
  function render() {
    THEMES.forEach(function (theme) {
      var el = slot(theme);
      if (el) el.innerHTML = surface(theme, CARD[theme]);
    });
    sizeDeck();
  }

  function sizeDeck() {
    var maxH = 0;
    THEMES.forEach(function (theme) {
      var el = slot(theme);
      if (el) maxH = Math.max(maxH, el.offsetHeight);
    });
    if (maxH) deck.style.height = maxH + STEP_Y * 2 + "px";
  }

  function fit() {
    var host = deck.parentElement;
    if (!host) return;
    var narrow = window.innerWidth < 1100;
    var natural = narrow ? 440 : DECK_W;
    deck.style.zoom = Math.min(1, host.clientWidth / natural);
    if (narrow) deck.style.height = "";
  }

  window.addEventListener("resize", fit);

  render();
  fit();
})();
