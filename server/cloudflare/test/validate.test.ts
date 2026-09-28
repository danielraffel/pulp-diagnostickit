import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { looksLikeReport } from "../src/validate.ts";

const summary = JSON.stringify({ schema: "diagnostickit.findings.v1", findings: [] });

test("a real DiagnosticKit archive is accepted", () => {
  const zip = new Uint8Array(readFileSync(process.env.DK_SAMPLE_ZIP!));
  assert.equal(looksLikeReport(zip, summary), null);
});

test("junk, foreign zips and foreign summaries are refused", () => {
  assert.match(looksLikeReport(new TextEncoder().encode("hello"), summary)!, /not a zip/);
  const foreign = new Uint8Array([0x50, 0x4b, 0x03, 0x04, ...new TextEncoder().encode("photo.jpg")]);
  assert.match(looksLikeReport(foreign, summary)!, /no diagnostic_report.md/);
  const zip = new Uint8Array(readFileSync(process.env.DK_SAMPLE_ZIP!));
  assert.match(looksLikeReport(zip, "{\"schema\":\"other\"}")!, /not a DiagnosticKit summary/);
  assert.match(looksLikeReport(zip, "not json")!, /not JSON/);
});
