// Bruce 软件更新表现层 (T11, 07-软件更新 §4.2 R3/R4) —— 纯函数, 无 DOM 无网络。
// 文案与状态区语义逐字对齐 apps/win/demo/win-settings-update-flow-demo.html, 并与 mac 侧
// BruceAppCore/SoftwareUpdatePresentation.swift 共享对拍用例
// tests/fixtures/update-copy-parity/cases.json (由 scripts/check-win-frontend.mjs 逐例执行)。
// 改动任何字面量必须同步 fixture 与 mac 实现。
//
// 时间口径: checkedAt/lastCheckAt 为 RFC3339 带偏移字符串; 「今天」按字符串内民事日期比较
// (不经过宿主时区), 保证任何 CI 环境与 mac Calendar 本地日语义一致 (24 小时制, 不随 12 小时制漂移)。

(() => {
  const copy = {
    caption: "软件更新",
    autoCheckTitle: "自动检查更新",
    autoCheckSubtitle: "启动 30 秒后静默检查一次, 之后每 24 小时一次; 检查失败不打扰",
    currentVersionTitle: "当前版本",
    devVersionValue: "开发版本",
    checkTitle: "检查更新",
    checkButton: "检查更新",
    navigationBadge: "有可用更新",
    lastCheckNever: "上次检查 —",
    checking: "正在检查更新…",
    bannerTitle: "发现新版本",
    expandNotes: " 展开",
    collapseNotes: " 收起",
    failedTitle: "检查失败",
    relaunching: "正在安装并重启…",
    manualInstallHint: "当前安装位置不支持自动更新, 请从发布页下载新版本",
  };

  // 状态区动作: title 逐字对齐 demo; role 决定 primary / plain / link 样式。
  const ACTIONS = {
    downloadAndInstall: { title: "下载并安装", role: "primary" },
    skipVersion: { title: "跳过此版本", role: "plain" },
    openReleasePage: { title: "查看发布页 ↗", role: "link" },
    cancelDownload: { title: "取消", role: "link" },
    installAndRelaunch: { title: "安装并重启", role: "primary" },
    later: { title: "稍后", role: "link" },
    retry: { title: "重试", role: "link" },
    manualDownload: { title: "手动下载 ↗", role: "link" },
    resumeChecks: { title: "恢复检查", role: "link" },
  };
  const action = key => ({ key, ...ACTIONS[key] });

  // ---- 时间 ----

  // RFC3339 民事字段: 直接取字符串内的年月日时分 (含偏移语义自洽, 与宿主时区无关)。
  function civilFromIso(iso) {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(iso || ""));
    if (!m) return null;
    return { y: +m[1], m: +m[2], d: +m[3], hh: m[4], mm: m[5] };
  }

  // 当前本地时间 → 同构民事字段 (年/月/日/时/分 + 与 civilFromIso 相同的字符串形态)。
  function civilNow(now) {
    if (typeof now === "string") {
      const fromIso = civilFromIso(now);
      if (fromIso) return fromIso;
    }
    const date = now instanceof Date ? now : new Date();
    const pad = (v, w = 2) => String(v).padStart(w, "0");
    return { y: date.getFullYear(), m: date.getMonth() + 1, d: date.getDate(), hh: pad(date.getHours()), mm: pad(date.getMinutes()) };
  }

  // 同日 `今天 HH:mm`, 跨天 `M月d日 HH:mm`。
  function timestamp(iso, now) {
    const at = civilFromIso(iso);
    if (!at) return "";
    const clock = `${at.hh}:${at.mm}`;
    const ref = civilNow(now);
    if (at.y === ref.y && at.m === ref.m && at.d === ref.d) return `今天 ${clock}`;
    return `${at.m}月${at.d}日 ${clock}`;
  }

  function lastCheckSubtitle(lastCheckAt, now) {
    if (!lastCheckAt) return copy.lastCheckNever;
    return `上次检查 ${timestamp(lastCheckAt, now)}`;
  }

  // ---- 版本与进度 ----

  function currentVersion(localVersion) {
    // C142: 行内不再有频道副标题, 只返回版本值.
    return { value: localVersion ? `v${localVersion}` : copy.devVersionValue };
  }

  // 十进制 MB 一位小数 (与 mac 同口径)。
  function megabytes(bytes) {
    return (Math.max(bytes || 0, 0) / 1000000).toFixed(1);
  }

  function downloadFraction(progress) {
    const total = progress && progress.totalBytes;
    if (!total || total <= 0) return 0;
    return Math.min(Math.max((progress.receivedBytes || 0) / total, 0), 1);
  }

  // `3.2 / 7.1 MB · 45%`; 总量未知时只显示已下载 `3.2 MB`。
  function downloadMeta(progress) {
    const total = progress && progress.totalBytes;
    if (!total || total <= 0) return `${megabytes(progress.receivedBytes)} MB`;
    return `${megabytes(progress.receivedBytes)} / ${megabytes(total)} MB · ${Math.floor(downloadFraction(progress) * 100)}%`;
  }

  // 更新说明要点: 清单 notes 为「; 」连接纯文本 (T09 生成器), demo 为换行分隔, 两者都识别;
  // 换行形态在 demo 中以空格拼接为单段。
  function noteItems(notes) {
    const raw = String(notes || "");
    const separator = raw.includes("\n") ? "\n" : "; ";
    const items = raw.split(separator).map(s => s.trim()).filter(Boolean);
    return { items, joiner: separator === "\n" ? " " : "; " };
  }

  // ---- 状态区 ----

  // 「发现新版本」横幅。
  function banner(release, localVersion, canSelfInstall) {
    const { items, joiner } = noteItems(release.notes);
    return {
      kind: "banner",
      title: copy.bannerTitle,
      fromVersion: localVersion ? `v${localVersion}` : copy.devVersionValue,
      toVersion: `v${release.version}`,
      collapsedNotes: items.slice(0, 2).join(joiner),
      fullNotes: items.join(joiner),
      notesTruncated: items.length > 2,
      sizeText: release.sizeBytes != null ? `${megabytes(release.sizeBytes)} MB` : null,
      actions: (canSelfInstall ? ["downloadAndInstall", "skipVersion", "openReleasePage"] : ["skipVersion", "openReleasePage"]).map(action),
      hint: canSelfInstall ? null : copy.manualInstallHint,
    };
  }

  // 状态区内容; kind=hidden 对应 demo 的 `:empty { display: none }`。
  function stageView(phase, ctx) {
    const release = (ctx && ctx.release) || {};
    const localVersion = ctx && ctx.localVersion;
    const canSelfInstall = !ctx || ctx.canSelfInstall !== false;
    switch (phase.kind) {
      case "idle": return { kind: "hidden" };
      case "checking": return { kind: "spinner", text: copy.checking };
      case "latest": return { kind: "confirmation", text: `已是最新版本 · 检查于 ${timestamp(phase.checkedAt, ctx && ctx.now)}` };
      case "available": return banner(release, localVersion, canSelfInstall);
      case "downloading":
        return { kind: "download", fraction: downloadFraction(phase), meta: downloadMeta(phase), actions: [action("cancelDownload")] };
      case "ready":
        return { kind: "ready", text: `v${release.version} 已下载完成,重启后生效`, actions: [action("installAndRelaunch"), action("later")] };
      case "failed":
        return { kind: "failure", title: copy.failedTitle, detail: failureDetail(phase), actions: [action("retry"), action("manualDownload")] };
      case "skipped":
        return { kind: "skipped", text: `已跳过 v${release.version};发布下个版本前不再提醒 · `, actions: [action("resumeChecks")] };
      case "relaunching": return { kind: "spinner", text: copy.relaunching };
      default: return { kind: "hidden" };
    }
  }

  // 导航角标与「检查更新」按钮可用性 (demo 状态机表)。
  function stageFlags(phase) {
    return {
      navBadge: phase.kind === "available" || phase.kind === "downloading" || phase.kind === "ready",
      checkEnabled: phase.kind !== "checking" && phase.kind !== "downloading" && phase.kind !== "relaunching",
    };
  }

  // ---- 失败文案 ----

  function failureDetail(phase) {
    switch (phase.failure) {
      case "timedOut": return "无法访问 GitHub (超时 10 秒);可稍后重试或手动下载";
      case "offline": return "无法访问 GitHub (网络不可用);可稍后重试或手动下载";
      case "httpStatus": return `无法获取更新信息 (HTTP ${phase.httpStatus});可稍后重试或手动下载`;
      default: return "更新信息无法识别;可稍后重试或手动下载";
    }
  }

  function failureStatusLine(phase) {
    switch (phase.failure) {
      case "timedOut": return "检查更新失败：网络超时";
      case "offline": return "检查更新失败：网络不可用";
      case "httpStatus": return `检查更新失败：HTTP ${phase.httpStatus}`;
      default: return "检查更新失败：更新信息无效";
    }
  }

  // 安装链路失败 → 设置窗口顶部状态行 (settings-status warn)。
  // downloadFailed 与 mac 共享 (fixture installFailures); Windows 经 tauri-plugin-updater
  // (minisign 验签 + NSIS 静默安装), 其余为 Windows 特有文案。
  function installFailureStatusLine(kind) {
    switch (kind) {
      case "downloadFailed": return "下载更新失败：网络错误, 可稍后重试";
      case "signatureInvalid": return "更新包校验失败：签名校验不通过, 已拒绝安装";
      case "installFailed": return "安装更新失败：请从发布页重新安装";
      default: return "安装更新失败：请稍后重试";
    }
  }

  window.BruceUpdatePresentation = {
    copy, action, timestamp, lastCheckSubtitle, currentVersion,
    megabytes, downloadMeta, downloadFraction, noteItems,
    stageView, stageFlags, failureDetail, failureStatusLine, installFailureStatusLine,
  };
})();
