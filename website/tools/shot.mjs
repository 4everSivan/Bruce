/* Screenshot helper over CDP (Node ≥ 22 has fetch + WebSocket). */
import { writeFile } from "node:fs/promises";

const [, , url, out, w = "1440", h = "1000", mode = "viewport", arg = "0"] = process.argv;
const BASE = "http://127.0.0.1:9222";

async function newTab() {
  const res = await fetch(`${BASE}/json/new?about:blank`, { method: "PUT" });
  if (!res.ok) throw new Error("cannot open tab: " + res.status);
  return res.json();
}

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.logs = [];
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
      } else if (msg.method === "Runtime.consoleAPICalled") {
        this.logs.push(
          msg.params.type + ": " + msg.params.args.map((a) => a.value ?? a.description).join(" ")
        );
      } else if (msg.method === "Runtime.exceptionThrown") {
        this.logs.push("EXCEPTION: " + (msg.params.exceptionDetails.exception?.description || msg.params.exceptionDetails.text));
      } else if (msg.method === "Log.entryAdded") {
        this.logs.push("log/" + msg.params.entry.level + ": " + msg.params.entry.text);
      }
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }
}

const tab = await newTab();
const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
const cdp = new CDP(ws);

await cdp.send("Page.enable");
await cdp.send("Runtime.enable");
await cdp.send("Log.enable");
await cdp.send("Emulation.setDeviceMetricsOverride", {
  width: Number(w),
  height: Number(h),
  deviceScaleFactor: 2,
  mobile: false,
});

await cdp.send("Page.navigate", { url });
await new Promise((r) => setTimeout(r, 1800));

if (mode === "scroll") {
  await cdp.send("Runtime.evaluate", {
    expression: `(function(){
      const el = document.querySelector(${JSON.stringify(arg)});
      if (!el) return 'missing';
      window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - 10, behavior: 'instant' });
      return String(window.scrollY);
    })()`,
  });
  await new Promise((r) => setTimeout(r, 900));
} else if (mode === "y") {
  await cdp.send("Runtime.evaluate", { expression: `window.scrollTo({top:${Number(arg)}, behavior:'instant'})` });
  await new Promise((r) => setTimeout(r, 900));
} else if (mode === "js") {
  await cdp.send("Runtime.evaluate", { expression: "(function(){" + arg + "})()" });
  await new Promise((r) => setTimeout(r, 1000));
} else if (mode === "full") {
  const { cssContentSize } = await cdp.send("Page.getLayoutMetrics");
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: Number(w),
    height: Math.ceil(cssContentSize.height),
    deviceScaleFactor: 2,
    mobile: false,
  });
  await new Promise((r) => setTimeout(r, 700));
}

const { data } = await cdp.send("Page.captureScreenshot", { format: "png" });
await writeFile(out, Buffer.from(data, "base64"));
if (cdp.logs.length) console.log(cdp.logs.join("\n"));
console.log("saved " + out);
ws.close();
await fetch(`${BASE}/json/close/${tab.id}`);
process.exit(0);
