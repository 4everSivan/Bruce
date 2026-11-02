// @managed-by: test-anything
// @module: pricing_presentation
// @type: unit_test
// @cases_doc: tests/docs/cases/u_pricing_presentation_cases.md
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const PP = require(join(repoRoot, "apps/win/src/pricing-presentation.js"));
const fixture = JSON.parse(
  readFileSync(join(here, "..", "fixtures", "pricing-sync-parity", "cases.json"), "utf8")
);
const local = JSON.parse(
  readFileSync(join(here, "..", "fixtures", "pricing_presentation_fixtures.json"), "utf8")
);

// @case: UT-pricing_presentation-001
// @feature: FP-pricing_presentation-01
// @scenario: normal
test("UT-pricing_presentation-001: 静态文案与双端对拍一致", () => {
  // Arrange
  const rows = fixture.rows;
  // Act
  const copy = PP.copy;
  // Assert
  for (const key of ["caption", "autoSyncTitle", "autoSyncSubtitle", "currentCatalogTitle", "syncCatalogTitle", "syncButton", "restoreButton"]) {
    assert.equal(copy[key], rows[key], `copy.${key} 与 fixture 不一致`);
  }
});

// @case: UT-pricing_presentation-002
// @feature: FP-pricing_presentation-02
// @scenario: boundary
test("UT-pricing_presentation-002: 当前目录副标题", () => {
  // Arrange
  const items = fixture.currentCatalog;
  // Act + Assert
  for (const item of items) {
    assert.equal(
      PP.currentCatalogSubtitle(item.source, item.modelCount),
      item.expectedSubtitle,
      `副标题不匹配: ${item.name}`
    );
  }
  assert.equal(PP.currentCatalogSubtitle("builtin", 0), "内置基线 · 0 款模型");
  assert.equal(PP.currentCatalogSubtitle("github", "abc"), "GitHub 已同步 · 0 款模型");
});

// @case: UT-pricing_presentation-003
// @feature: FP-pricing_presentation-03
// @scenario: normal
test("UT-pricing_presentation-003: 同步时间格式化", () => {
  // Arrange
  const now = local.now;
  // Act + Assert
  for (const item of fixture.lastSync) {
    assert.equal(PP.lastSyncSubtitle(item.at, now), item.expected, `时间格式不匹配: ${item.name}`);
  }
  assert.equal(PP.timestamp("2026-10-31T14:02:00+08:00", now), "今天 14:02");
  assert.equal(PP.timestamp("2026-10-30T09:15:00+08:00", now), "10月30日 09:15");
  assert.equal(PP.lastSyncSubtitle(null, now), local.empty_catalog_subtitle);
  assert.equal(PP.timestamp("not-a-date", now), "");
});

// @case: UT-pricing_presentation-004
// @feature: FP-pricing_presentation-04
// @scenario: normal
test("UT-pricing_presentation-004: 同步状态机矩阵", () => {
  // Arrange
  const stages = fixture.stages;
  // Act + Assert
  for (const item of stages) {
    const display = PP.stageDisplay(item.phase);
    assert.equal(display.kind, item.expected.kind, `kind 不匹配: ${item.name}`);
    if (item.expected.kind === "hidden") {
      assert.equal(display.text, null, `text 应为 null: ${item.name}`);
    } else if (item.expected.kind === "spinner" || item.expected.kind === "confirmation") {
      assert.equal(display.text, item.expected.text, `text 不匹配: ${item.name}`);
    } else if (item.expected.kind === "failure") {
      assert.equal(display.title, item.expected.title, `title 不匹配: ${item.name}`);
      assert.equal(display.detail, item.expected.detail, `detail 不匹配: ${item.name}`);
      assert.equal(display.statusLine, item.expected.statusLine, `statusLine 不匹配: ${item.name}`);
    }
  }
  assert.deepEqual(PP.stageDisplay({ kind: "unknown" }), { kind: "hidden", text: null });
});

// @case: UT-pricing_presentation-005
// @feature: FP-pricing_presentation-05
// @scenario: boundary
test("UT-pricing_presentation-005: 按钮可用性", () => {
  // Arrange
  const syncing = { kind: "syncing" };
  const idle = { kind: "idle" };
  // Act + Assert
  assert.equal(PP.isSyncButtonEnabled(syncing), false);
  assert.equal(PP.isRestoreButtonEnabled(syncing), false);
  assert.equal(PP.isSyncButtonEnabled(idle), true);
  assert.equal(PP.isRestoreButtonEnabled(idle), true);
  assert.equal(PP.isSyncButtonEnabled(null), true);
  assert.equal(PP.isRestoreButtonEnabled(null), true);
  for (const item of fixture.stages) {
    assert.equal(PP.isSyncButtonEnabled(item.phase), item.syncEnabled, `syncEnabled: ${item.name}`);
    assert.equal(PP.isRestoreButtonEnabled(item.phase), item.restoreEnabled, `restoreEnabled: ${item.name}`);
  }
});
