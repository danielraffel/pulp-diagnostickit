# Report intake on Cloudflare (free)

A Cloudflare Worker that receives a diagnostics ZIP from the app and emails it,
attached, to your own inbox. With it configured, the app's one button is
**Collect & Send to Support**: the user never opens a mail app.

Everything here fits Cloudflare's free plan: Workers (100,000 requests a day),
Email Routing, and sending from a Worker to your own verified address. No R2
storage is used, so no payment method is required.

## What it does

`POST /report` with `Authorization: Bearer <UPLOAD_KEY>` and a
`multipart/form-data` body:

| field | content |
|---|---|
| `archive` | the diagnostics ZIP (file) |
| `product` | product name |
| `summary` | the archive's `findings.json` |
| `note` | what the user typed (may be empty) |

It replies `{"ok": true, "reference": "AB12CD34"}` and sends one email:

- **Subject:** `[DiagnosticKit] <Product> — <N problems | N warnings | nothing found> [<reference>]`.
  Filter on `[DiagnosticKit]` for every product, or `[DiagnosticKit] Spectr`
  for one. The tag is `SUBJECT_PREFIX` below.
- **Body:** the user's note and every finding, so the verdict is readable
  without opening the ZIP.
- **Attachment:** the ZIP, byte for byte.

Errors are JSON `{"error": "..."}` with status 401 (wrong key), 413 (over
`MAX_BYTES`), 429 (more than 5 reports a minute from one IP), 400 (malformed),
502 (the email could not be sent). The app retries once on 429/5xx and on
connection failures, and otherwise tells the user in plain words while keeping
the ZIP on their Desktop.

### Why a shipped key is acceptable

`UPLOAD_KEY` is inside every copy of the app, so treat it as recoverable. The
destination address is fixed in this Worker's configuration and never taken
from the request, so a leaked key can only send *you* reports: it cannot be
used to email anyone else. The size cap and rate limit bound the nuisance, and
rotating the key (below) ends it.

## Set it up (one time, per owner)

Needs a domain on Cloudflare DNS and `wrangler` logged in (`wrangler login`).

1. **Email Routing** — Cloudflare dashboard → your domain → Email → Email
   Routing → enable. This adds the domain's MX records (replace any existing
   mail setup only if you mean to). Under *Destination addresses*, add the
   inbox reports should land in and click the verification link Cloudflare
   emails to it. Optionally add a routing rule so an address on your domain
   (e.g. `support@yourdomain`) forwards there too.
2. **Configure**: copy `wrangler.toml` to `wrangler.local.toml` (git-ignored,
   so your addresses stay out of the repository) and edit the copy:
   - `FROM`: an address on the Email Routing domain (it need not exist as a
     mailbox), e.g. `diagnostics@yourdomain`.
   - `TO` and `[[send_email]] destination_address`: the verified inbox.
   - `SUBJECT_PREFIX`, `MAX_BYTES`: optional.
   - `name`: the Worker's name, which becomes its URL.
3. **Deploy and set the key:**
   ```bash
   cd server/cloudflare
   wrangler deploy --config wrangler.local.toml
   openssl rand -hex 24 | tee /dev/stderr | wrangler secret put UPLOAD_KEY --config wrangler.local.toml
   ```
   Keep the printed key; the app needs it.
4. **Check it:** `curl https://<name>.<account>.workers.dev/health` → `{"ok":true}`,
   then send a real report (below) and confirm the email arrives with the ZIP.

## Point a product at it

In the product's DiagnosticKit `.env`:

```bash
SEND_ENDPOINT="https://<name>.<account>.workers.dev/report"
SEND_KEY="<the key from step 3>"
```

Keep `SEND_KEY` out of version control: commit the `.env` with the endpoint
only and add the key when building (for example from a local secrets file).
With both set, the app sends automatically; with either missing it falls back
to saving the ZIP on the Desktop.

One Worker can serve several products: the product name travels in each
report and appears in the subject.

## Rotate the key

```bash
openssl rand -hex 24 | tee /dev/stderr | wrangler secret put UPLOAD_KEY --config wrangler.local.toml
```

Builds carrying the old key then get "This build isn't allowed to send reports
any more" and keep the ZIP on the Desktop; ship a build with the new key.

## Tests

```bash
DK_SAMPLE_ZIP=/path/to/a/Product-Diagnostics-*.zip node --test test/*.test.ts
```

Covers the subject, body, the attachment decoding to the exact archive bytes,
MIME line rules, header injection through the product name, and the report
check.

## What the intake accepts

Only a DiagnosticKit report: a ZIP holding `diagnostic_report.md` and
`findings.json`, sent with a summary carrying the `diagnostickit.findings.v1`
schema tag. Anything else is refused with 400 before any email is built. This
cannot prove the app sent it (anything the app sends can be copied), but it
keeps arbitrary uploads from reaching your inbox.
