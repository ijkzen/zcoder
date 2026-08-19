# AGENTS.md

## What this repo is

**zcoder** is the Android remote-control client for the ZCode desktop app: it pairs with a desktop device via QR scan, then watches/drives coding sessions from the phone. The only code is the Flutter app in `app/` (a single `zcode_remote` module). The root also holds domain docs — nothing else lives outside `app/`.

## Layout

```
app/lib/main.dart
app/lib/src/
  ui/         Flutter screens & widgets (sessions_page, conversation_page, scan_page, …)
  bridge/     bridge_manager.dart — the RPC channel between terminal and one workspace (one bridge per open workspace)
  protocol/   the wire protocol: relay transport, binary RPC channel (varint/crc32/fragment), topics, services, zlog
  session/    conversation_controller (snapshot+deltas), session_status_monitor (completion notifications)
  services/   notifications, update_checker (GitHub Releases self-update), app_version
  storage/    app_database.dart (sqflite local cache)
app/tool/     build_e2e_apk.sh, probe_relay.dart (debug against a live relay)
docs/
  protocol/   01-08 — authoritative wire-protocol references (read before touching protocol/)
  adr/        architecture decision records
  ui-test-cases.md   UI behavior contract (v1.5)
CONTEXT.md    domain glossary — USE ITS VOCABULARY in issues/commits/PRs (see docs/agents/domain.md)
```

## Build / test / lint

All commands run from `app/`:

- `flutter analyze`
- `flutter test` (≈224 tests)
- `flutter run` against a device/emulator
- Release E2E APK: `app/tool/build_e2e_apk.sh` — release + arm64-only + R8 + `release-key.jks` signing + `--dart-define=ZREMOTE_LOG=true` (zlog goes to the in-app protocol log page and logcat with `[zremote]` prefix). CI builds 3 APKs (arm64/armv7/universal) the same way.

CI (`flutter analyze` + `flutter test`) is enforced in `.github/workflows/ci.yml`; keep it green.

## Architecture rules

- **UI → session/bridge/services → protocol/storage**: UI never constructs wire frames or touches RPC directly; use the controllers/bridge. Keep protocol parsing free of widget code.
- **Layer vocabulary** comes from `CONTEXT.md` (Session vs Conversation, Row, Bridge, Approval, Snapshot & deltas, Stop, Workspace). Don't invent synonyms.
- **Conversation state arrives as a full snapshot on subscribe, then incremental deltas** (rows appended/upserted/delta-patched, `state.updated` patches) — never as whole reloads. A past bug (extra list wrapper around `requestEvent` args) silently broke all frame routing; verify event-listener argument shapes against `docs/protocol/`.
- **Completion notifications**: list polling every 20s + detail-page 2s polling share a `_notifiedTerminal` dedup per task; `SessionStatusMonitor` is pure logic, no UI. Foreground + focused detail page suppresses the completion notification.

## Conventions & gotchas

- Lints: `flutter_lints` defaults, no custom rules (`analysis_options.yaml`). No `print` — use `zlog` (`src/protocol/zlog.dart`) for protocol tracing.
- UI: keep the existing Material 3 style; don't copy styles from other projects. Low-frequency entries go into a secondary/overflow menu, create one if none exists. Shared composer bits live in `command_suggestion_panel.dart` / `chat_composer.dart` — reuse, don't reimplement.
- **Android emulator is not reliable for ShaderMask/saveLayer compositing** (whole rows render solid grey, no logcat error). Use per-character coloring for visual verification on the emulator; keep ShaderMask on real devices.
- **mobile_scanner**: after first-time permission grant, barcode detection can stop (CameraX `bindToLifecycle` timing) — rebind on resume.
- **Self-update**: app/`pubspec.yaml` version is `0.4.22+29`. Release flow = bump only the version + commit `chore: bump version to X.Y.Z+N` + annotated tag `vX.Y.Z` + push; pushing the tag auto-triggers `release.yml` → 3 signed APKs + a GitHub Release the in-app update checker fetches. Builders use the git-history convention in the existing commits.
- **`/flutter_project_upgrade` is a prompt-based command** (`~/.zcode/commands/*.md`), not a Skill — follow its instructions directly, never via the Skill tool.
- A codegraph index for this repo is configured as a workspace MCP server; prefer it for cross-file exploration.

## Read before sensitive changes

- `docs/protocol/*.md` before any protocol/transport edit; `docs/adr/` before architecture changes; `CONTEXT.md` before naming anything; `docs/ui-test-cases.md` before changing UI behavior.

## Agent skills

### Issue tracker

Issues are tracked as GitHub issues on `ijkzen/zcoder`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical labels are used as-is: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.
