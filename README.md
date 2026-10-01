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
- **Logic Pro / GarageBand** — the usual reason a correctly installed AU does
  not appear: the app set to *Open using Rosetta*, Audio Units switched off in
  Settings › Plug-ins, the product missing from Logic's component cache or
  cached at an older component version, a recorded validation result, and
  Logic's own AU scan logs (when it last scanned, and what it said)
- **Every DAW installed**, with version, architectures and Rosetta setting,
  plus REAPER's and Ableton Live's plug-in scan records
- **Load test** — each installed VST3 and CLAP is loaded in a child process
  (`dlopen`, then the format's entry point is asked what it contains), so a
  plug-in that cannot load, or crashes on load, is caught without a host
- **Editor render test** — the installed standalone app is run headless: it
  builds the same processor and editor as the plug-ins, brings up Metal, Dawn
  and Skia, renders the editor offscreen and exits (no window, no audio
  device). The GPU start-up log and the rendered image go in the archive
- **Other Pulp-built plug-ins**, and any Objective-C class names they share
  with the product (two plug-ins defining one class can run each other's code
  inside a host)
- The product's **saved data** folder, **folder permissions** on every plug-in
  location, **audio devices** (channels, sample rate, buffer, defaults),
  **microphone permission** checks, and **displays**
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

## Output modes

| Mode | When | Setup |
|------|------|-------|
| **Send to support** (recommended) | `SEND_ENDPOINT` + `SEND_KEY` are set | Deploy the free Cloudflare intake in [`server/cloudflare`](server/cloudflare/README.md). One button collects and sends; the user never opens a mail app. The report arrives as an email with the ZIP attached and a filterable `[DiagnosticKit] <Product>` subject. Failures retry once, then keep the ZIP on the Desktop with Try Again |
| **Local ZIP** (default) | No send or GitHub config present | None — drops `…-Diagnostics-<timestamp>.zip` on the Desktop, reveals it in Finder, tells the user the filename to send you |
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

The app ships with DiagnosticKit's own icon (`Resources/AppIcon.png`). To
brand it for a product, set `APP_ICON_PNG` in `.env` to a 1024×1024 PNG with
transparent corners; the build turns it into `AppIcon.icns`.

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

The archive also holds `findings.json` (schema `diagnostickit.findings.v1`):
the product, macOS version, architecture, what is installed where, the
`diagnostickit` build that produced it, and every finding with its severity,
for automated triage.

Per-product `.env` keys beyond the identifiers: `STATE_DIRS` (colon-separated
folders to summarise; default `~/Library/Application Support/<PLUGIN_NAME>`)
and `STANDALONE_PROBE` (`false` to skip the editor render test).

## Versioning

The app carries two versions, and every report names both:

- **App version** (`CFBundleShortVersionString`) is the version of the product
  it ships with. `APP_VERSION` in `.env` sets it (default: the kit version),
  and a product's packaging may restamp it so users see one number.
- **Kit version** is DiagnosticKit's own: the `VERSION` file at the root of
  this repository (`MAJOR.MINOR.PATCH`). `Scripts/build_app.sh` records it,
  the exact commit, and whether tracked files were modified as the
  `DiagnosticKitVersion`, `DiagnosticKitCommit` and `DiagnosticKitDirty`
  Info.plist keys. The report footer and `findings.json` repeat them, so any
  report traces back to the source that built it. The JUCE app reads the same
  `VERSION` file.

**No changes without versioning.** A change to what the app does (`Sources/`,
`Resources/`, `Scripts/build_app.sh`, `Package.swift`, the entitlements, or
the JUCE app's sources) raises `VERSION` in the same pull request: patch for a
fix, minor for new behaviour or report content, major for a change a product's
`.env` must adapt to. A released version is tagged `v<VERSION>` and frozen;
`Scripts/check_version_bump.sh` fails if the app's sources differ from the tag
for the current `VERSION`, or if a branch changes them without raising
`VERSION` above its base. CI (`.github/workflows/version.yml`) runs it on every
push and pull request, together with `Scripts/test_check_version_bump.sh`,
which proves the check rejects a planted unversioned change. To fail before
pushing instead, opt in to the same check locally:

```bash
git config core.hooksPath .githooks
```

To release: merge, then tag the merge commit `v<VERSION>` and push the tag.
Ship only builds from a clean, tagged commit (`DiagnosticKitDirty` false).

## Privacy

Reports are anonymized by default, on a best-effort basis with no guarantee:
the home path, account name, full name, computer name and hostname are
replaced with placeholders in the report, `findings.json` and every text file
in the archive (set `ANONYMIZE_USERNAMES=false` and `EXCLUDE_USER_PATHS=false`
to keep them). Raw crash reports are only copied in when anonymization is off.
In local-ZIP mode the user reviews and sends the output themselves — nothing is
uploaded automatically.

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
