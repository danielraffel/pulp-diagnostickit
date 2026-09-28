import { test } from "node:test";
import assert from "node:assert/strict";
import { buildReportEmail } from "../src/mime.ts";

const zip = new Uint8Array([0x50, 0x4b, 0x03, 0x04, ...Array(300).fill(7)]);
const summary = JSON.stringify({
  macos: "Version 26.6.2", architecture: "arm64", diagnostics_version: "1.0.0",
  findings: [
    { severity: "problem", message: "Logic Pro is set to Open using Rosetta" },
    { severity: "warning", message: "Standalone App is installed 2 times" },
  ],
});
const mail = buildReportEmail({
  subjectPrefix: "[DiagnosticKit]",
  from: "diagnostics@generouscorp.com", to: "daniel@generouscorp.com", reference: "AB12CD34",
  product: "Spectr", summary, note: "Logic can't see it — tried twice\nand rebooted",
  archiveName: "Spectr-Diagnostics-20260927.zip", archive: zip,
});

const part = (name: string) => {
  const m = mail.match(new RegExp(`${name}[\\s\\S]*?\\r\\n\\r\\n([\\s\\S]*?)\\r\\n--`));
  assert.ok(m, `missing part ${name}`);
  return Buffer.from(m[1].replace(/\r\n/g, ""), "base64");
};

const subject = () => {
  const raw = mail.match(/^Subject: (.*)\r$/m)?.[1] ?? "";
  const encoded = raw.match(/^=\?UTF-8\?B\?(.*)\?=$/);
  return encoded ? Buffer.from(encoded[1], "base64").toString("utf8") : raw;
};

test("subject leads with the verdict and reference", () => {
  assert.equal(subject(), "[DiagnosticKit] Spectr — 1 problem [AB12CD34]");
});

test("body carries the note and every finding", () => {
  const body = part("Content-Type: text/plain").toString("utf8");
  assert.match(body, /What happened:\nLogic can't see it — tried twice\nand rebooted/);
  assert.match(body, /❌ Logic Pro is set to Open using Rosetta/);
  assert.match(body, /⚠️ Standalone App is installed 2 times/);
});

test("attachment decodes to the exact archive bytes", () => {
  assert.match(mail, /Content-Disposition: attachment; filename="Spectr-Diagnostics-20260927.zip"/);
  assert.deepEqual(new Uint8Array(part("Content-Type: application/zip")), zip);
});

test("base64 lines stay within 76 characters and headers end in CRLF", () => {
  for (const line of mail.split("\r\n")) assert.ok(line.length <= 998, "line too long");
  assert.ok(!/[^\r]\n/.test(mail), "bare LF in MIME");
});

test("a newline in the product name cannot inject a header", () => {
  const evil = buildReportEmail({ subjectPrefix: "[DiagnosticKit]", from: "a@b.c", to: "d@e.f", reference: "X", product: "Spectr\r\nBcc: x@evil",
    summary: "{}", note: "", archiveName: "a.zip", archive: zip });
  assert.doesNotMatch(evil, /^Bcc:/m);
});
