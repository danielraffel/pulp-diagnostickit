# DiagnosticKit

> **An optional developer add-on for [Pulp](https://github.com/Generous-Corp/pulp).**
> Not part of Pulp core, not required to build or ship a Pulp plugin. It's a
> small "double-click and send me the results" helper for **debugging a failed
> install on someone else's machine** — when a user says "your plugin didn't
> load," they run this and send you back a single report.

When run, it collects the things that explain a "won't load":

- **macOS / system info** and **audio devices**
- **Plugin status** per format (AU / VST3 / CLAP / Standalone) — installed paths,
  bundle IDs, AU component type/subtype/manufacturer
- **Security / Gatekeeper signals** — `codesign --verify`, signing authority,
  **quarantine xattr**, and **executable architecture (arm64 / x86_64)** — which
  is what catches "Intel Mac vs an arm64-only build" and "downloaded copy got
  quarantined"
- **Build information** per installed bundle — version, the bundle's
  `pulp-build-info.json` (product/SDK revisions and the Skia, Dawn and
  wgpu-native pins it was built with), and for every executable and bundled
  library: architectures, minimum macOS, signature, and any `@rpath`
  dependency that does not resolve inside the installed bundle
- **Gatekeeper / notarization** verdicts (`spctl --assess`, `stapler`)
- **Installer history** — `pkgutil` receipts and each install session in
  `/var/log/install.log`, judged completed / failed / unfinished, plus free
  disk space
- **Audio Unit registration** (`auval -a`) and a full **`auval -v`** run
- **GPU / Metal** support, **crash and hang reports that mention the product**
  (including host crashes such as a DAW crashing with the plug-in loaded), and
  the last hour of **system log** lines naming it
- **Pulp model state** (model-backed plugins only, when `PULP_MODEL_PATH` is set)

The report opens with **Likely Problems**: the conclusions drawn from all of
the above (not installed, duplicate or mismatched installs, wrong architecture,
macOS too old, broken signature, unresolved library, AU not registered or
failing validation, failed install), so the cause is the first thing a reader
sees. Raw evidence (`auval.txt`, install-log and system-log excerpts, crash
reports) goes into the ZIP next to the report.

It then writes everything into a report and either drops a **ZIP on the
Desktop** (default, no setup) or opens a **GitHub issue** (optional).

## When to use it

Best for **early distribution / beta** and **one-off "can you run this and send
me the result?"** moments — when a tester or user hits "it doesn't load" and you
need the facts from *their* machine. It is **intentionally minimal** — not a
polished product experience by design — but it's far friendlier than asking a
non-technical user to run Terminal commands, and it's just **one** easy way to
collect that data. It's an optional add-on; reach for it when sharing test
builds, not as a default part of a public release.

## Two output modes

| Mode | When | Setup |
|------|------|-------|
| **Local ZIP** (default) | No GitHub config present | None — drops `…-Diagnostics-<timestamp>.zip` on the Desktop, reveals it in Finder, tells the user the filename to send you |
| **GitHub issue** | `GITHUB_REPO` + a fine-grained PAT are configured | Create a PAT with *Issues: Read/Write* scoped to one repo |

## Two implementations

| Platform | Implementation | Status |
|----------|---------------|--------|
| **macOS** | `Sources/` — Swift/SwiftUI app | **working** — Developer-ID-signable, hardened-runtime, headless `--selftest`, local-ZIP + GitHub modes |
| **Windows / Linux** | `JUCE/` — JUCE C++ app (JUCE fetched at build time, not redistributed here) | Windows tested; Linux compiles, not yet hardware-validated |

## Quickstart (macOS, CLI)

```bash
git clone https://github.com/danielraffel/pulp-diagnostickit
cd pulp-diagnostickit

# Configure: copy the template, fill in your plugin's identifiers. Leave the
# GitHub fields blank for local-ZIP mode (no setup needed).
cp .env.example .env && $EDITOR .env

# Build the signed .app  →  build/<AppName>.app
BUILD_TYPE=release ./Scripts/build_app.sh

# Verify headlessly: drops a diagnostics ZIP on the Desktop and prints its path
# (DIAGNOSTICKIT_OUTPUT_DIR=/some/dir writes it there instead)
./build/*Diagnostics.app/Contents/MacOS/* --selftest
```

`.env` is per-project instance config and is **gitignored**; `.env.example` is
the committed template. Nothing secret lives in the repo — the GitHub PAT, if
you use GitHub mode, stays only in your local `.env`.

## Bundling it into a Pulp plugin installer (optional)

Pulp example installers treat DiagnosticKit as a **graceful, optional add-on**.
For the [Magenta example](https://github.com/danielraffel/pulp-magenta-examples),
build the diagnostics app, then point the installer at it:

```bash
PULP_MAGENTA_V2_DIAGNOSTICS_APP="$PWD/build/PromptableAccompanistV2Diagnostics.app" \
  /path/to/pulp-magenta-examples/scripts/build-v2-test-dmg.sh <build_dir>
```

The installer's `PULP_MAGENTA_V2_INCLUDE_DIAGNOSTICS` defaults to `auto`: it adds
a selectable "Diagnostics Helper" component **if the app is present**, and
**skips gracefully (never errors)** if it isn't — so a release that doesn't ship
the add-on just builds without it. Set `=0` to force it off.

## Privacy

Diagnostic collection honors `ANONYMIZE_USERNAMES` and `EXCLUDE_USER_PATHS`
(strip the local username / home paths from the report), and in local-ZIP mode
the user reviews and sends the output themselves — nothing is uploaded
automatically.

## Security notes (GitHub mode)

Local-ZIP mode (the default) sends nothing automatically and is the privacy-safe
path. If you opt into **GitHub mode**, be aware:

- The PAT is read from `.env` and **baked into the distributed app** (so the app
  can file issues without prompting). Anyone who has the binary can recover it —
  use a **fine-grained, Issues-write-only, expiring** token scoped to a single
  diagnostics repo, and rotate it.
- The **Windows** C++ uploader currently shells the upload through a temporary
  batch file; treat the GitHub-repo / path values as trusted (developer-set).
  Prefer local-ZIP mode unless you specifically need auto-filed issues. (Tracked
  as a hardening follow-up; see the note in `JUCE/Source/GitHubUploader.cpp`.)

## Not for production

This is a **development & testing** tool. Bundle it in test builds you hand to
collaborators; don't ship it as a default component of a public release (the
Pulp installer's `auto` / `=0` switch makes that a one-line decision).
