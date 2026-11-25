// 设置页「网络出口国家校验」(C264, design/11 §3.1): 独立国家组、
// 本机回环专用代理端口与受管订阅；解除分组绝不触碰底层凭据。
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections = window.BruceSettingsSections || {};
  const { node, byId, invoke, persist, providers, state } = core;

  const QUICK_COUNTRIES = [
    ["JP", "🇯🇵 日本"],
    ["US", "🇺🇸 美国"],
    ["SG", "🇸🇬 新加坡"],
    ["GB", "🇬🇧 英国"],
    ["HK", "🇭🇰 香港"],
  ];
  const PROVIDER_LABELS = Object.fromEntries(providers.map(([id, label]) => [id, label]));

  let hostRef = null;

  function groups() {
    return (state.settings.egressGroups || []).map((group) => ({
      country: group.country,
      providers: [...(group.providers || [])],
      proxyPort: group.proxyPort ?? null,
      lastTestResult: group.lastTestResult ?? null,
    }));
  }

  function countryFlag(code) {
    const value = String(code || "").toUpperCase();
    if (!/^[A-Z]{2}$/.test(value)) return "";
    return String.fromCodePoint(...[...value].map((char) => 127397 + char.charCodeAt(0)));
  }

  function toneFor(result) {
    if (!result) return "off";
    if (result.startsWith("线路探测匹配")) return "ok";
    if (result.startsWith("出口国家不匹配") || result.includes("国内")) return "danger";
    return "warn";
  }

  async function saveGroups(next, { rerender = true } = {}) {
    const ok = await persist({ egressGroups: next });
    if (rerender) render();
    return ok;
  }

  function setPort(code, rawValue) {
    const digits = [...String(rawValue || "")].filter((char) => char >= "0" && char <= "9").join("");
    const next = groups();
    const group = next.find((item) => item.country === code);
    if (!group) return;
    if (!digits) {
      group.proxyPort = null;
    } else {
      const port = Number(digits);
      if (!Number.isInteger(port) || port < 1 || port > 65535) return;
      group.proxyPort = port;
      group.lastTestResult = null; // 端口变更清空旧结论, 避免误导当前线路。
    }
    saveGroups(next);
  }

  function toggleProvider(code, providerId) {
    const next = groups();
    const target = next.find((item) => item.country === code);
    if (!target) return;
    if (target.providers.includes(providerId)) {
      target.providers = target.providers.filter((id) => id !== providerId);
    } else {
      for (const group of next) {
        group.providers = group.providers.filter((id) => id !== providerId);
      }
      target.providers.push(providerId);
    }
    saveGroups(next);
  }

  function addCountry(code) {
    const value = String(code || "").trim().toUpperCase();
    if (!/^[A-Z]{2}$/.test(value)) {
      message("请输入 2 位 ISO 国家代码", "warn");
      return false;
    }
    const next = groups();
    if (next.some((group) => group.country === value)) {
      message(`${value} 已存在`, "warn");
      return false;
    }
    next.push({ country: value, providers: [], proxyPort: null, lastTestResult: null });
    saveGroups(next);
    return true;
  }

  function message(text, tone = "info") {
    const host = byId("egress-status");
    if (!host) return;
    host.textContent = text;
    host.dataset.tone = tone;
  }

  function renderGroup(group) {
    const block = node("section", null, { class: "egress-group" });
    const head = node("div", null, { class: "egress-group-head" });
    head.append(node("span", "egress-group-flag", countryFlag(group.country)));
    head.append(node("b", `${group.country}`, { class: "egress-group-country" }));

    const port = node("input", null, {
      type: "text", class: "egress-port", placeholder: "代理端口", value: group.proxyPort ?? "",
      "aria-label": `${group.country} 专用代理端口`,
    });
    port.addEventListener("change", () => setPort(group.country, port.value));
    head.append(port);

    const test = node("button", "测试线路", { type: "button", class: "btn plain-btn egress-test" });
    test.disabled = group.proxyPort == null;
    test.addEventListener("click", async () => {
      test.disabled = true;
      test.textContent = "探测中…";
      try {
        const response = await invoke("egress_test", { country: group.country, port: group.proxyPort });
        const next = groups();
        const current = next.find((item) => item.country === group.country);
        if (current) {
          current.lastTestResult = response?.result || null;
          await saveGroups(next, { rerender: false });
        }
        message(response?.result || "线路探测完成", toneFor(response?.result));
        render();
      } catch (error) {
        message(`线路测试失败：${error?.message || error}`, "warn");
        test.disabled = false;
        test.textContent = "测试线路";
      }
    });
    head.append(test);

    const dissolve = node("button", "解散", { type: "button", class: "btn plain-btn egress-remove" });
    dissolve.title = "解散此通道（不删除订阅凭据）";
    dissolve.addEventListener("click", () => {
      saveGroups(groups().filter((item) => item.country !== group.country));
    });
    head.append(dissolve);
    block.append(head);

    const result = group.lastTestResult
      || (group.proxyPort ? `127.0.0.1:${group.proxyPort} · 尚未测试` : "尚未配置代理端口");
    block.append(node("div", result, { class: `egress-result ${toneFor(group.lastTestResult)}` }));

    // 只列已添加的订阅; 已在该组但后来被移除的 Provider 仍显示以便解除。
    const added = new Set(Object.keys(state.settings.subscriptionProviders || {}));
    const visible = new Set([
      ...(added.size ? added : (state.settings.enabledProviders || [])),
      ...group.providers,
    ]);
    const chips = node("div", null, { class: "egress-providers" });
    for (const [id, label] of Object.entries(PROVIDER_LABELS)) {
      if (!visible.has(id)) continue;
      const on = group.providers.includes(id);
      const chip = node("button", label, {
        type: "button", class: on ? "egress-provider active" : "egress-provider", "aria-pressed": String(on),
      });
      chip.addEventListener("click", () => toggleProvider(group.country, id));
      chips.append(chip);
    }
    block.append(chips);
    return block;
  }

  function render() {
    if (!hostRef) return;
    hostRef.replaceChildren();
    const intro = node("p", "保护受管订阅在查询额度时的出口国家。未加入分组的订阅不受影响；每组须配置本机回环专用代理端口。", { class: "hint" });
    hostRef.append(intro);

    const addRow = node("div", null, { class: "egress-add" });
    const input = node("input", null, {
      type: "text", class: "egress-add-input", placeholder: "国家代码（如 JP）", maxlength: "2",
      "aria-label": "添加国家代码",
    });
    addRow.append(input);
    for (const [code, label] of QUICK_COUNTRIES) {
      const quick = node("button", label, { type: "button", class: "egress-quick" });
      quick.addEventListener("click", () => { input.value = code; addCountry(code); });
      addRow.append(quick);
    }
    const add = node("button", "添加国家", { type: "button", class: "btn plain-btn" });
    add.addEventListener("click", () => addCountry(input.value));
    addRow.append(add);
    hostRef.append(addRow);
    hostRef.append(node("div", null, { id: "egress-status", class: "egress-status", role: "status" }));

    const current = groups();
    if (!current.length) {
      hostRef.append(node("div", "尚未配置出口国家组", { class: "egress-empty" }));
      return;
    }
    for (const group of current) hostRef.append(renderGroup(group));
  }

  function buildEgressCard(host) {
    hostRef = node("div", null, { class: "egress-card" });
    host.append(hostRef);
    render();
  }

  Object.assign(S, { buildEgressCard });
})();
