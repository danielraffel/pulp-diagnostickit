// A plain-text email with the diagnostics ZIP attached, as raw MIME, built
// without dependencies. The subject and body lead with what the report
// concluded, so the inbox shows the verdict before anyone opens the ZIP.

export interface ReportEmail {
  /** Fixed tag every report's subject starts with, for inbox filters. */
  subjectPrefix: string;
  from: string;
  to: string;
  reference: string;
  product: string;
  summary: string; // findings.json
  note: string;
  archiveName: string;
  archive: Uint8Array;
}

interface Finding { severity?: string; message?: string }

const headerSafe = (text: string) => text.replace(/[\r\n]+/g, " ").slice(0, 200);

// RFC 2047 encoded-word, so product names and notes with non-ASCII survive.
const encodeHeader = (text: string) =>
  /^[\x20-\x7e]*$/.test(text) ? text : `=?UTF-8?B?${base64(new TextEncoder().encode(text))}?=`;

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

const wrap76 = (text: string) => text.replace(/.{1,76}/g, (line) => line + "\r\n");

export function buildReportEmail(report: ReportEmail): string {
  let findings: Finding[] = [];
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(report.summary) as Record<string, unknown>;
    findings = Array.isArray(parsed.findings) ? (parsed.findings as Finding[]) : [];
  } catch {
    // An unreadable summary still delivers the archive.
  }
  const problems = findings.filter((f) => f.severity === "problem").length;
  const warnings = findings.filter((f) => f.severity === "warning").length;
  const verdict = problems ? `${problems} problem${problems === 1 ? "" : "s"}`
    : warnings ? `${warnings} warning${warnings === 1 ? "" : "s"}` : "nothing found";
  // "[DiagnosticKit] Spectr — 1 problem [AB12CD34]": filter on the tag for
  // every product, or on the tag plus the product name for one.
  const subject = headerSafe(`${report.subjectPrefix} ${report.product} — ${verdict} [${report.reference}]`);

  const mark = (s?: string) => (s === "problem" ? "❌" : s === "warning" ? "⚠️" : "ℹ️");
  const lines = [
    `${report.product} diagnostics report ${report.reference}`,
    `macOS ${parsed.macos ?? "?"} · ${parsed.architecture ?? "?"} · DiagnosticKit ${parsed.diagnostics_version ?? "?"}`,
    "",
    report.note.trim() ? `What happened:\n${report.note.trim()}\n` : "No note from the user.\n",
    "Likely problems:",
    ...(findings.length ? findings.map((f) => `${mark(f.severity)} ${f.message ?? ""}`) : ["✅ Nothing found that would stop it loading."]),
    "",
    `The full report is attached (${report.archiveName}).`,
  ];
  const boundary = `dk-${report.reference}-${Date.now().toString(36)}`;
  const text = base64(new TextEncoder().encode(lines.join("\n")));

  return [
    `From: DiagnosticKit <${report.from}>`,
    `To: ${report.to}`,
    `Subject: ${encodeHeader(subject)}`,
    `Message-ID: <${report.reference}.${Date.now()}@${report.from.split("@")[1] ?? "localhost"}>`,
    `Date: ${new Date().toUTCString()}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    wrap76(text),
    `--${boundary}`,
    `Content-Type: application/zip; name="${headerSafe(report.archiveName).replace(/"/g, "")}"`,
    "Content-Transfer-Encoding: base64",
    `Content-Disposition: attachment; filename="${headerSafe(report.archiveName).replace(/"/g, "")}"`,
    "",
    wrap76(base64(report.archive)),
    `--${boundary}--`,
    "",
  ].join("\r\n");
}
