/* ============================================================
   BRUCE — official site
   site.js : masthead, reveals, the 26-week record, credit lists
   ============================================================ */
(function () {
  "use strict";

  var D = window.BRUCE_DATA;

  /* ---------- masthead ------------------------------------------- */
  var mast = document.getElementById("masthead");
  var sections = Array.prototype.slice.call(document.querySelectorAll("main section[id]"));
  var navLinks = Array.prototype.slice.call(document.querySelectorAll(".masthead__nav a"));

  var nightSection = document.getElementById("egress");

  function onScroll() {
    if (!mast) return;
    mast.classList.toggle("is-stuck", window.scrollY > 80);

    if (nightSection) {
      var nr = nightSection.getBoundingClientRect();
      mast.classList.toggle("is-dark", nr.top <= 40 && nr.bottom >= 40);
    }

    var mid = window.scrollY + window.innerHeight * 0.34;
    var current = null;
    sections.forEach(function (s) {
      if (s.offsetTop <= mid) current = s.id;
    });
    navLinks.forEach(function (a) {
      a.classList.toggle("is-active", a.getAttribute("href") === "#" + current);
    });
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- reveals -------------------------------------------- */
  var revealTargets = [
    ".section__head",
    ".anatomy",
    ".local-notes",
    ".marquee-group",
    ".record-heat",
    ".record-copy",
    ".eg-band",
    ".wb-stage",
    ".colophon__download",
    ".colophon__top",
  ];

  var revealEls = [];
  revealTargets.forEach(function (sel) {
    document.querySelectorAll(sel).forEach(function (el, i) {
      el.setAttribute("data-reveal", "");
      el.style.setProperty("--reveal-delay", Math.min(240, i * 70) + "ms");
      revealEls.push(el);
    });
  });

  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("is-in");
            io.unobserve(e.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.04 }
    );
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("is-in"); });
  }

  /* ---------- section 03 : the record ---------------------------- */
  var grid = document.getElementById("heatmap-grid");
  var monthsRow = document.getElementById("heatmap-months");
  var tip = document.getElementById("heatmap-tip");

  var MONTHS = ["1 月", "2 月", "3 月", "4 月", "5 月", "6 月", "7 月", "8 月", "9 月", "10 月", "11 月", "12 月"];
  var BAND = { 0: "无用量", 1: "100M 以下", 2: "100–200M", 3: "200–300M", 4: "300–400M", 5: "400M 以上" };

  if (grid && D) {
    var frag = document.createDocumentFragment();
    var cols = D.heatmap.weeks.length;

    D.heatmap.weeks.forEach(function (week) {
      week.forEach(function (level) {
        var cell = document.createElement("span");
        cell.className = "heatmap__cell";
        if (level !== null) cell.setAttribute("data-level", String(level));
        cell.dataset.band = level === null ? null : String(level);
        frag.appendChild(cell);
      });
    });
    grid.appendChild(frag);

    /* month labels, one per column where a new month begins */
    var start = D.heatmap.start;
    var lastMonth = -1;
    var labels = [];
    for (var c = 0; c < cols; c += 1) {
      var d = new Date(start.getTime());
      d.setDate(d.getDate() + c * 7);
      if (d.getMonth() !== lastMonth) {
        lastMonth = d.getMonth();
        labels.push('<span style="grid-column:' + (c + 1) + '">' + MONTHS[d.getMonth()] + "</span>");
      }
    }
    if (monthsRow) monthsRow.innerHTML = labels.join("");

    /* cells: rebuild with an index so the tooltip can resolve a date */
    var all = grid.querySelectorAll(".heatmap__cell");
    var idx = 0;
    var dayCursor = new Date(start.getTime());
    var dates = [];
    D.heatmap.weeks.forEach(function (week) {
      week.forEach(function (level) {
        dates.push(new Date(dayCursor.getTime()));
        dayCursor.setDate(dayCursor.getDate() + 1);
      });
    });

    all.forEach(function (cell) {
      var i = idx++;
      var date = dates[i];
      if (!date) return;
      function showTip() {
        if (!tip) return;
        var level = cell.dataset.band;
        var band = level === null ? "未发生" : BAND[Number(level)];
        tip.textContent =
          date.getMonth() + 1 + " 月 " + date.getDate() + " 日 · " + band;
        tip.classList.add("is-on");
        var r = cell.getBoundingClientRect();
        tip.style.left = r.left + r.width / 2 + "px";
        tip.style.top = r.top + "px";
      }
      cell.addEventListener("pointerenter", showTip);
      cell.addEventListener("click", showTip); /* 触屏没有 hover，点按显示 */
      cell.addEventListener("pointerleave", function () {
        if (tip) tip.classList.remove("is-on");
      });
    });

    /* 点空白处收起触屏上的日期提示 */
    document.addEventListener("click", function (e) {
      if (!tip || e.target.closest(".heatmap__cell")) return;
      tip.classList.remove("is-on");
    });

    var range = document.getElementById("heatmap-range");
    if (range) {
      range.textContent =
        "5 月 11 日 — 11 月 4 日 · 178 天 · 峰值 586.6M";
    }
  }

  /* ---------- section 02 : the flowing icon row ------------------- */
  function sourceChip(row) {
    var label = ' title="' + row.name + '" aria-label="' + row.name + '"';
    var tile = ' style="--tile:' + row.tile + '"';
    if (row.image) {
      /* 官方 App 位图（docs/assets/provider-icons/agent-icons 同步） */
      return (
        '<span class="src-chip"' + tile + label + '>' +
        '<img class="src-chip__glyph" src="assets/agent-icons/' + row.image + '.png" alt="" />' +
        "</span>"
      );
    }
    if (row.logo) {
      /* 站点内的官方 logo（Pi Coding Agent，白色字形，dashboardicons 收录） */
      return (
        '<span class="src-chip"' + tile + label + '>' +
        '<img class="src-chip__logo" src="assets/agent-icons/' + row.logo + '.svg" alt="" />' +
        "</span>"
      );
    }
    if (row.icon) {
      return (
        '<span class="src-chip"' + tile + label + '>' +
        '<img class="src-chip__icon" src="assets/provider-icons/' + row.icon + '.svg" alt="" />' +
        "</span>"
      );
    }
    return (
      '<span class="src-chip"' + tile + label + '>' +
      '<span class="src-chip__mono">' + row.mono + "</span></span>"
    );
  }

  function fillMarquee(marqueeId, trackId, rows, label) {
    var marquee = document.getElementById(marqueeId);
    var track = document.getElementById(trackId);
    if (!marquee || !track || !rows) return;

    /* 单份图标铺满一屏：尺寸随容器宽度浮动，避免同屏出现重复 logo */
    var count = rows.length;
    var containerW = marquee.clientWidth || 0;
    var gap = Math.max(12, Math.min(28, Math.round(containerW * 0.02)));
    var minChip = 44;
    var maxChip = 132;
    var ideal = Math.floor((containerW - count * gap) / count) + 2;
    var chip = Math.max(minChip, Math.min(maxChip, ideal));
    marquee.style.setProperty("--chip-size", chip + "px");
    marquee.style.setProperty("--chip-gap", gap + "px");

    var chips = rows.map(sourceChip).join("");
    track.innerHTML = '<div class="marquee__set">' + chips + "</div>";

    /* 极宽屏（尺寸封顶后）仍需重复铺满；两半相同 → 平移 50% 无缝右移 */
    var setWidth =
      track.firstElementChild.getBoundingClientRect().width || count * (chip + gap);
    var repeats = Math.max(1, Math.ceil((containerW + 1) / setWidth));
    var half = "";
    for (var i = 0; i < repeats; i += 1) {
      half += '<div class="marquee__set">' + chips + "</div>";
    }
    track.innerHTML = half + half;

    /* 恒定约 42px/s；--flow-duration 同时供 reduced-motion 覆盖使用 */
    var duration = Math.max(18, Math.round((setWidth * repeats) / 42));
    track.style.setProperty("--flow-duration", duration + "s");

    marquee.setAttribute(
      "aria-label",
      label + "：" +
        rows.map(function (row) { return row.name; }).join("、") +
        "（共 " + rows.length + " 个）"
    );
  }

  /* 单行展示：按图标去重（Kimi Work / Kimi Code CLI / Kimi 这类只留一个）。
     Codex 只去掉官方 App 位图（蓝色云朵），订阅侧保留绿色 GPT/OpenAI 图形。 */
  function sourceBrands() {
    var seen = {};
    var out = [];
    D.sources.agents.concat(D.sources.providers).forEach(function (row) {
      if (row.image === "agent-codex") return;
      var key = row.icon || row.image || row.mono || row.name;
      if (seen[key]) return;
      seen[key] = true;
      out.push(row);
    });
    return out;
  }

  function buildSourceMarquee() {
    if (!D) return;
    fillMarquee(
      "source-marquee",
      "source-track",
      sourceBrands(),
      "支持的本机 Agent 与订阅服务商"
    );
  }

  buildSourceMarquee();

  var marqueeTimer = null;
  window.addEventListener("resize", function () {
    clearTimeout(marqueeTimer);
    marqueeTimer = setTimeout(buildSourceMarquee, 250);
  });

  /* ---------- modal-free smooth anchor offset -------------------- */
  document.querySelectorAll('a[href^="#"]').forEach(function (a) {
    a.addEventListener("click", function (e) {
      var id = a.getAttribute("href");
      if (id.length < 2) return;
      var target = document.querySelector(id);
      if (!target) return;
      e.preventDefault();
      var top = target.getBoundingClientRect().top + window.scrollY - 24;
      window.scrollTo({ top: top, behavior: "smooth" });
      history.replaceState(null, "", id);
    });
  });
})();
