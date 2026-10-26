import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";

// A small DOM boundary for executing the production scripts. This does not
// replace WebView2/native-window acceptance; selectors and events are real
// inputs to the same code shipped in both HTML entry points.
export class Element {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.listeners = new Map();
    this.attributes = {};
    this.dataset = {};
    // 样式桩: cssText/直接属性赋值照旧, 另支持 CSS 自定义属性下发
    // (app.js 用 style.setProperty("--hero-grad-start", ...) 传递档位色)。
    this.style = {
      setProperty(name, value) { this[name] = String(value); },
      getPropertyValue(name) { return this[name] ?? ""; },
    };
    this.value = "";
    this.checked = false;
    this.disabled = false;
    this._text = "";
    this.classList = {
      contains: value => this.className.split(/\s+/).includes(value),
      add: (...values) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...values])].join(" "); },
      remove: (...values) => { this.className = this.className.split(/\s+/).filter(x => !values.includes(x)).join(" "); },
      toggle: (value, force) => {
        const enabled = force ?? !this.classList.contains(value);
        this.classList[enabled ? "add" : "remove"](value);
        return enabled;
      },
    };
  }
  get id() { return this.attributes.id || ""; }
  set id(value) { this.attributes.id = value; }
  get className() { return this.attributes.class || ""; }
  set className(value) { this.attributes.class = value; }
  get textContent() { return this._text + this.children.map(x => x.textContent).join(""); }
  set textContent(value) { this.children = []; this._text = String(value ?? ""); }
  set innerHTML(value) {
    if (value !== "") throw new Error("DOM harness only supports clearing innerHTML");
    this.children = []; this._text = "";
  }
  get innerHTML() { return this.textContent; }
  append(...nodes) {
    for (const value of nodes) {
      const node = typeof value === "string" ? new Element("#text") : value;
      if (typeof value === "string") node.textContent = value;
      node.parentElement = this;
      this.children.push(node);
    }
  }
  replaceChildren(...nodes) { this.innerHTML = ""; this.append(...nodes); }
  remove() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(x => x !== this); }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name.startsWith("data-")) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = String(value);
    if (name === "value") this.value = String(value);
    if (name === "checked") this.checked = true;
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(type, callback) { this.listeners.set(type, [...(this.listeners.get(type) || []), callback]); }
  async dispatch(type, values = {}) {
    const event = { target: this, currentTarget: this, preventDefault() {}, ...values };
    await Promise.all((this.listeners.get(type) || []).map(callback => callback(event)));
  }
  async click() { if (!this.disabled) await this.dispatch("click"); }
  matches(selector) {
    const attrs = [...selector.matchAll(/\[([\w-]+)(?:=["']?([^\]"']+)["']?)?\]/g)];
    const bare = selector.replace(/\[[^\]]+\]/g, "");
    const tag = bare.match(/^[a-z]+/i)?.[0];
    const id = bare.match(/#([\w-]+)/)?.[1];
    const classes = [...bare.matchAll(/\.([\w-]+)/g)].map(x => x[1]);
    return (!tag || this.tagName === tag.toUpperCase()) && (!id || this.id === id)
      && classes.every(x => this.classList.contains(x))
      && attrs.every(([, key, val]) => {
        const actual = key.startsWith("data-") ? this.dataset[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] : this.attributes[key];
        return actual !== undefined && (val === undefined || actual === val);
      });
  }
  querySelectorAll(selector) {
    const parts = selector.trim().split(/\s+/);
    const all = [];
    const seen = new Set();   // 同一元素在遍历中可能被重复访问, 按元素身份去重
    const visit = node => {
      for (const child of node.children) {
        if (child.matches(parts.at(-1))) {
          let parent = child.parentElement, index = parts.length - 2;
          while (parent && index >= 0) {
            if (parent.matches(parts[index])) index -= 1;
            parent = parent.parentElement;
          }
          if (index < 0 && !seen.has(child)) { seen.add(child); all.push(child); }
        }
        visit(child);
      }
    };
    visit(this);
    return all;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}

function parseHTML(source) {
  const root = new Element("document");
  const stack = [root];
  for (const token of source.matchAll(/<\/?[a-z][^>]*>|[^<]+/gi)) {
    const text = token[0];
    if (text.startsWith("</")) { stack.pop(); continue; }
    if (!text.startsWith("<")) { if (text.trim()) stack.at(-1).append(text); continue; }
    const tag = text.match(/^<([a-z0-9-]+)/i)[1];
    const node = new Element(tag);
    for (const [, key, double, single, bare] of text.matchAll(/([\w-]+)(?:="([^"]*)"|='([^']*)'|=([^\s>]+))?/g)) {
      if (key !== tag) node.setAttribute(key, double ?? single ?? bare ?? "");
    }
    stack.at(-1).append(node);
    // 自闭合标签必须包含 SVG 内的空元素 (path/circle/rect/...): 否则解析器会把后续
    // 兄弟节点错误嵌套进它们内部, 造成 DOM 树错位与节点被重复访问 (C032 实测:
    // 设置页导航图标的 <path/> 之后整棵子树被吞进 path 里, 误报重复 id)。
    if (!/^(input|link|meta|br|hr|img|path|circle|rect|line|polyline|polygon|ellipse|stop|use)$/i.test(tag)) stack.push(node);
  }
  root.body = root.querySelector("body");
  root.createElement = tag => new Element(tag);
  root.createElementNS = (_namespace, tag) => new Element(tag);
  root.createTextNode = text => Object.assign(new Element("#text"), { textContent: text });
  root.getElementById = id => root.querySelector(`#${id}`);
  return root;
}

export const fixture = JSON.parse(readFileSync(resolve("tests/fixtures/viewmodel-parity/agent-usage-valid.panel.json"), "utf8"));
// 工作台分析 (C070): 直接取 mac 产出、Rust 对拍锁定的 golden, 按范围索引 —— 前端测试渲染的
// 就是两端后端真实下发的结构。
export const analytics = Object.fromEntries(
  JSON.parse(readFileSync(resolve("tests/fixtures/viewmodel-parity/agent-usage-workbench.analytics.json"), "utf8"))
    .map(snapshot => [snapshot.range, snapshot]),
);
export const defaults = {
  refreshIntervalSecs: 1800, notificationsEnabled: true, theme: "fluent",
  cardOrder: ["usage", "subscription", "hourly"], hotkey: "", consentVersion: 0,
  usageEnabled: true, enabledProviders: ["kimi", "codex", "claude", "deepseek"], providerOrder: [], pricingOverrides: {},
  layoutMode: "stack", activeCardId: "usage",
};
export async function settle() { await new Promise(resolve => setImmediate(resolve)); }
export async function boot({ html = "index.html", panel = fixture, settings = defaults, reject = {}, accounts = [], rejections = [], dialogPath = "C:\\\\Users\\\\demo\\\\导出.csv", workbench = analytics, claudeLocal = { status: "followed", storedAccountCount: 0 }, verify = { status: "ok", reason: null }, grokLocal = { status: "followed", storedAccountCount: 0 }, codexSources = { cliAuth: true, ccSwitch: true }, codexStart = { deviceAuthId: "dev-1", userCode: "ABCD-1234", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 0, expiresInSeconds: 900, browserOpened: true }, codexPoll = [{ status: "pending" }, { status: "authorized", accountId: "acct-1", email: "a@b.c" }], codexImport = { added: 1 }, stepfunOpen = { site: "domestic", url: "https://platform.stepfun.com/step-plan", intervalMs: 2000 }, stepfunPoll = [{ status: "waiting", currentUrl: "https://platform.stepfun.com/step-plan", message: "等待 🇨🇳 国内站 登录完成中..." }, { status: "captured", site: "domestic", currentUrl: "https://platform.stepfun.com/step-plan", accountId: "stepfun-web1", message: "🎉 检测到 🇨🇳 国内站 登录完成，已提取 Oasis-Token" }], stepfunClear = { url: "https://platform.stepfun.com/step-plan", message: "已清空 🇨🇳 国内站 登录缓存，正在刷新..." } } = {}) {
  const htmlSource = readFileSync(resolve("apps/win/src", html), "utf8");
  const document = parseHTML(htmlSource);
  const calls = [], errors = [], events = new Map();
  const window = new Element("window");
  // 凭据账号随移除命令收敛 (C089): 移除服务后重新添加须得到空账号列表。
  const state = { panel: structuredClone(panel), settings: structuredClone(settings), accounts: structuredClone(accounts) };
  const invoke = async (command, args) => {
    calls.push({ command, args });
    if (reject[command]) throw new Error(reject[command]);
    if (command === "get_dashboard") return structuredClone(state.panel);
    if (command === "get_settings") return structuredClone(state.settings);
    if (command === "save_settings_command") {
      // 镜像后端契约 (C090): enabled_providers 是 subscriptionProviders[id].enabled 的派生投影,
      // 保存时由后端归一, 并把归一结果回传前端作本地缓存。
      const next = structuredClone(args.settings);
      if (next.subscriptionProviders) {
        next.enabledProviders = Object.keys(next.subscriptionProviders)
          .filter((id) => next.subscriptionProviders[id]?.enabled);
      }
      state.settings = next;
      return structuredClone(next);
    }
    if (command === "credential_allowlist") return ["kimiQuotaAccounts", "codexQuotaAccounts", "volcengineQuotaAccounts", "providerMeta"];
    if (command === "get_credential_fields") return state.accounts.length ? ["kimiQuotaAccounts"] : [];
    if (command === "get_credential_accounts") return structuredClone(state.accounts);
    // C092: 被丢弃账号的原因清单 (测试可按需注入 rejections fixture)。
    if (command === "get_credential_rejections") return structuredClone(rejections);
    if (command === "remove_provider_credentials") {
      state.accounts = state.accounts.filter(account => account.field !== `${args.provider}QuotaAccounts`);
      return null;
    }
    if (command === "plugin:dialog|save") return dialogPath;
    if (command === "get_usage_analytics") return structuredClone(workbench[args.range] ?? null);
    if (command === "get_model_prices") return [{ model: "fixture-model", displayName: "Fixture Model", vendor: "Fixture Vendor", inputPricePerMillion: 1, outputPricePerMillion: 2, cacheReadPricePerMillion: null, currency: "USD", note: "fixture 备注" }];
    if (command === "claude_local_status") return structuredClone(claudeLocal);
    if (command === "import_claude_from_local") return { status: claudeLocal.status };
    // C085: Grok 本机只读跟随。
    if (command === "grok_local_status") return structuredClone(grokLocal);
    if (command === "import_grok_from_local") return { status: grokLocal.status };
    if (command === "verify_subscription") return structuredClone(typeof verify === "function" ? verify(args) : verify);
    if (command === "ccswitch_status") return { available: true };
    if (command === "import_volcengine_from_ccswitch") return { status: "ok", reason: null };
    // C084: Codex 设备码登录与只读账号发现。
    if (command === "codex_discovery_sources") return structuredClone(codexSources);
    if (command === "codex_device_start") return structuredClone(codexStart);
    if (command === "open_verification_page") return null;
    if (command === "codex_device_poll") {
      const next = codexPoll.shift() ?? { status: "pending" };
      if (next.status === "authorized") {
        state.accounts = [...state.accounts, { field: "codexQuotaAccounts", accountId: next.accountId, displayName: next.accountId, authorizationState: "connected", usable: true }];
      }
      return structuredClone(next);
    }
    if (command === "codex_import_discovered") {
      state.accounts = [...state.accounts, { field: "codexQuotaAccounts", accountId: "discovered-1", displayName: "discovered-1", authorizationState: "reauthRequired", usable: false }];
      return structuredClone(codexImport);
    }
    // C086: StepFun 内嵌网页登录与自动抓 Cookie。
    if (command === "stepfun_web_login_open") {
      const site = args?.site === "global" ? "global" : "domestic";
      const url = site === "global" ? "https://platform.stepfun.ai/plan-subscribe" : "https://platform.stepfun.com/step-plan";
      return structuredClone({ ...stepfunOpen, site, url });
    }
    if (command === "stepfun_web_login_action") {
      const url = args?.action === "home" ? "https://platform.stepfun.com" : "https://platform.stepfun.com/step-plan";
      return { url };
    }
    if (command === "stepfun_web_login_poll") {
      const next = stepfunPoll.shift() ?? { status: "waiting", currentUrl: "https://platform.stepfun.com/step-plan", message: "等待 🇨🇳 国内站 登录完成中..." };
      if (next.status === "captured") {
        const id = next.accountId || "stepfun-web1";
        state.accounts = [
          ...state.accounts.filter(a => !(a.field === "stepfunQuotaAccounts" && a.accountId === id)),
          { field: "stepfunQuotaAccounts", accountId: id, displayName: `StepFun · ${id.split("-").pop()}`, authorizationState: "ok", usable: true },
        ];
      }
      return structuredClone(next);
    }
    if (command === "stepfun_web_login_clear_session") return structuredClone(stepfunClear);
    if (command === "stepfun_web_login_close") return null;
    if (command === "get_runtime_info") return { version: "0.11.5", dataRoot: "isolated-data", cacheRoot: "isolated-cache", snapshotPath: "isolated-snapshot", status: { phase: "stale", lastSuccessAt: "2026-10-08T08:00:00Z", error: "COLLECTION_PARTIAL", diagnosticCodes: ["PROVIDER_RATE_LIMIT"] } };
    return null;
  };
  window.__TAURI__ = { core: { invoke }, event: { listen: async (name, callback) => {
    events.set(name, [...(events.get(name) || []), callback]);
    return () => events.set(name, events.get(name).filter(value => value !== callback));
  } } };
  window.dispatchEvent = event => window.dispatch(event.type, event);
  const context = vm.createContext({ document, window, console: { error: (...args) => errors.push(args.join(" ")), log() {} },
    CustomEvent: class { constructor(type, values) { this.type = type; Object.assign(this, values); } },
    setTimeout, clearTimeout, URL, crypto: { randomUUID: () => "test-account" }, structuredClone });
  for (const [, file] of htmlSource.matchAll(/<script src="([^"]+)"/g)) {
    vm.runInContext(readFileSync(resolve("apps/win/src", file), "utf8"), context, { filename: file });
  }
  // 内联脚本 (如 preview.html, C115) 同样按生产源码执行。
  for (const [, inline] of htmlSource.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
    vm.runInContext(inline, context, { filename: `${html}#inline` });
  }
  await settle(); await settle();
  return { document, window, calls, errors, state, context, events, node: id => document.getElementById(id),
    emit: async (name, payload) => { await Promise.all((events.get(name) || []).map(callback => callback({ payload }))); await settle(); } };
}
