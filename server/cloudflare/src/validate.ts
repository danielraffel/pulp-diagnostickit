// Accept only what DiagnosticKit produces: a ZIP holding diagnostic_report.md
// and findings.json, with a summary carrying the DiagnosticKit schema tag.
// This cannot prove the app sent it (anything the app sends can be copied);
// it keeps arbitrary uploads from becoming email.

const REQUIRED_FILES = ["diagnostic_report.md", "findings.json"];

export function looksLikeReport(archive: Uint8Array, summary: string): string | null {
  // Local file header signature "PK\x03\x04".
  if (archive.length < 4 || archive[0] !== 0x50 || archive[1] !== 0x4b || archive[2] !== 0x03 || archive[3] !== 0x04) {
    return "not a zip archive";
  }
  // Entry names are stored uncompressed in the ZIP's headers.
  const names = new TextDecoder("latin1").decode(archive);
  for (const file of REQUIRED_FILES) {
    if (!names.includes(`/${file}`) && !names.includes(file)) return `archive has no ${file}`;
  }
  try {
    const parsed = JSON.parse(summary) as { schema?: unknown };
    if (parsed.schema !== "diagnostickit.findings.v1") return "summary is not a DiagnosticKit summary";
  } catch {
    return "summary is not JSON";
  }
  return null;
}
