import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync(new URL("../apps/widget/index.html", import.meta.url), "utf8");
const scriptElement = html.match(/<script>\s*\/\* Kimi Pixel Field renderer[\s\S]*?<\/script>/)?.[0];
assert.ok(scriptElement, "the pixel-field renderer script must be present");
const script = scriptElement
  .replace(/^<script>\s*/, "")
  .replace(/\s*<\/script>$/, "");

const pendingFrames = new Map();
const pendingTimers = new Map();
let nextId = 1;
let frameRequestCount = 0;
let lastTimeout = null;

const scheduler = {
  requestAnimationFrame(callback) {
    const id = nextId++;
    frameRequestCount += 1;
    pendingFrames.set(id, callback);
    return id;
  },
  cancelAnimationFrame(id) {
    pendingFrames.delete(id);
  },
  setTimeout(callback, delay) {
    const id = nextId++;
    lastTimeout = delay;
    pendingTimers.set(id, { callback, delay });
    return id;
  },
  clearTimeout(id) {
    pendingTimers.delete(id);
  },
  pendingAnimationCount() {
    return pendingFrames.size;
  },
  pendingCount() {
    return pendingFrames.size + pendingTimers.size;
  },
  frameRequests() {
    return frameRequestCount;
  },
  lastTimeoutDelay() {
    return lastTimeout;
  },
};

class FakeCanvas {
  constructor() {
    this.style = {};
    this.width = 0;
    this.height = 0;
    this.context = {
      globalAlpha: 1,
      fillStyle: "",
      font: "",
      setTransform() {},
      clearRect() {},
      fillText() {},
    };
  }

  getContext(kind) {
    return kind === "2d" ? this.context : null;
  }

  setAttribute() {}

  remove() {}
}

const listeners = new Map();
const documentObject = {
  visibilityState: "hidden",
  createElement(kind) {
    assert.equal(kind, "canvas");
    return new FakeCanvas();
  },
  addEventListener(type, listener) {
    listeners.set(`document:${type}`, listener);
  },
  removeEventListener(type, listener) {
    if (listeners.get(`document:${type}`) === listener) listeners.delete(`document:${type}`);
  },
};
const container = {
  ownerDocument: documentObject,
  appendChild() {},
  getBoundingClientRect() {
    return { width: 240, height: 120, left: 0, top: 0 };
  },
  addEventListener(type, listener) {
    listeners.set(type, listener);
  },
  removeEventListener(type, listener) {
    if (listeners.get(type) === listener) listeners.delete(type);
  },
};

const context = {
  console,
  devicePixelRatio: 2,
  performance: { now: () => 0 },
  matchMedia: () => ({ matches: false }),
  document: documentObject,
  getComputedStyle: () => ({ color: "#ffffff" }),
  ResizeObserver: class {
    observe() {}
    disconnect() {}
  },
  requestAnimationFrame: scheduler.requestAnimationFrame,
  cancelAnimationFrame: scheduler.cancelAnimationFrame,
  setTimeout: scheduler.setTimeout,
  clearTimeout: scheduler.clearTimeout,
};
context.window = context;
vm.runInNewContext(script, context, { filename: "widget-pixel-field.js" });

const field = context.KimiPixelField.mount(container, { driftSpeed: 16 });
assert.equal(scheduler.pendingAnimationCount(), 0, "mount must stay static while invisible");

field.setVisible(true);
assert.equal(scheduler.lastTimeoutDelay(), 125, "visible animation is capped at 8 fps");

field.setVisible(false);
assert.equal(scheduler.pendingCount(), 0, "hiding cancels all animation work");

field.setInteractive(true);
assert.equal(scheduler.frameRequests(), 1, "interaction may request one immediate frame");

field.destroy();
assert.equal(scheduler.pendingCount(), 0, "destroy releases every scheduled callback");

console.log("Widget performance tests passed: 5");
