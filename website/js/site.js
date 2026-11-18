/* ============================================================
   BRUCE — official site
   site.js : masthead, choreographed reveals, 26-week ledger wave,
             gliding tooltip, rolling figures, 10+10 source directory
   ============================================================ */
(function () {
  "use strict";

  var D = window.BRUCE_DATA;
  var reduceMq = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* ---------- masthead ------------------------------------------- */
  var mast = document.getElementById("masthead");
  var sections = Array.prototype.slice.call(document.querySelectorAll("main section[id]"));
  var navLinks = Array.prototype.slice.call(document.querySelectorAll(".masthead__nav a"));
  var nightSection = document.getElementById("egress");

  function onScroll() {
    if (!mast) return;
    mast.classList.toggle("is-stuck", window.scrollY > 48);

    if (nightSection) {
      var nr = nightSection.getBoundingClientRect();
      mast.classList.toggle("is-dark", nr.top <= 44 && nr.bottom >= 44);
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

  /* ---------- reveals & scroll-triggered choreography ------------ */
  var revealGroups = [
    [".section__head", 0],
    [".anatomy", 60],
    [".marquee-group", 40],
    [".source-col", 90],
    [".local-notes__list li", 65],
    [".record-heat", 40],
    [".record-copy", 110],
    [".eg-band", 70],
    [".wb-stage", 50],
    [".colophon__download", 40],
    [".colophon__top", 80],
  ];

  var revealEls = [];
  revealGroups.forEach(function (pair) {
    var sel = pair[0];
    var step = pair[1];
    document.querySelectorAll(sel).forEach(function (el, idx) {
      el.setAttribute("data-reveal", "");
      el.style.setProperty("--reveal-delay", Math.min(280, idx * step) + "ms");
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
      { rootMargin: "0px 0px -6% 0px", threshold: 0.04 }
    );
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("is-in"); });
  }

  /* ---------- section 03 : 26-week ledger + gliding tooltip ------ */
  var heatmapEl = document.getElementById("heatmap");
  var grid = document.getElementById("heatmap-grid");
  var monthsRow = document.getElementById("heatmap-months");
  var tip = document.getElementById("heatmap-tip");
  var readout = document.getElementById("heatmap-readout");
  var DEFAULT_READOUT = "11 月 4 日 · 400M 以上（当日峰值 586.6M）";

  var MONTHS = ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"];
  var BAND = { 0: "无活跃记录", 1: "100M 以下", 2: "100–200M", 3: "200–300M", 4: "300–400M", 5: "400M 以上（峰值 586.6M）" };

  function setReadoutText(text) {
    if (!readout || readout.textContent === text) return;
    readout.textContent = text;
    if (!reduceMq.matches) {
      readout.classList.remove("is-tick");
      void readout.offsetWidth;
      readout.classList.add("is-tick");
    }
  }

  if (grid && D) {
    var frag = document.createDocumentFragment();
    var cols = D.heatmap.weeks.length;

    D.heatmap.weeks.forEach(function (week, wIdx) {
      week.forEach(function (level, dIdx) {
        var cell = document.createElement("span");
        cell.className = "heatmap__cell";
        cell.style.setProperty("--hd", (wIdx * 12 + dIdx * 5) + "ms");
        if (level !== null) {
          cell.setAttribute("data-level", String(level));
          cell.dataset.band = String(level);
        } else {
          cell.classList.add("is-future");
          cell.dataset.band = "";
        }
        frag.appendChild(cell);
      });
    });
    grid.appendChild(frag);

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

    var all = grid.querySelectorAll(".heatmap__cell");
    var dayCursor = new Date(start.getTime());
    var dates = [];
    D.heatmap.weeks.forEach(function (week) {
      week.forEach(function () {
        dates.push(new Date(dayCursor.getTime()));
        dayCursor.setDate(dayCursor.getDate() + 1);
      });
    });

    all.forEach(function (cell, idx) {
      var date = dates[idx];
      if (!date) return;
      function showTip() {
        var raw = cell.dataset.band;
        var band = raw === "" ? "尚未到来的日期" : BAND[Number(raw)];
        var text = (date.getMonth() + 1) + " 月 " + date.getDate() + " 日 · " + band;
        setReadoutText(text);
        if (!tip) return;
        var wasOff = !tip.classList.contains("is-on");
        tip.textContent = text;
        var r = cell.getBoundingClientRect();
        var tx = Math.round(r.left + r.width / 2);
        var ty = Math.round(r.top);
        if (wasOff) {
          /* 首次显现时直接就位再开过渡，防止从左上角飞入 */
          tip.classList.add("is-snap");
          tip.style.setProperty("--tx", tx + "px");
          tip.style.setProperty("--ty", ty + "px");
          void tip.offsetWidth;
          tip.classList.remove("is-snap");
        } else {
          tip.style.setProperty("--tx", tx + "px");
          tip.style.setProperty("--ty", ty + "px");
        }
        tip.classList.add("is-on");
      }
      cell.addEventListener("pointerenter", showTip);
      cell.addEventListener("click", showTip);
    });

    grid.addEventListener("pointerleave", function () {
      if (tip) tip.classList.remove("is-on");
      setReadoutText(DEFAULT_READOUT);
    });

    document.addEventListener("click", function (e) {
      if (!tip || e.target.closest(".heatmap__cell")) return;
      tip.classList.remove("is-on");
      setReadoutText(DEFAULT_READOUT);
    });
  }

  /* 滚动进入 03 章时播放热力图对角线波纹与四项台账数字滚入 */
  var recordSection = document.getElementById("record");
  function animateStatList() {
    var statEls = Array.prototype.slice.call(document.querySelectorAll(".stat-list .v"));
    if (!statEls.length || reduceMq.matches) return;
    var specs = statEls.map(function (el) {
      var raw = el.textContent.trim();
      var m = raw.match(/^([\d.]+)(.*)$/);
      if (!m) return null;
      var num = parseFloat(m[1]);
      var dec = m[1].indexOf(".") !== -1 ? m[1].split(".")[1].length : 0;
      return { el: el, target: num, dec: dec, suffix: m[2] };
    });
    var t0 = performance.now();
    var dur = 760;
    function tick(now) {
      var p = Math.min(1, (now - t0) / dur);
      var eased = 1 - Math.pow(1 - p, 3.4);
      specs.forEach(function (sp) {
        if (!sp) return;
        var cur = sp.target * eased;
        sp.el.textContent = cur.toFixed(sp.dec) + sp.suffix;
      });
      if (p < 1) requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  if (recordSection && "IntersectionObserver" in window) {
    var recIo = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            if (heatmapEl) heatmapEl.classList.add("is-wave-in");
            animateStatList();
            recIo.unobserve(e.target);
          }
        });
      },
      { threshold: 0.18 }
    );
    recIo.observe(recordSection);
  } else if (heatmapEl) {
    heatmapEl.classList.add("is-wave-in");
  }

  /* ---------- section 02 : brand badge helper -------------------- */
  function badgeInnerHtml(row) {
    if (row.image) {
      return '<img class="src-chip__glyph" src="assets/agent-icons/' + row.image + '.png" alt="" />';
    }
    if (row.logo) {
      return '<img class="src-chip__logo" src="assets/agent-icons/' + row.logo + '.svg" alt="" />';
    }
    if (row.icon) {
      return '<img class="src-chip__icon" src="assets/provider-icons/' + row.icon + '.svg" alt="" />';
    }
    return '<span class="src-chip__mono">' + (row.mono || row.name.charAt(0)) + "</span>";
  }

  function marqueePill(row) {
    return (
      '<span class="src-pill" title="' + row.name + '">' +
      '<span class="src-chip" style="--tile:' + row.tile + '" aria-hidden="true">' +
      badgeInnerHtml(row) +
      "</span>" +
      '<span class="src-pill__name">' + row.name + "</span>" +
      "</span>"
    );
  }

  function sourceBrands() {
    var seen = {};
    var out = [];
    D.sources.agents.concat(D.sources.providers).forEach(function (row) {
      if (row.image === "agent-codex") return;
      var key = (row.icon || row.image || row.logo || row.name) + ":" + row.name.split(" ")[0];
      if (seen[key]) return;
      seen[key] = true;
      out.push(row);
    });
    return out;
  }

  function buildSourceMarquee() {
    if (!D) return;
    var marquee = document.getElementById("source-marquee");
    var track = document.getElementById("source-track");
    if (!marquee || !track) return;

    var rows = sourceBrands();
    var pills = rows.map(marqueePill).join("");
    track.innerHTML = '<div class="marquee__set">' + pills + "</div>";

    var containerW = marquee.clientWidth || 1200;
    var setWidth = track.firstElementChild.getBoundingClientRect().width || rows.length * 140;
    var repeats = Math.max(1, Math.ceil((containerW + 1) / setWidth));
    var half = "";
    for (var i = 0; i < repeats; i += 1) {
      half += '<div class="marquee__set">' + pills + "</div>";
    }
    track.innerHTML = half + half;

    var duration = Math.max(24, Math.round((setWidth * repeats) / 38));
    track.style.setProperty("--flow-duration", duration + "s");

    marquee.setAttribute(
      "aria-label",
      "支持的本机 Agent 与订阅服务商：" + rows.map(function (r) { return r.name; }).join("、")
    );
  }

  function renderSourceLists() {
    if (!D) return;
    var agentUl = document.getElementById("source-agents-list");
    var provUl = document.getElementById("source-providers-list");

    function rowHtml(row, idx) {
      return (
        '<li class="source-item" style="--row-d:' + (idx * 28) + 'ms">' +
        '<span class="src-chip src-chip--sm" style="--tile:' + row.tile + '" aria-hidden="true">' +
        badgeInnerHtml(row) +
        "</span>" +
        '<span class="source-item__name">' + row.name + "</span>" +
        (row.tag ? '<span class="source-item__tag">' + row.tag + "</span>" : "") +
        "</li>"
      );
    }

    if (agentUl) agentUl.innerHTML = D.sources.agents.map(rowHtml).join("");
    if (provUl) provUl.innerHTML = D.sources.providers.map(rowHtml).join("");
  }

  buildSourceMarquee();
  renderSourceLists();

  var marqueeTimer = null;
  window.addEventListener("resize", function () {
    clearTimeout(marqueeTimer);
    marqueeTimer = setTimeout(buildSourceMarquee, 220);
  });

  /* ---------- smooth anchor offset ------------------------------- */
  document.querySelectorAll('a[href^="#"]').forEach(function (a) {
    a.addEventListener("click", function (e) {
      var id = a.getAttribute("href");
      if (!id || id.length < 2) return;
      var target = document.querySelector(id);
      if (!target) return;
      e.preventDefault();
      var offset = id === "#top" ? 0 : target.getBoundingClientRect().top + window.scrollY - 68;
      window.scrollTo({ top: Math.max(0, offset), behavior: "smooth" });
      history.replaceState(null, "", id);
    });
  });
})();
