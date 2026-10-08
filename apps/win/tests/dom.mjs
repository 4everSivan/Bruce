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
    this.style = {};
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
    const visit = node => {
      for (const child of node.children) {
        if (child.matches(parts.at(-1))) {
          let parent = child.parentElement, index = parts.length - 2;
          while (parent && index >= 0) {
            if (parent.matches(parts[index])) index -= 1;
            parent = parent.parentElement;
          }
          if (index < 0) all.push(child);
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
    if (!/^(input|link|meta|br|hr|img)$/i.test(tag)) stack.push(node);
  }
  root.body = root.querySelector("body");
  root.createElement = tag => new Element(tag);
  root.createElementNS = (_namespace, tag) => new Element(tag);
  root.createTextNode = text => Object.assign(new Element("#text"), { textContent: text });
  root.getElementById = id => root.querySelector(`#${id}`);
  return root;
}

export const fixture = JSON.parse(readFileSync(resolve("tests/fixtures/viewmodel-parity/agent-usage-valid.panel.json"), "utf8"));
export const defaults = {
  refreshIntervalSecs: 1800, notificationsEnabled: true, theme: "fluent",
  cardOrder: ["usage", "subscription", "hourly"], hotkey: "", consentVersion: 0,
  usageEnabled: true, enabledProviders: ["kimi", "codex", "claude", "deepseek"], providerOrder: [], pricingOverrides: {},
};
export async function settle() { await new Promise(resolve => setImmediate(resolve)); }
export async function boot({ html = "index.html", panel = fixture, settings = defaults, reject = {}, accounts = [] } = {}) {
  const htmlSource = readFileSync(resolve("apps/win/src", html), "utf8");
  const document = parseHTML(htmlSource);
  const calls = [], errors = [], events = new Map();
  const window = new Element("window");
  const state = { panel: structuredClone(panel), settings: structuredClone(settings) };
  const invoke = async (command, args) => {
    calls.push({ command, args });
    if (reject[command]) throw new Error(reject[command]);
    if (command === "get_dashboard") return structuredClone(state.panel);
    if (command === "get_settings") return structuredClone(state.settings);
    if (command === "save_settings_command") { state.settings = structuredClone(args.settings); return; }
    if (command === "credential_allowlist") return ["kimiQuotaAccounts", "codexQuotaAccounts", "volcengineQuotaAccounts", "providerMeta"];
    if (command === "get_credential_fields") return accounts.length ? ["kimiQuotaAccounts"] : [];
    if (command === "get_credential_accounts") return accounts;
    if (command === "get_model_prices") return { "fixture-model": { inputPricePerMillion: 1, outputPricePerMillion: 2, currency: "USD" } };
    if (command === "get_runtime_info") return { dataRoot: "isolated-data", cacheRoot: "isolated-cache", snapshotPath: "isolated-snapshot", status: { phase: "stale", lastSuccessAt: "2026-10-08T08:00:00Z", error: "COLLECTION_PARTIAL", diagnosticCodes: ["PROVIDER_RATE_LIMIT"] } };
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
  await settle(); await settle();
  return { document, calls, errors, state, context, events, node: id => document.getElementById(id),
    emit: async (name, payload) => { await Promise.all((events.get(name) || []).map(callback => callback({ payload }))); await settle(); } };
}
