// @managed-by: test-anything
// @module: provider_brand
// @type: benchmark
// @cases_doc: tests/docs/cases/b_provider_brand_cases.md
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const context = { window: {} };
vm.createContext(context);
vm.runInContext(
  readFileSync(join(repoRoot, "apps/win/src/provider-brand.js"), "utf8"),
  context
);
const glyphs = context.window.BRUCE_PROVIDER_GLYPHS;
const brand = JSON.parse(
  readFileSync(join(repoRoot, "tests/fixtures/agent-brand-parity/cases.json"), "utf8")
);
const keys = [
  ...brand.agents.map((agent) => agent.glyph),
  ...brand.models.map((model) => model.glyph),
].filter(Boolean);

export const meta = {
  module: "provider_brand",
  cases: ["BM-provider_brand-001"],
};

// @case: BM-provider_brand-001
// @feature: FP-provider_brand-01
// @scenario: hotspot
export function bench_bm_provider_brand_001_lookup() {
  const rounds = 20000;
  for (let r = 0; r < 1000; r += 1) for (const key of keys) glyphs[key];
  const start = performance.now();
  for (let r = 0; r < rounds; r += 1) {
    for (const key of keys) glyphs[key];
  }
  const totalMs = performance.now() - start;
  const iterations = rounds * keys.length;
  return {
    id: "BM-provider_brand-001",
    module: "provider_brand",
    workload: `${keys.length} glyph keys x ${rounds} rounds`,
    iterations,
    total_ms: Number(totalMs.toFixed(3)),
    avg_us: Number(((totalMs * 1000) / iterations).toFixed(3)),
    avg_ns: Number(((totalMs * 1_000_000) / iterations).toFixed(1)),
    ops_per_sec: Number(((iterations * 1000) / totalMs).toFixed(1)),
  };
}

export function run() {
  return [bench_bm_provider_brand_001_lookup()];
}
