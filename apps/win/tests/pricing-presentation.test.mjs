import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import PP from "../src/pricing-presentation.js";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const fixture = JSON.parse(
  readFileSync(join(repoRoot, "tests/fixtures/pricing-sync-parity/cases.json"), "utf8")
);

test("rows copy matches parity fixture", () => {
  assert.equal(PP.copy.caption, fixture.rows.caption);
  assert.equal(PP.copy.autoSyncTitle, fixture.rows.autoSyncTitle);
  assert.equal(PP.copy.autoSyncSubtitle, fixture.rows.autoSyncSubtitle);
  assert.equal(PP.copy.currentCatalogTitle, fixture.rows.currentCatalogTitle);
  assert.equal(PP.copy.syncCatalogTitle, fixture.rows.syncCatalogTitle);
  assert.equal(PP.copy.syncButton, fixture.rows.syncButton);
  assert.equal(PP.copy.restoreButton, fixture.rows.restoreButton);
});

test("currentCatalog subtitle matches parity fixture", () => {
  for (const item of fixture.currentCatalog) {
    const actual = PP.currentCatalogSubtitle(item.source, item.modelCount);
    assert.equal(actual, item.expectedSubtitle, `Mismatch for ${item.name}`);
  }
});

test("lastSync subtitle matches parity fixture", () => {
  const now = "2026-10-31T14:30:00+08:00";
  for (const item of fixture.lastSync) {
    const actual = PP.lastSyncSubtitle(item.at, now);
    assert.equal(actual, item.expected, `Mismatch for ${item.name}`);
  }
});

test("stages display and button states match parity fixture", () => {
  for (const item of fixture.stages) {
    const display = PP.stageDisplay(item.phase);
    assert.equal(display.kind, item.expected.kind, `kind mismatch for ${item.name}`);
    if (item.expected.kind === "hidden") {
      assert.equal(display.text, null);
    } else if (item.expected.kind === "spinner" || item.expected.kind === "confirmation") {
      assert.equal(display.text, item.expected.text, `text mismatch for ${item.name}`);
    } else if (item.expected.kind === "failure") {
      assert.equal(display.title, item.expected.title, `title mismatch for ${item.name}`);
      assert.equal(display.detail, item.expected.detail, `detail mismatch for ${item.name}`);
      assert.equal(display.statusLine, item.expected.statusLine, `statusLine mismatch for ${item.name}`);
    }

    assert.equal(
      PP.isSyncButtonEnabled(item.phase),
      item.syncEnabled,
      `syncEnabled mismatch for ${item.name}`
    );
    assert.equal(
      PP.isRestoreButtonEnabled(item.phase),
      item.restoreEnabled,
      `restoreEnabled mismatch for ${item.name}`
    );
  }
});
