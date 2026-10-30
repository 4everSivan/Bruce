// 仪表盘数据更新动效 (C158, mac design/03 规则 13 / design/05 规则 34).
//
// Windows 每次 dashboard-updated 都全量重建 DOM, 新节点出生即终值, CSS transition
// 没有旧值可过渡. 因此本模块在 render 之后按稳定 key 对比上一帧 panel, 用 Web
// Animations API 从旧值补到新值; 渲染值本身始终是终值, 动画不写回内联样式.
//
// 所有浏览器能力在函数内检测: Node DOM 测试桩没有 Element.animate / getComputedStyle,
// 模块加载不触碰这些 API, 测试里自动 inert.
(function () {
  if (typeof window === "undefined") return;

  var BAR_DURATION = 850;
  var DIGIT_DURATION = 600;
  var SEGMENT_DURATION = 140;
  var SEGMENT_STAGGER = 6;
  var SEGMENT_COUNT = 24;
  // 临界阻尼弹簧采样 (w=5, 归一化到 1); WebView2 113+ 支持 linear().
  var SPRING = "linear(0, 0.0197, 0.0689, 0.1357, 0.2118, 0.2913, 0.3703, 0.4462, 0.5172, 0.5827, 0.642, 0.6953, 0.7427, 0.7846, 0.8213, 0.8533, 0.881, 0.905, 0.9257, 0.9435, 0.9587, 0.9716, 0.9827, 0.992, 1)";
  var FALLBACK_EASE = "cubic-bezier(.4,0,.2,1)";
  var LEVEL_COLORS = { normal: "#4A9E5C", warning: "#D4A843", critical: "#D71921" };
  var EMPTY_SEGMENT_COLOR = "#222222";

  function canAnimate() {
    return typeof window.Element === "function"
      && window.Element.prototype
      && typeof window.Element.prototype.animate === "function";
  }

  function springEasing() {
    try {
      if (typeof CSS !== "undefined" && CSS.supports
        && CSS.supports("animation-timing-function", "linear(0,1)")) {
        return SPRING;
      }
    } catch (error) {}
    return FALLBACK_EASE;
  }

  function clampPercent(value) {
    var number = Number(value);
    return Number.isFinite(number) ? Math.max(0, Math.min(100, number)) : 0;
  }

  function levelOf(percent) {
    return percent < 50 ? "normal" : percent < 80 ? "warning" : "critical";
  }

  function peakWindow(section) {
    var peak = null;
    var rows = [].concat(section.windows || [], ...(section.accounts || []).map(function (account) {
      return account.windows || [];
    }));
    for (var index = 0; index < rows.length; index += 1) {
      var row = rows[index];
      if (peak === null || row.usedPercent > peak.usedPercent) peak = row;
    }
    return peak;
  }

  // 补间 key 的唯一来源: 渲染器 (app.js) 与补间层共用, 不得各自拼字符串.
  // 窗口行恒含两个 "|"; 收起行 / 迷你条用 "|#" 前缀, 不会与任何窗口 label 撞键.
  var keys = {
    meter: function (sectionID, accountID, label) {
      return sectionID + "|" + (accountID || "") + "|" + label;
    },
    collapsed: function (sectionID) { return sectionID + "|#collapsed"; },
    mini: function (sectionID) { return sectionID + "|#mini"; },
    percent: function (rowKey) { return rowKey + "||pct"; },
    balance: function (sectionID) { return sectionID + "||bal"; },
    chip: function (sectionID) { return sectionID + "||chip"; },
  };
  var meterKey = keys.meter;

  function meterValues(panel) {
    var map = new Map();
    var sections = (panel && panel.subscription && panel.subscription.sections) || [];
    for (var index = 0; index < sections.length; index += 1) {
      var section = sections[index];
      for (var windowIndex = 0; windowIndex < (section.windows || []).length; windowIndex += 1) {
        var row = section.windows[windowIndex];
        map.set(meterKey(section.id, "", row.label), row.usedPercent);
      }
      for (var accountIndex = 0; accountIndex < (section.accounts || []).length; accountIndex += 1) {
        var account = section.accounts[accountIndex];
        for (var accountWindowIndex = 0; accountWindowIndex < (account.windows || []).length; accountWindowIndex += 1) {
          var accountRow = account.windows[accountWindowIndex];
          map.set(meterKey(section.id, account.id, accountRow.label), accountRow.usedPercent);
        }
      }
      if (section.collapsedWindow) {
        map.set(keys.collapsed(section.id), section.collapsedWindow.usedPercent);
      }
      var peak = peakWindow(section);
      if (peak) map.set(keys.mini(section.id), peak.usedPercent);
    }
    return map;
  }

  function balanceValues(panel) {
    var map = new Map();
    var sections = (panel && panel.subscription && panel.subscription.sections) || [];
    for (var index = 0; index < sections.length; index += 1) {
      var section = sections[index];
      if (!section.balance) continue;
      map.set(keys.balance(section.id), section.balance.amountText);
      map.set(keys.chip(section.id), section.balance.amountText);
    }
    return map;
  }

  function percentValues(panel) {
    var map = new Map();
    var sections = (panel && panel.subscription && panel.subscription.sections) || [];
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex += 1) {
      var section = sections[sectionIndex];
      for (var windowIndex = 0; windowIndex < (section.windows || []).length; windowIndex += 1) {
        var row = section.windows[windowIndex];
        map.set(keys.percent(meterKey(section.id, "", row.label)), row.percentText);
      }
      for (var accountIndex = 0; accountIndex < (section.accounts || []).length; accountIndex += 1) {
        var account = section.accounts[accountIndex];
        for (var accountWindowIndex = 0; accountWindowIndex < (account.windows || []).length; accountWindowIndex += 1) {
          var accountRow = account.windows[accountWindowIndex];
          map.set(keys.percent(meterKey(section.id, account.id, accountRow.label)), accountRow.percentText);
        }
      }
      if (section.collapsedWindow) {
        map.set(keys.percent(keys.collapsed(section.id)), section.collapsedWindow.percentText);
      }
    }
    return map;
  }

  // Nothing 分段补间计划 (纯函数, 测试直接断言): 只列出颜色有变化的段.
  // 渲染出的 DOM 已是终值; 错峰段在 delay 期间必须保持起点色 (fill: "backwards"),
  // 否则会先闪出终值、再跳回旧色、再补间.
  function segmentPlan(fromPercent, toPercent) {
    var oldFilled = Math.round(clampPercent(fromPercent) / 100 * SEGMENT_COUNT);
    var newFilled = Math.round(clampPercent(toPercent) / 100 * SEGMENT_COUNT);
    var oldLevel = levelOf(clampPercent(fromPercent));
    var newLevel = levelOf(clampPercent(toPercent));
    var boundary = Math.min(oldFilled, newFilled);
    var plan = [];
    for (var index = 0; index < SEGMENT_COUNT; index += 1) {
      var wasFilled = index < oldFilled;
      var isFilled = index < newFilled;
      var from = wasFilled ? oldLevel : "empty";
      var to = isFilled ? newLevel : "empty";
      if (from === to) continue;
      plan.push({
        index: index,
        from: from,
        to: to,
        delay: Math.abs(index - boundary) * SEGMENT_STAGGER,
        duration: SEGMENT_DURATION,
        fill: "backwards",
      });
    }
    return plan;
  }

  function segmentColor(key) {
    return key === "empty" ? EMPTY_SEGMENT_COLOR : LEVEL_COLORS[key];
  }

  function animateSegmented(meter, fromPercent, toPercent) {
    var segments = meter.children;
    segmentPlan(fromPercent, toPercent).forEach(function (step) {
      var segment = segments[step.index];
      if (!segment || typeof segment.animate !== "function") return;
      segment.animate(
        [{ backgroundColor: segmentColor(step.from) }, { backgroundColor: segmentColor(step.to) }],
        { duration: step.duration, delay: step.delay, easing: "ease-out", fill: step.fill }
      );
    });
  }

  function animateMeters(before, after) {
    var nodes = document.querySelectorAll("[data-motion-key]");
    Array.prototype.forEach.call(nodes, function (node) {
      var key = node.getAttribute("data-motion-key");
      var from = before.get(key);
      var to = after.get(key);
      if (from == null || to == null || Math.abs(to - from) < 0.5) return;
      var meter = node.classList.contains("meter") ? node : node.querySelector(".meter");
      if (!meter) return;
      if (meter.classList.contains("segmented")) {
        animateSegmented(meter, from, to);
        return;
      }
      var fill = null;
      for (var index = 0; index < meter.children.length; index += 1) {
        if (meter.children[index].tagName !== "I") { fill = meter.children[index]; break; }
      }
      if (!fill || typeof fill.animate !== "function") return;
      fill.animate(
        [{ width: clampPercent(from) + "%" }, { width: clampPercent(to) + "%" }],
        { duration: BAR_DURATION, easing: springEasing(), fill: "none" }
      );
    });
  }

  function tokenize(text) {
    var tokens = [];
    var value = String(text || "");
    for (var index = 0; index < value.length; index += 1) {
      var character = value[index];
      if (character >= "0" && character <= "9") tokens.push({ digit: true, value: character });
      else tokens.push({ digit: false, value: character });
    }
    return tokens;
  }

  function sameSkeleton(left, right) {
    if (left.length !== right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index].digit !== right[index].digit) return false;
      if (!left[index].digit && left[index].value !== right[index].value) return false;
    }
    return true;
  }

  function numericAmount(text) {
    var parsed = parseFloat(String(text || "").replace(/[^0-9.-]/g, ""));
    return Number.isFinite(parsed) ? parsed : null;
  }

  function rollDigit(element, from, to, direction, duration, easing) {
    element.textContent = "";
    // 隐藏占位留在文档流里, 撑住新数字的宽度与文字基线; 进出两位绝对定位.
    var hold = document.createElement("span");
    hold.className = "motion-hold";
    hold.textContent = to;
    var outgoing = document.createElement("span");
    outgoing.className = "motion-out";
    outgoing.textContent = from;
    var incoming = document.createElement("span");
    incoming.className = "motion-in";
    incoming.textContent = to;
    element.append(hold, outgoing, incoming);
    outgoing.animate([
      { transform: "translateY(0)", opacity: 1 },
      { transform: "translateY(" + (direction > 0 ? "-100%" : "100%") + ")", opacity: 0 },
    ], { duration: duration, easing: easing, fill: "forwards" });
    incoming.animate([
      { transform: "translateY(" + (direction > 0 ? "100%" : "-100%") + ")", opacity: 0.45 },
      { transform: "translateY(0)", opacity: 1 },
    ], { duration: duration, easing: easing, fill: "forwards" });
    setTimeout(function () {
      element.textContent = to;
      element.setAttribute("data-d", to);
    }, duration);
  }

  // 数字列逐位滚动: 余额 0.6s, 百分比与量条同一 0.85s 事务; 曲线同为临界阻尼弹簧.
  function rollNumber(element, fromText, toText, duration) {
    var fromTokens = tokenize(fromText);
    var toTokens = tokenize(toText);
    var fromValue = numericAmount(fromText);
    var toValue = numericAmount(toText);
    var direction = (toValue === null ? 0 : toValue) >= (fromValue === null ? 0 : fromValue) ? 1 : -1;

    if (!sameSkeleton(fromTokens, toTokens)) {
      // 位数 / 千分位骨架变化: 整体上下换行, 不逐位错位
      if (typeof element.animate === "function") {
        element.animate([
          { opacity: 0, transform: "translateY(" + (direction > 0 ? "60%" : "-60%") + ")" },
          { opacity: 1, transform: "translateY(0)" },
        ], { duration: 280, easing: "ease-out", fill: "none" });
      }
      return;
    }

    var digits = element.querySelectorAll(".motion-digit");
    var digitIndex = 0;
    for (var index = 0; index < fromTokens.length; index += 1) {
      if (!fromTokens[index].digit) continue;
      if (fromTokens[index].value !== toTokens[index].value) {
        var column = digits[digitIndex];
        if (column) {
          rollDigit(column, fromTokens[index].value, toTokens[index].value, direction, duration, springEasing());
        }
      }
      digitIndex += 1;
    }
  }

  function animateBalances(before, after) {
    var nodes = document.querySelectorAll("[data-balance-key]");
    Array.prototype.forEach.call(nodes, function (node) {
      var key = node.getAttribute("data-balance-key");
      var from = before.get(key);
      var to = after.get(key);
      if (!from || !to || from === to) return;
      rollNumber(node, from, to, DIGIT_DURATION);
    });
  }

  function animatePercents(before, after) {
    var nodes = document.querySelectorAll("[data-percent-key]");
    Array.prototype.forEach.call(nodes, function (node) {
      var key = node.getAttribute("data-percent-key");
      var from = before.get(key);
      var to = after.get(key);
      if (!from || !to || from === to) return;
      rollNumber(node, from, to, BAR_DURATION);
    });
  }

  function animatePanelMotion(previousPanel, currentPanel, options) {
    var settings = options || {};
    if (!settings.animate || !previousPanel || !currentPanel) return;
    if (settings.motionSuppressed) return;
    if (document.hidden === true) return;
    if (!canAnimate()) return;
    animateMeters(meterValues(previousPanel), meterValues(currentPanel));
    animatePercents(percentValues(previousPanel), percentValues(currentPanel));
    animateBalances(balanceValues(previousPanel), balanceValues(currentPanel));
  }

  window.BruceMotion = {
    animatePanelMotion: animatePanelMotion,
    keys: keys,
    internals: {
      segmentPlan: segmentPlan,
      tokenize: tokenize,
      sameSkeleton: sameSkeleton,
      numericAmount: numericAmount,
      meterValues: meterValues,
      balanceValues: balanceValues,
      percentValues: percentValues,
    },
  };
})();
