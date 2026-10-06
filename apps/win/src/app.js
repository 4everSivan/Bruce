// Bruce Windows 看板骨架: 经 Tauri IPC 消费视图模型 JSON (契约见
// apps/win/viewmodel/src/models.rs, 字段 camelCase)。
const { invoke } = window.__TAURI__.core;

function text(node, value) {
  node.textContent = value;
}

function render(panel) {
  const usage = panel.usage;
  const hero = document.getElementById("hero");
  const live = document.getElementById("live");

  if (!usage) {
    hero.classList.add("hidden");
    renderDiagnostics(panel.diagnostics);
    return;
  }

  hero.classList.remove("hidden");
  live.classList.toggle("hidden", !usage.isLive);
  text(document.getElementById("hero-total"), usage.totalTokensText);
  text(document.getElementById("hero-cost"), usage.costText ?? "");

  const breakdown = document.getElementById("breakdown");
  breakdown.innerHTML = "";
  for (const item of usage.breakdown) {
    const cell = document.createElement("div");
    cell.className = "cell";
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = item.label;
    const value = document.createElement("span");
    value.textContent = item.valueText;
    cell.append(label, value);
    breakdown.append(cell);
  }

  renderHourly(panel.hourly);
  renderDiagnostics(panel.diagnostics);
}

function renderHourly(hourly) {
  const host = document.getElementById("hourly");
  const rows = document.getElementById("hourly-rows");
  rows.innerHTML = "";
  if (!hourly || !hourly.rows.length) {
    host.classList.add("hidden");
    return;
  }
  host.classList.remove("hidden");
  for (const row of hourly.rows) {
    const item = document.createElement("div");
    item.className = "hourly-row";

    const line = document.createElement("div");
    line.className = "name-line";
    const name = document.createElement("span");
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.style.background = row.colorHex;
    name.append(dot, document.createTextNode(row.name));
    const total = document.createElement("span");
    total.textContent = row.todayTotalText;
    line.append(name, total);
    item.append(line);

    for (const bar of [...row.models, ...row.projects].slice(0, 3)) {
      const track = document.createElement("div");
      track.className = "bar";
      const fill = document.createElement("div");
      fill.style.width = `${Math.round(bar.share * 100)}%`;
      fill.style.background = "var(--accent)";
      track.append(fill);
      item.append(track);
    }
    rows.append(item);
  }
}

function renderDiagnostics(diagnostics) {
  const card = document.getElementById("diagnostics");
  const list = document.getElementById("diagnostic-list");
  list.innerHTML = "";
  if (!diagnostics.length) {
    card.classList.add("hidden");
    return;
  }
  card.classList.remove("hidden");
  for (const diagnostic of diagnostics) {
    const li = document.createElement("li");
    li.textContent =
      diagnostic.kind === "agentIssue"
        ? `${diagnostic.agentId}: ${diagnostic.status} ${diagnostic.note}`
        : diagnostic.kind;
    list.append(li);
  }
}

async function refresh() {
  const button = document.getElementById("refresh");
  button.disabled = true;
  button.textContent = "采集中…";
  try {
    render(await invoke("get_dashboard"));
  } catch (error) {
    console.error("get_dashboard 失败", error);
  } finally {
    button.disabled = false;
    button.textContent = "刷新";
  }
}

document.getElementById("refresh").addEventListener("click", refresh);
refresh();
