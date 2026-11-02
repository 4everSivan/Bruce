// @managed-by: test-anything
// @module: pricing_catalog
// @type: benchmark
// @cases_doc: tests/docs/cases/b_pricing_catalog_cases.md
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const catalogText = readFileSync(join(repoRoot, "config/pricing-catalog.json"), "utf8");

export const meta = {
  module: "pricing_catalog",
  cases: ["BM-pricing_catalog-001"],
};

function validate(text) {
  const catalog = JSON.parse(text);
  if (catalog.schemaVersion !== 1) throw new Error("schemaVersion");
  if (!Array.isArray(catalog.models) || catalog.models.length === 0) throw new Error("models");
  let models = 0;
  for (const model of catalog.models) {
    if (!model.model || typeof model.input !== "number" || typeof model.output !== "number") {
      throw new Error("model fields");
    }
    models += 1;
  }
  return models;
}

// @case: BM-pricing_catalog-001
// @feature: FP-pricing_catalog-01
// @scenario: hotspot
export function bench_bm_pricing_catalog_001_parse_validate() {
  const iterations = 5000;
  for (let i = 0; i < 200; i += 1) validate(catalogText);
  const start = performance.now();
  for (let i = 0; i < iterations; i += 1) validate(catalogText);
  const totalMs = performance.now() - start;
  return {
    id: "BM-pricing_catalog-001",
    module: "pricing_catalog",
    workload: "95 models / 22 KB catalog",
    iterations,
    total_ms: Number(totalMs.toFixed(3)),
    avg_us: Number(((totalMs * 1000) / iterations).toFixed(3)),
    avg_ns: Number(((totalMs * 1_000_000) / iterations).toFixed(1)),
    ops_per_sec: Number(((iterations * 1000) / totalMs).toFixed(1)),
  };
}

export function run() {
  return [bench_bm_pricing_catalog_001_parse_validate()];
}
