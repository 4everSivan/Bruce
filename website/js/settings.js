/* ============================================================
   BRUCE — official site
   settings.js : interactive recreation of the settings window
   Layout, tokens and copy follow the Fluent chrome in the app.
   ============================================================ */
(function () {
  "use strict";

  var D = window.BRUCE_DATA;
  var root = document.getElementById("bruce-settings");
  if (!root) return;

  var state = { cat: "general" };

  /* ---------- formatters ------------------------------------------ */
  function compact(n) {
    if (n < 1000) return String(Math.round(n));
    if (n < 1e6) return (n / 1e3).toFixed(n >= 1e5 ? 0 : 1) + "K";
    return (n / 1e6).toFixed(n >= 1e8 ? 0 : 1) + "M";
  }
  function money(n) {
    return "¥" + n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  function pct(n) {
    return Math.round(n * 100) + "%";
  }

  /* ---------- tiny inline icons (stroke, 14px box) ---------------- */
  var GLYPH = {
    gear: '<circle cx="7" cy="7" r="2.3"/><path d="M7 1.4v1.5M7 11.1v1.5M1.4 7h1.5M11.1 7h1.5M3.1 3.1l1 1M9.9 9.9l1 1M10.9 3.1l-1 1M4.1 9.9l-1 1"/>',
    chart: '<path d="M2.2 12V8.4M5.6 12V4.6M9 12V6.8M12.4 12V2.6"/><path d="M1.4 12.6h12"/>',
    dollar: '<circle cx="7" cy="7" r="5.4"/><path d="M7 4v6M8.8 5.2c0-.7-.8-1.2-1.8-1.2s-1.8.5-1.8 1.2.8 1.2 1.8 1.2 1.8.5 1.8 1.2-.8 1.2-1.8 1.2-1.8-.5-1.8-1.2"/>',
    cloud: '<path d="M4.2 10.6a2.3 2.3 0 0 1 .4-4.6 3.2 3.2 0 0 1 6.1-.6 2.1 2.1 0 0 1 .4 4.2H4.6a2 2 0 0 1-.4.9z"/>',
    shield: '<path d="M7 1.6 2.6 3.3v3.4c0 2.6 1.8 4.6 4.4 5.7 2.6-1.1 4.4-3.1 4.4-5.7V3.3L7 1.6z"/><path d="m5 6.9 1.4 1.5L9.2 5.6"/>',
    wrench: '<path d="M9.7 1.9a3.1 3.1 0 0 0-3.9 4l-4 4 1.4 1.4 4-4a3.1 3.1 0 0 0 4-3.9l-2 2-1.5-1.5 2-2z"/>',
  };

  function ico(name) {
    return (
      '<svg viewBox="0 0 14 14" aria-hidden="true">' + GLYPH[name] + "</svg>"
    );
  }

  /* ---------- structural helpers ---------------------------------- */
  function sw(on) {
    return (
      '<button class="st-switch" role="switch" aria-checked="' +
      (on ? "true" : "false") +
      '" aria-label="Toggle"><span class="visually-hidden">Toggle</span></button>'
    );
  }

  function seg(options, active) {
    return (
      '<div class="st-seg" role="group">' +
      options
        .map(function (o) {
          return (
            '<button type="button" aria-pressed="' +
            (o === active ? "true" : "false") +
            '">' +
            o +
            "</button>"
          );
        })
        .join("") +
      "</div>"
    );
  }

  function row(title, sub, control) {
    return (
      '<div class="st-row"><div class="st-row__text"><div class="st-row__title">' +
      title +
      "</div>" +
      (sub ? '<div class="st-row__sub">' + sub + "</div>" : "") +
      '</div><div class="st-row__control">' +
      control +
      "</div></div>"
    );
  }

  function card(rows) {
    return '<div class="st-card">' + rows.join("") + "</div>";
  }

  function caption(text) {
    return '<div class="st-caption">' + text + "</div>";
  }

  /* ---------- panes ----------------------------------------------- */

  function paneGeneral() {
    var s = D.token;
    var rows = [];

    rows.push(row("配色模式", "立即作用于菜单栏面板与设置窗口", seg(["跟随系统", "浅色", "深色"], "浅色")));
    rows.push(row("界面风格", "经典、液态玻璃，或 Nothing 点阵控制台", seg(["经典", "液态玻璃", "Nothing"], "液态玻璃")));
    rows.push(row("模糊风格", "标准与通透为系统液态玻璃，哑光退化为材质质感", seg(["标准", "通透", "哑光"], "标准")));
    rows.push(row("界面动效", "关闭后全应用不做过渡动画；「始终播放」会忽略系统「减弱动态效果」", seg(["跟随系统", "始终播放", "始终关闭"], "跟随系统")));
    rows.push(row("仪表盘卡片布局", "纵向级联可滚轮纵览，或收进顶栏 Tab", seg(["纵向级联", "顶栏 Tab"], "纵向级联")));

    var refresh = [];
    refresh.push(row("刷新间隔", "订阅额度最短 3 分钟查询一次，遇 429 限流自动冷却", seg(["3 分钟", "6 分钟", "自定义"], "3 分钟")));
    refresh.push(row("锁屏暂停订阅刷新", "电脑锁屏期间暂停查询云端订阅额度", sw(true)));
    refresh.push(row("额度预警气泡", "额度紧缺时在菜单栏图标下方弹出提示微卡", sw(true)));
    refresh.push(row("开机自启动", "开机时自动启动 Bruce 并在后台常驻菜单栏", sw(false)));

    var metrics = [];
    metrics.push(
      '<div class="st-row"><div class="st-row__text"><div class="st-row__title">菜单栏实时预览</div>' +
        '<div class="st-row__sub">整枚图标是一张位图，任一指标变化时重绘</div></div>' +
        '<div class="st-row__control">' +
        '<div class="st-menubar-preview" id="preview-strip"></div>' +
        "</div></div>"
    );
    metrics.push(row("仅显示图标", "隐藏全部文本指标，只留高精度配额环规", sw(false)));
    metrics.push(row("菜单栏指标", "可拖拽排序，最多三项绘制在环规右侧", '<span class="st-value st-value--muted">最低剩余额度 · 今日 Token · 今日费用</span>'));

    return (
      '<p class="st-pane-lede">外观、刷新节奏与菜单栏指标。这里没有任何一项会离开这台机器。</p>' +
      caption("外观") + card(rows) +
      caption("刷新") + card(refresh) +
      caption("菜单栏指标") + card(metrics)
    );
  }

  function paneAgents() {
    var s = D.token;
    var days = D.heatmap.cells.slice(-30).map(function (c) {
      return { tokens: c.level * 100e6 };
    });
    var max = Math.max.apply(null, days.map(function (d) { return d.tokens; }));

    var bars = days
      .map(function (d, i) {
        var h = Math.max(3, (d.tokens / max) * 84);
        var x = 4 + i * 24;
        return '<rect class="bar" x="' + x + '" y="' + (94 - h) + '" width="14" height="' + h + '" rx="2"></rect>';
      })
      .join("");

    var axis =
      '<text x="4" y="106">10/6</text>' +
      '<text x="180" y="106">10/13</text>' +
      '<text x="356" y="106">10/20</text>' +
      '<text x="532" y="106">10/27</text>' +
      '<text x="690" y="106">11/4</text>';

    var kpis =
      '<div class="st-kpis">' +
      '<div class="st-kpi"><span class="st-kpi__k">总 Token</span><span class="st-kpi__v">586.6M</span><span class="st-kpi__s">全部 Agent · 全部时间</span></div>' +
      '<div class="st-kpi"><span class="st-kpi__k">费用</span><span class="st-kpi__v">¥334.15</span><span class="st-kpi__s">按你自己的价目</span></div>' +
      '<div class="st-kpi"><span class="st-kpi__k">缓存收益</span><span class="st-kpi__v">¥1,284.60</span><span class="st-kpi__s"><b>已省</b> · 命中 97%</span></div>' +
      '<div class="st-kpi"><span class="st-kpi__k">活跃 Agent</span><span class="st-kpi__v">4</span><span class="st-kpi__s">今日 · 已配置 10 个</span></div>' +
      "</div>";

    var composition =
      '<div class="st-kpis">' +
      '<div class="st-kpi"><span class="st-kpi__k">Prompt 输入</span><span class="st-kpi__v">18.4M</span></div>' +
      '<div class="st-kpi"><span class="st-kpi__k">模型输出</span><span class="st-kpi__v">1.7M</span></div>' +
      '<div class="st-kpi"><span class="st-kpi__k">缓存读取</span><span class="st-kpi__v">566.5M</span></div>' +
      '<div class="st-kpi"><span class="st-kpi__k">缓存写入</span><span class="st-kpi__v">12.6M</span></div>' +
      "</div>";

    return (
      '<p class="st-pane-lede">用量工作台。所有会话只在本机解析，绝不上报远程服务器。</p>' +
      '<div class="st-toolbar">' +
      seg(["今日", "近 7 天", "近 30 天", "本月", "全部历史"], "近 30 天") +
      '<span class="st-toolbar__spacer"></span>' +
      '<button class="st-btn" type="button">导出 CSV</button>' +
      '<button class="st-btn" type="button">导出 JSON</button>' +
      "</div>" +
      kpis +
      '<div class="st-chart-card"><div class="st-chart-card__head"><span class="st-chart-card__title">时序趋势</span>' +
      '<span class="st-chart-card__sub">近 30 天 · 峰值 586.6M（11 月 4 日）</span></div>' +
      '<svg class="st-chart" viewBox="0 0 720 112" preserveAspectRatio="none" aria-hidden="true">' +
      bars + axis + "</svg></div>" +
      caption("Token 构成") + composition +
      '<p class="st-note">所有会话仅在本机分析，绝不上报远程服务器。</p>'
    );
  }

  function panePricing() {
    var s = D.token;
    var rows = D.pricing
      .map(function (p) {
        var cost = ((p.used * p.inn) / 1e6) * 0.55 + ((p.used * p.cache) / 1e6) * 0.45;
        return (
          "<tr>" +
          '<td><div class="st-model">' +
          '<span class="st-badge" style="width:20px;height:20px;border-radius:4px;background:' +
          p.tile +
          ";color:" + p.mark + ';font-size:10px;box-shadow:inset 0 0 0 0.5px rgba(0,0,0,.12)">' +
          p.mono +
          "</span>" +
          '<div><div class="st-model__name">' + p.name + '</div><div class="st-model__vendor">' + p.vendor + "</div></div>" +
          "</div></td>" +
          '<td class="num">' + compact(p.used) + "</td>" +
          '<td><span class="st-tag">内置</span></td>' +
          '<td class="num">¥' + p.inn.toFixed(p.inn < 1 ? 2 : 1) + " /1M</td>" +
          '<td class="num">¥' + p.out.toFixed(p.out < 1 ? 2 : 1) + " /1M</td>" +
          '<td class="num">¥' + p.cache.toFixed(p.cache < 1 ? 3 : 2) + " /1M</td>" +
          '<td class="num">' + money(cost) + "</td>" +
          "</tr>"
        );
      })
      .join("");

    return (
      '<p class="st-pane-lede">今日预估总费用，按本机全部活跃 Agent 的真实 token 吞吐折算。</p>' +
      '<div class="st-kpis">' +
      '<div class="st-kpi"><span class="st-kpi__k">今日折算总费用</span><span class="st-kpi__v">' + money(s.cost) + '</span><span class="st-kpi__s">/ 586.6M tokens</span></div>' +
      "</div>" +
      caption("模型价格表") +
      card([
        row("自动同步价格表", "启动 30 秒后静默同步一次，之后每 24 小时一次", sw(true)),
        row("当前价格表", "内置基线 · 86 款模型", '<span class="st-tag st-tag--ok">86 款</span>'),
        row("同步价格表", "上次同步 今天 14:02", '<button class="st-btn" type="button">同步更新</button><button class="st-btn" type="button">恢复内置</button>'),
      ]) +
      '<div class="st-card" style="margin-top:14px"><table class="st-table"><thead><tr>' +
      '<th style="width:27%">模型与厂商</th><th class="num">今日用量</th><th>来源</th>' +
      '<th class="num">输入单价</th><th class="num">输出单价</th><th class="num">缓存命中</th><th class="num">今日折算</th>' +
      "</tr></thead><tbody>" + rows + "</tbody></table></div>" +
      '<p class="st-note">人工校准写入 <em>~/Library/Application Support/Bruce/config/onboarding-v1.json</em> 的 <em>pricingOverrides</em> 节点，下次刷新生效。</p>'
    );
  }

  function paneSubscriptions() {
    var rows = D.subscriptions.sections
      .map(function (p) {
        var status;
        if (p.balance != null) {
          status = '<span class="st-tag">余额 ¥' + p.balance.toFixed(2) + "</span>";
        } else if (p.accounts) {
          status = '<span class="st-tag st-tag--ok">2 个账号</span>';
        } else {
          var worst = Math.max.apply(null, p.windows.map(function (w) { return w.used; }));
          status = '<span class="st-tag ' + (worst >= 80 ? "st-tag--warn" : "st-tag--ok") + '">' + worst + "% 本周</span>";
        }
        return (
          '<div class="st-row"><div class="st-provider">' +
          (p.icon
            ? '<span class="st-badge" style="background:' + p.color +
              '"><img class="st-badge__glyph" src="assets/provider-icons/' + p.icon + '.svg" alt="" ' +
              'onerror="this.style.display=\'none\';this.nextElementSibling.style.display=\'block\'">' +
              '<span class="st-badge__mono">' + p.monogram + "</span></span>"
            : '<span class="st-badge" style="background:' + p.color + '">' + p.monogram + "</span>") +
          '<div class="st-row__text"><div class="st-row__title">' + p.name + "</div>" +
          '<div class="st-row__sub">每 3 分钟查询一次 · 最近 17:13</div></div>' +
          "</div>" +
          '<div class="st-row__control">' + status +
          '<button class="st-btn" type="button">配置</button>' + sw(true) + "</div></div>"
        );
      })
      .join("");

    return (
      '<p class="st-pane-lede">凭证只存在本机一份 0600 文件里。没有在这里启用的服务商，不会被查询。</p>' +
      caption("云端额度凭证") +
      card([rows]) +
      card([
        row("添加服务", "只列出尚未配置的 Provider", '<button class="st-btn" type="button">选择 Provider ▾</button><button class="st-btn st-btn--primary" type="button">添加…</button>'),
      ]) +
      '<p class="st-note">配置并启用的服务商，只在统一授权生效时查询额度，锁屏期间暂停。拖拽行可调整在看板上的顺序。出口 IP 会按服务商所在区域校验。</p>'
    );
  }

  function paneConsent() {
    return (
      '<p class="st-pane-lede">采集只需要一次授权；装上 App 并不等于授权。</p>' +
      card([
        row("模型用量", "允许按授权范围采集本机会话用量", sw(true)),
      ]) +
      '<div class="st-card" style="margin-top:14px;padding:16px 18px 18px">' +
      '<div class="st-row__title" style="font-size:13.5px">授权后应用将：</div>' +
      '<ul class="st-bullets">' +
      "<li>扫描本机 Agent 会话目录与 CC Switch 数据库（只读）</li>" +
      "<li>每 3 分钟刷新已授权模块</li>" +
      "<li>只查询已启用的服务商；一个都没配就不发起请求</li>" +
      "<li>快照只写入 ~/Library/Application Support/Bruce，别处不写</li>" +
      "</ul>" +
      '<div class="st-status-line"><span class="dot"></span>当前授权有效 · 范围 v2，2026-08-21 授予</div>' +
      '<div style="display:flex;gap:8px;margin-top:14px"><button class="st-btn st-btn--danger" type="button">撤销全部授权</button>' +
      '<button class="st-btn" type="button">查看诊断范围</button></div>' +
      "</div>"
    );
  }

  function paneMaintenance() {
    return (
      caption("软件更新") +
      card([
        row("自动检查更新", "启动 30 秒后静默检查一次，之后每 24 小时一次；失败不打扰", sw(true)),
        row("当前版本", "Universal 2 · 未签名预览版", '<span class="st-value">{{VERSION}}</span>'),
        row("检查更新", "上次检查 今天 09:12", '<button class="st-btn" type="button">检查更新</button>'),
      ]) +
      caption("模型价格表") +
      card([
        row("自动同步价格表", "启动 30 秒后静默同步一次，之后每 24 小时一次", sw(true)),
        row("当前价格表", "内置基线 · 86 款模型", '<span class="st-tag st-tag--ok">86 款</span>'),
        row("Sync now", "Last synced today 14:02", '<button class="st-btn" type="button">Sync now</button><button class="st-btn" type="button">Restore built-in</button>'),
      ]) +
      caption("数据") +
      card([
        row("清理用量缓存", "仅删除本应用快照，不影响配置、凭证与账单统计", '<button class="st-btn st-btn--danger" type="button">清理</button>'),
        row("导出账单", "token 用量与花费统计 CSV", '<button class="st-btn" type="button">导出…</button>'),
      ]) +
      caption("诊断") +
      card([
        row("诊断信息", "最近采集错误与模块状态，脱敏 JSON", '<button class="st-btn" type="button">预览</button>'),
        row("导出诊断包", "脱敏 zip，不含 Artifact 与凭证", '<button class="st-btn" type="button">导出…</button>'),
      ])
    );
  }

  /* ---------- sidebar --------------------------------------------- */
  var CATS = [
    { id: "general", title: "通用", icon: "gear" },
    { id: "agents", title: "模型用量", icon: "chart" },
    { id: "pricing", title: "模型计费", icon: "dollar" },
    { id: "subscription", title: "订阅额度", icon: "cloud" },
    { id: "consent", title: "授权与隐私", icon: "shield", badge: "" },
    { id: "maintenance", title: "维护", icon: "wrench", badge: "新" },
  ];

  var PANES = {
    general: { title: "通用", render: paneGeneral },
    agents: { title: "模型用量", render: paneAgents },
    pricing: { title: "模型计费", render: panePricing },
    subscription: { title: "订阅额度", render: paneSubscriptions },
    consent: { title: "授权与隐私", render: paneConsent },
    maintenance: { title: "维护", render: paneMaintenance },
  };

  /* ---------- build ------------------------------------------------ */
  root.innerHTML =
    '<div class="st-titlebar"><div class="st-lights" aria-hidden="true"><i></i><i></i><i></i></div>' +
    '<div class="st-title">Bruce 设置</div></div>' +
    '<div class="st-body">' +
    '<nav class="st-sidebar" aria-label="设置分类">' +
    CATS.map(function (c) {
      return (
        '<button class="st-nav" type="button" role="tab" data-cat="' + c.id + '" aria-selected="' + (c.id === state.cat) + '">' +
        ico(c.icon) + "<span>" + c.title + "</span>" +
        (c.badge ? '<span class="st-nav__badge">' + c.badge + "</span>" : "") +
        "</button>"
      );
    }).join("") +
    '<div class="st-sidebar__foot"><span>v{{VERSION}}</span><span>通用二进制</span></div>' +
    "</nav>" +
    '<div class="st-content" id="st-content"></div>' +
    "</div>";

  var content = root.querySelector("#st-content");

  function paint() {
    var pane = PANES[state.cat];
    content.innerHTML =
      '<div class="pane">' +
      '<p class="st-crumb">设置<span>/</span>' + pane.title + "</p>" +
      '<h2 class="st-pane-title">' + pane.title + "</h2>" +
      pane.render() +
      "</div>";
    content.scrollTop = 0;
    bind(pane);
    root.querySelectorAll(".st-nav").forEach(function (b) {
      b.setAttribute("aria-selected", String(b.dataset.cat === state.cat));
    });
    paintPreview();
    syncDeskIndex();
  }

  function paintPreview() {
    var strip = root.querySelector("#preview-strip");
    if (!strip) return;
    var icon =
      '<svg width="17" height="17" viewBox="0 0 20 20" aria-hidden="true">' +
      '<circle cx="10" cy="10" r="6.4" fill="none" stroke="rgba(0,0,0,.18)" stroke-width="1.4"/>' +
      '<path d="M10 3.6a6.4 6.4 0 0 1 5.4 9.8" fill="none" stroke="#15803d" stroke-width="1.4" stroke-linecap="round"/>' +
      '<circle cx="15.4" cy="13.4" r="1.8" fill="#15803d"/></svg>';
    strip.innerHTML =
      icon + '<span class="item">42%</span><span class="item">586.6M</span><span class="item">¥334</span>';
  }

  function syncDeskIndex() {
    document.querySelectorAll("#desk-index li").forEach(function (li, i) {
      li.classList.toggle("is-current", CATS[i] && CATS[i].id === state.cat);
    });
  }

  /* ---------- interaction ------------------------------------------ */
  function bind(pane) {
    content.querySelectorAll(".st-switch").forEach(function (b) {
      b.addEventListener("click", function () {
        b.setAttribute("aria-checked", b.getAttribute("aria-checked") === "true" ? "false" : "true");
      });
    });
    content.querySelectorAll(".st-seg").forEach(function (g) {
      g.addEventListener("click", function (e) {
        var b = e.target.closest("button");
        if (!b) return;
        g.querySelectorAll("button").forEach(function (x) {
          x.setAttribute("aria-pressed", "false");
        });
        b.setAttribute("aria-pressed", "true");
      });
    });
  }

  root.addEventListener("click", function (e) {
    var nav = e.target.closest(".st-nav");
    if (nav && nav.dataset.cat && nav.dataset.cat !== state.cat) {
      state.cat = nav.dataset.cat;
      paint();
    }
  });

  /* external triggers: the ordered list in the desk copy */
  document.querySelectorAll("#desk-index li").forEach(function (li, i) {
    li.addEventListener("click", function () {
      if (!CATS[i]) return;
      state.cat = CATS[i].id;
      paint();
    });
    li.style.cursor = "pointer";
  });

  /* ---------- scale the 1000pt window to the available width ------- */
  function fit() {
    var wrap = root.parentElement;
    if (!wrap) return;
    var avail = wrap.clientWidth;
    var scale = Math.min(1, avail / 1000);
    /* on narrow screens keep the window legible and let it be panned */
    if (window.innerWidth < 760) scale = Math.max(scale, 0.68);
    root.style.zoom = scale;
    wrap.style.height = Math.ceil(680 * scale) + "px";
    var pannable = scale * 1000 > avail + 4;
    wrap.classList.toggle("is-pannable", pannable);
    var hint = document.querySelector(".desk-swipe");
    if (hint) hint.hidden = !pannable;
  }

  window.addEventListener("resize", fit);

  paint();
  fit();
})();
