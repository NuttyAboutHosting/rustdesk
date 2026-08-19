# NahSupport - NAH custom client (fork notes)

This is Nutty About Hosting's fork of [RustDesk](https://github.com/rustdesk/rustdesk),
building the **NahSupport** remote-support client used by our internal support
platform. Upstream code is AGPL-3.0; this fork stays public to satisfy the
source-offer obligation for the clients we distribute to customers.

Branch layout:

* `master` - mirrors upstream master (sync via GitHub "Sync fork").
* `nah/custom-client` - our branch, based on the `1.4.9` release tag.
  Rebase onto newer release tags, never onto master tip.

## What is patched (kept deliberately small)

| Change | Where |
|---|---|
| `nah` module: embedded custom-client config, session-code parsing, portal registration | `src/nah.rs` (new) |
| Apply embedded config on every process start | `src/common.rs` -> `load_custom_client()` |
| Spawn session reporter on plain UI launch | `src/core_main.rs` (before the final UI return) |
| Module registration | `src/lib.rs` |
| NAH build workflow | `.github/workflows/nah-build.yml` (new) |
| macOS bundle rebrand: `NAHSupport.app`, bundle id `uk.co.nuttyabouthosting.support`, `nahsupport://` URL scheme, NAH AppIcon.icns | `flutter/macos/Runner*` (pbxproj, AppInfo.xcconfig, Info.plist, AppIcon.icns) |
| macOS min version 10.14 -> 12.3 (screencapturekit; upstream CI seds this into its arm64 job at build time, we commit it - arm64-only fork) | `build.py`, `flutter/macos/Podfile`, `Cargo.toml`, `project.pbxproj` |
| macOS `.app` path fixes for the renamed bundle | `build.py` (`build_flutter_dmg`) |

No changes to `libs/hbb_common` (submodule still points at upstream) and no
changes to the protocol, so upstream release rebases should be low-friction.

## How the customisation works

Upstream already contains the "custom client" machinery used by RustDesk Pro's
client generator: `load_custom_client()` reads a signed `custom.txt` and applies
app name, pinned server settings, and hard-locked options. Our patch calls
`nah::apply_embedded_config()` at the top of that function, applying the same
kinds of settings from compile-time constants instead of a signed file:

* App identity becomes **NahSupport** (window title, `nahsupport://` URI,
  config dir `%AppData%\NahSupport` - so a customer's real RustDesk install,
  if any, is untouched).
* `custom-rendezvous-server` and `key` are written to `OVERWRITE_SETTINGS`,
  which wins over any user-editable option - the client can only talk to our
  server.
* The **support** flavour also hard-locks: incoming-only UI (`conn-type`),
  `disable-installation`, `disable-account`, `disable-settings`, and
  click-to-accept (`approve-mode=click`, no passwords).

## Session codes

The customer downloads `NahSupport-<code>.exe` from the support portal. The
filename is applied by the portal's download endpoint; the binary is identical
for every session, so one Authenticode signature stays valid for all of them.

On launch, `nah::spawn_session_reporter()`:

1. recovers the original filename (the portable self-extractor forwards it via
   the `RUSTDESK_APPNAME` env var, same as upstream's filename-config feature),
2. parses the trailing `-<4..12 digits>` as the session code (tolerating
   Windows " (1)" duplicate-download suffixes),
3. POSTs `{ rustdeskId, platform, hostname, clientVersion }` to
   `<NAH_API_BASE>/api/v1/support/remote/sessions/<code>/register` with
   retries, so the portal can show "customer online" and give the technician
   the ID to connect to.

A plain `NahSupport.exe` (no code) runs fine and skips registration; the
customer can read their ID out over the phone as a fallback.

On macOS the customer downloads `NahSupport-<code>.dmg`. Renaming a dmg does
not change its volume name and the app inside is always `NAHSupport.app`, so
the code never reaches the executable's filename. Instead, when the app is
launched from a mounted disk image (exe under `/Volumes/...`),
`session_code_from_mounted_dmg()` asks `hdiutil info` which image file backs
that mount and parses the code from the *dmg's* filename - i.e. the file the
portal renamed. One binary and one notarization stay valid for every session.
If the customer drags the app to /Applications first and launches it from
there, the code is lost and registration is skipped (phone-a-code fallback).

## Build-time configuration

All read via `option_env!` in `src/nah.rs`. Endpoint values are injected by
CI from repository variables (Settings -> Secrets and variables -> Actions)
rather than committed here; empty values give an unpinned dev build with
session registration disabled.

| Env var | Source | Purpose |
|---|---|---|
| `NAH_RENDEZVOUS_SERVER` | `vars.NAH_RENDEZVOUS_SERVER` | hbbs/hbbr host to pin |
| `NAH_RS_PUB_KEY` | `vars.NAH_RS_PUB_KEY` | hbbs public key (`id_ed25519.pub` content from the server) |
| `NAH_API_BASE` | `vars.NAH_API_BASE` | support portal API base for session registration |
| `NAH_FLAVOR` | build matrix | `support` (customer) or `technician` (staff) |

## CI (`.github/workflows/nah-build.yml`)

Runs on push to `nah/custom-client` or manually. Reuses upstream's
`bridge.yml` and TopMostWindow reusable workflows, then builds Windows x64
for both flavours and uploads `NahSupport.exe` / `NahSupportTechnician.exe`
as artifacts.

Repo settings it consumes:

* `vars.NAH_RS_PUB_KEY` - set once the VPS exists (public value, fine as a
  repo variable). Until set, builds are unpinned dev builds.
* `vars.NAH_ENABLE_SIGNING` = `true` + `secrets.AZURE_TENANT_ID` /
  `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` - enables the Azure Trusted
  Signing steps (account/profile names in the workflow are TODO until the
  Azure Trusted Signing account is provisioned).

## Still to do

* [ ] VPS: hbbs/hbbr up on the rendezvous host, then set
      `vars.NAH_RS_PUB_KEY` and rebuild.
* [ ] Azure Trusted Signing: identity validation, then fill the TODOs in
      `nah-build.yml` and set `vars.NAH_ENABLE_SIGNING`.
* [ ] Portable wrapper still extracts to `%LocalAppData%\rustdesk`
      (`libs/portable` hardcodes the name) - cosmetic, but rename alongside
      the icon work. Verified 2026-07-11: config/logs correctly use
      `%AppData%\NahSupport`; only the extraction dir keeps the old name.
* [x] Visual branding: NAH "n" logomark icons (app_icon.ico, res/icon.*,
      tray-icon.ico, flutter/assets/icon.svg) and Runner.rc metadata
      (ProductName/CompanyName/description now NahSupport / NAH). Regenerate
      via `nah-assets/gen-icons.js`.
* [x] macOS build job (arm64): `build-macos-arm64` in nah-build.yml, bundle
      rebranded to NAHSupport.app / uk.co.nuttyabouthosting.support, session
      code recovered from the backing dmg via hdiutil. Unsigned on push;
      Developer ID signing + notarization runs on workflow_dispatch sign=true
      once the APPLE_* secrets exist in the `release-signing` environment.
* [ ] Portal side: `support.RemoteSessions` table + endpoints in
      Nah.Support.Next (see `docs/research/remote-support-rustdesk-architecture.md`
      in that repo).
* [ ] Verify on a real build that `disable-settings` does not hide anything
      the customer needs (accept prompt, elevation request); relax to
      `disable-settings=N` if it does.
