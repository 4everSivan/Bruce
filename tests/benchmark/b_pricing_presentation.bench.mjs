// @managed-by: test-anything
// @module: pricing_presentation
// @type: benchmark
// @cases_doc: tests/docs/cases/b_pricing_presentation_cases.md
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
const NOW = "2026-10-31T14:30:00+08:00";

export const meta = {
  module: "pricing_presentation",
  cases: ["BM-pricing_presentation-001", "BM-pricing_presentation-002"],
};

// @case: BM-pricing_presentation-001
// @feature: FP-pricing_presentation-04
// @scenario: hotspot
export function bench_bm_pricing_presentation_001_stage_display() {
  const stages = fixture.stages;
  const rounds = 2000;
  for (let r = 0; r < 5; r += 1) for (const item of stages) PP.stageDisplay(item.phase);
  const start = performance.now();
  for (let r = 0; r < rounds; r += 1) {
    for (const item of stages) PP.stageDisplay(item.phase);
  }
  const totalMs = performance.now() - start;
  const iterations = rounds * stages.length;
  return {
    id: "BM-pricing_presentation-001",
    module: "pricing_presentation",
    workload: `${stages.length} stages x ${rounds} rounds`,
    iterations,
    total_ms: Number(totalMs.toFixed(3)),
    avg_us: Number(((totalMs * 1000) / iterations).toFixed(3)),
    avg_ns: Number(((totalMs * 1_000_000) / iterations).toFixed(1)),
    ops_per_sec: Number(((iterations * 1000) / totalMs).toFixed(1)),
  };
}

// @case: BM-pricing_presentation-002
// @feature: FP-pricing_presentation-03
// @scenario: hotspot
export function bench_bm_pricing_presentation_002_timestamp() {
  const inputs = [
    "2026-10-31T14:02:00+08:00",
    "2026-10-30T09:15:00+08:00",
    null,
  ];
  const iterations = 10000;
  for (let i = 0; i < 200; i += 1) PP.timestamp(inputs[i % inputs.length], NOW);
  const start = performance.now();
  for (let i = 0; i < iterations; i += 1) PP.timestamp(inputs[i % inputs.length], NOW);
  const totalMs = performance.now() - start;
  return {
    id: "BM-pricing_presentation-002",
    module: "pricing_presentation",
    workload: "3 input shapes",
    iterations,
    total_ms: Number(totalMs.toFixed(3)),
    avg_us: Number(((totalMs * 1000) / iterations).toFixed(3)),
    avg_ns: Number(((totalMs * 1_000_000) / iterations).toFixed(1)),
    ops_per_sec: Number(((iterations * 1000) / totalMs).toFixed(1)),
  };
}

export function run() {
  return [bench_bm_pricing_presentation_001_stage_display(), bench_bm_pricing_presentation_002_timestamp()];
}
