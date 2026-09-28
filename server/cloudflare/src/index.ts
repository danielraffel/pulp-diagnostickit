// DiagnosticKit report intake: receives a diagnostics ZIP from the app and
// emails it, attached, to the owner's own verified address.
//
// The destination is fixed here, never taken from the request, so the
// endpoint cannot be used to mail anyone else. The upload key is shipped
// inside the app and is therefore recoverable; what it buys is that a
// casual request cannot post here, and a leaked key is rotated, not feared.
// A size cap and a per-IP rate limit bound what a leaked key can do.

import { EmailMessage } from "cloudflare:email";
import { buildReportEmail } from "./mime";

export interface Env {
  SEND: { send(message: EmailMessage): Promise<void> };
  LIMITER?: { limit(options: { key: string }): Promise<{ success: boolean }> };
  UPLOAD_KEY: string;
  FROM: string;
  TO: string;
  MAX_BYTES?: string;
  SUBJECT_PREFIX?: string;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json(200, { ok: true });
    if (request.method !== "POST" || url.pathname !== "/report") return json(404, { error: "not found" });

    if (!env.UPLOAD_KEY || request.headers.get("authorization") !== `Bearer ${env.UPLOAD_KEY}`) {
      return json(401, { error: "unauthorized" });
    }
    if (env.LIMITER) {
      const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
      if (!(await env.LIMITER.limit({ key: ip })).success) return json(429, { error: "too many reports; try again later" });
    }
    const max = Number(env.MAX_BYTES ?? 20_000_000);
    if (Number(request.headers.get("content-length") ?? "0") > max) return json(413, { error: "report too large" });

    let form: FormData;
    try {
      form = await request.formData();
    } catch {
      return json(400, { error: "expected multipart/form-data" });
    }
    const archive = form.get("archive");
    if (!(archive instanceof File) || archive.size === 0) return json(400, { error: "missing archive" });
    if (archive.size > max) return json(413, { error: "report too large" });

    const reference = crypto.randomUUID().slice(0, 8).toUpperCase();
    const raw = buildReportEmail({
      subjectPrefix: env.SUBJECT_PREFIX ?? "[DiagnosticKit]",
      from: env.FROM,
      to: env.TO,
      reference,
      product: String(form.get("product") ?? "Product").replace(/[^\p{L}\p{N} ._-]/gu, "").slice(0, 60) || "Product",
      summary: String(form.get("summary") ?? "{}"),
      note: String(form.get("note") ?? ""),
      archiveName: archive.name || `${reference}.zip`,
      archive: new Uint8Array(await archive.arrayBuffer()),
    });
    try {
      await env.SEND.send(new EmailMessage(env.FROM, env.TO, raw));
    } catch (error) {
      return json(502, { error: `could not send: ${(error as Error).message}` });
    }
    return json(200, { ok: true, reference });
  },
};
