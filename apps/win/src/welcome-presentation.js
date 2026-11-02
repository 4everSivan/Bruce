// Bruce 首次启动欢迎与引导向导共享表现层 (T22, 10-首次启动欢迎与引导向导 §4.2 R1–R6) —— 纯函数, 无 DOM 无网络。
// 文案、步骤状态机与准入判据同 mac 侧 BruceAppCore/WelcomeOnboardingPresentation.swift 共享对拍用例
// tests/fixtures/welcome-onboarding-parity/cases.json。

(() => {
  const CURRENT_WELCOME_VERSION = 1;

  const copy = {
    windowTitle: "欢迎使用 Bruce",
    brandSubtitle: "LOCAL-FIRST",
    privacyTitle: "100% 本地只读闭环",
    privacyBody: "不代理对话流量、不修改外部会话数据库（SQLite 强制 mode=ro），凭据以 POSIX 0600 权限保存在本机目录。",
    step1NavTitle: "环境扫描与启用",
    step1NavSubtitle: "自动探测本机 Agent 目录",
    step2NavTitle: "订阅额度连接",
    step2NavSubtitle: "可选 · 一键导入或稍后配置",
    step3NavTitle: "外观与快捷唤出",
    step3NavSubtitle: "菜单栏预览 · 主题与快捷键",
    step1Eyebrow: "STEP 01 · WELCOME & LOCAL SCAN",
    step1Title: "欢迎使用 Bruce",
    step1Description: "Bruce 已在后台完成本机只读探测。点击下方主按钮即可一步开启本地 Token 与费用统计，无需逐项翻找设置。",
    step1SectionTitle: "本机 AI Agent 会话源（只读扫描）",
    step1RescanButton: "重新扫描",
    step1ConsentTitle: "一步启用：本地会话统计 + 本机 0600 凭据存储",
    step1ConsentBody: "只读扫描已发现的 Agent 目录与 CC Switch 数据库（每 30 分钟自动刷新）；订阅凭据统一保存在本机受保护文件（权限 0600），彻底告别系统钥匙串频繁弹窗。可随时在「设置 → 授权与隐私」撤销。",
    step1PrimaryButton: "启用本地统计并继续 →",
    step2Eyebrow: "STEP 02 · SUBSCRIPTION QUOTA",
    step2OptionalBadge: "可选步骤 · 可随时跳过",
    step2Title: "连接云端订阅额度",
    step2Description: "监控 5 小时滑动窗、周限额与 API 余额预警。若本机已登录 CLI 或 CC Switch，可直接一键只读导入；也可跳过此步，先看本地 Token 统计。",
    step2DiscoveryTitle: "发现本机已登录凭据（免填 Key 一键导入）",
    step2ImportButton: "一键只读导入",
    step2ImportedBadge: "✓ 已导入",
    step2ProvidersSectionTitle: "支持的服务商（10 家）· 也可在「设置 → 订阅额度」随时添加",
    step2BackButton: "← 上一步",
    step2SkipButton: "稍后在设置中配置",
    step2NextButton: "继续 →",
    step3Eyebrow: "STEP 03 · APPEARANCE & SHORTCUT",
    step3Title: "定制你的菜单栏看板",
    step3Description: "完成最后一步外观与热键偏好，点击「完成并打开看板」即刻在菜单栏展开实时监控。",
    step3RingOuterTitle: "外母环 · 全局平均剩余额度",
    step3RingOuterSubtitle: "≥30% 翡翠绿 · 15~30% 琥珀黄 · <15% 警示红",
    step3RingInnerTitle: "内子环 · 最紧缺窗口短板预警",
    step3RingInnerSubtitle: "防止长周期充裕掩盖 5h 窗口即将耗尽的断流风险",
    step3FinishButton: "完成并打开看板 ↵",
    settingsRowTitle: "欢迎与使用引导",
    settingsRowSubtitle: "重新查看三步快速上手向导、本机 Agent 扫描状态与菜单栏双环图解",
    settingsReopenButton: "重新打开欢迎向导",
  };

  const steps = [
    {
      index: 1,
      id: "environmentScan",
      railTitle: copy.step1NavTitle,
      railSubtitle: copy.step1NavSubtitle,
      badgeText: copy.step1Eyebrow,
      title: copy.step1Title,
      subtitle: copy.step1Description,
    },
    {
      index: 2,
      id: "subscriptionConnect",
      railTitle: copy.step2NavTitle,
      railSubtitle: copy.step2NavSubtitle,
      badgeText: copy.step2Eyebrow,
      title: copy.step2Title,
      subtitle: copy.step2Description,
    },
    {
      index: 3,
      id: "appearanceAndShortcut",
      railTitle: copy.step3NavTitle,
      railSubtitle: copy.step3NavSubtitle,
      badgeText: copy.step3Eyebrow,
      title: copy.step3Title,
      subtitle: copy.step3Description,
    },
  ];

  function shouldPresentWelcome(welcomeCompletedVersion, consentConfirmed, keychainAccessConfigured) {
    if ((Number(welcomeCompletedVersion) || 0) >= CURRENT_WELCOME_VERSION) {
      return false;
    }
    if (Boolean(consentConfirmed) && Boolean(keychainAccessConfigured)) {
      return false;
    }
    return true;
  }

  function readySourcesSummary(readyCount) {
    const r = Number(readyCount) || 0;
    if (r > 0) {
      return `已发现 ${r} 个就绪源`;
    }
    return "暂未发现活跃源（仍可启用）";
  }

  function menuBarPreviewMetricsText(isNothingTheme, iconOnly) {
    if (iconOnly) {
      return "";
    }
    if (isNothingTheme) {
      return "68% / 124K / $1.28";
    }
    return "68%  124K  $1.28";
  }

  const BruceWelcomePresentation = {
    CURRENT_WELCOME_VERSION,
    copy,
    steps,
    shouldPresentWelcome,
    readySourcesSummary,
    menuBarPreviewMetricsText,
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = BruceWelcomePresentation;
  }
  if (typeof window !== "undefined") {
    window.BruceWelcomePresentation = BruceWelcomePresentation;
  }
})();
