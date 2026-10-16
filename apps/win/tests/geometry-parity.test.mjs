#!/usr/bin/env node
// 几何对拍: win 任务栏交互 Demo 内联的几何镜像
// (`apps/win/demo/win-taskbar-interaction-demo.html` 的 `// @geometry-parity:begin/end` 区段)
// 必须与 Rust `runtime_core::compute_dashboard_geometry` 逐字段一致。
//
// 背景 (C035): 维护者无 Windows 机器, Demo 是人眼核验「任务栏四方向自适应」的唯一载体。
// 若 Demo 的几何实现与 Rust 漂移, 核验结论即失效 —— 该风险只能靠对拍消除。
// 同一份 fixture 由双侧读取:
//   - Node: 本测试 (读取 Demo 内联镜像)
//   - Rust: apps/win/src-tauri/tests/runtime_coverage.rs::dashboard_geometry_parity_fixture_is_current
// 几何改动后必须重新生成 fixture, 见 apps/win/src-tauri/examples/dump_geometry.rs。

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const demoPath = join(repoRoot, "apps/win/demo/win-taskbar-interaction-demo.html");
const fixturePath = join(repoRoot, "tests/fixtures/geometry-parity/cases.json");

function loadMirror() {
  const html = readFileSync(demoPath, "utf8");
  const region = html.match(/\/\/ @geometry-parity:begin([\s\S]*?)\/\/ @geometry-parity:end/);
  assert.ok(region, "demo 必须保留 @geometry-parity 标注区段");
  const factory = new Function(`${region[1]}\nreturn { computeGeometry, detectTaskbarEdge };`);
  return factory();
}

const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
const mirror = loadMirror();

test("demo 几何镜像与 Rust fixture 逐字段一致", () => {
  assert.ok(fixture.cases.length >= 40, "fixture 覆盖不足");
  for (const item of fixture.cases) {
    const geom = mirror.computeGeometry(item.monitor, item.tray);
    assert.equal(mirror.detectTaskbarEdge(item.monitor, item.tray), item.edge, `${item.name}: 任务栏边`);
    assert.equal(geom.edge, item.edge, `${item.name}: 任务栏边`);
    assert.equal(geom.x, item.geometry.x, `${item.name}: x`);
    assert.equal(geom.y, item.geometry.y, `${item.name}: y`);
    assert.equal(geom.width, item.geometry.width, `${item.name}: width`);
    assert.equal(geom.height, item.geometry.height, `${item.name}: height`);
  }
});

test("fixture 覆盖任务栏四方向与有无托盘坐标", () => {
  const edges = [...new Set(fixture.cases.map((item) => item.edge))].sort();
  assert.deepEqual(edges, ["bottom", "left", "right", "top"]);
  assert.ok(fixture.cases.some((item) => item.tray === null), "必须覆盖无托盘坐标 (热键唤出)");
  assert.ok(fixture.cases.some((item) => item.tray !== null), "必须覆盖有托盘坐标 (托盘点击)");
});
