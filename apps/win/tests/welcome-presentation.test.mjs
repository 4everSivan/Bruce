import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import WP from "../src/welcome-presentation.js";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const fixture = JSON.parse(
  readFileSync(join(repoRoot, "tests/fixtures/welcome-onboarding-parity/cases.json"), "utf8")
);

test("welcome copy matches shared parity fixture (T22)", () => {
  for (const [key, expected] of Object.entries(fixture.copy)) {
    assert.equal(WP.copy[key], expected, `copy.${key} mismatch`);
  }
});

test("welcome 3-step metadata matches shared parity fixture (T22)", () => {
  assert.equal(WP.steps.length, 3);
  assert.equal(WP.steps[0].railTitle, fixture.copy.step1NavTitle);
  assert.equal(WP.steps[1].railTitle, fixture.copy.step2NavTitle);
  assert.equal(WP.steps[2].railTitle, fixture.copy.step3NavTitle);
});

test("shouldPresentWelcome matches shared parity fixture (T22)", () => {
  for (const item of fixture.shouldPresentWelcomeCases) {
    const actual = WP.shouldPresentWelcome(
      item.welcomeCompletedVersion,
      item.consentConfirmed,
      item.keychainAccessConfigured
    );
    assert.equal(actual, item.expected, `shouldPresentWelcome mismatch for ${item.name}`);
  }
});

test("readySourcesSummary and menuBarPreviewMetricsText match shared parity fixture (T22)", () => {
  for (const item of fixture.readySourcesSummaryCases) {
    assert.equal(
      WP.readySourcesSummary(item.readyCount),
      item.expected
    );
  }
  for (const item of fixture.menuBarPreviewMetricsCases) {
    assert.equal(
      WP.menuBarPreviewMetricsText(item.isNothingTheme, item.iconOnly),
      item.expected
    );
  }
});
