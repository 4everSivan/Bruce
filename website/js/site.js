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

  var nightSection = document.getElementById("machine");

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
    ".panel-layout",
    ".desk-layout",
    ".desk-hint",
    ".desk-window-wrap",
    ".record-heat",
    ".record-copy",
    ".pledge",
    ".source-col",
    ".sources-note",
    ".install-main",
    ".install-spec",
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
      cell.addEventListener("pointerenter", function (e) {
        if (!tip) return;
        var level = cell.dataset.band;
        var band = level === null ? "未发生" : BAND[Number(level)];
        tip.textContent =
          date.getMonth() + 1 + " 月 " + date.getDate() + " 日 · " + band;
        tip.classList.add("is-on");
        var r = cell.getBoundingClientRect();
        tip.style.left = r.left + r.width / 2 + "px";
        tip.style.top = r.top + "px";
      });
      cell.addEventListener("pointerleave", function () {
        if (tip) tip.classList.remove("is-on");
      });
    });

    var range = document.getElementById("heatmap-range");
    if (range) {
      range.textContent =
        "5 月 11 日 — 11 月 4 日 · 178 天 · 峰值 586.6M";
    }
  }

  /* ---------- section 05 : the two lists ------------------------- */
  function fillList(id, rows, withTag) {
    var el = document.getElementById(id);
    if (!el || !rows) return;
    el.innerHTML = rows
      .map(function (row, i) {
        var n = String(i + 1).padStart(2, "0");
        if (typeof row === "string") {
          return '<li><span class="i">' + n + '</span><span class="n">' + row + "</span></li>";
        }
        return (
          '<li><span class="i">' + n + "</span>" +
          '<span class="n">' + row.name +
          (withTag && row.tag ? '<small>' + row.tag + "</small>" : "") +
          "</span></li>"
        );
      })
      .join("");
  }

  if (D) {
    fillList("agent-list", D.sources.agents, false);
    fillList("provider-list", D.sources.providers, true);
  }

  /* ---------- copy the build command ----------------------------- */
  document.querySelectorAll("[data-copy]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var target = document.querySelector(btn.dataset.copy);
      if (!target) return;
      var text = target.textContent.trim();
      var done = function () {
        var old = btn.textContent;
        btn.textContent = "已复制";
        setTimeout(function () { btn.textContent = old; }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, done);
      } else {
        done();
      }
    });
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
