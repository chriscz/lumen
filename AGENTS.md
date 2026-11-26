# Lumen

Local-first Android controller for Philips Hue lights over Bluetooth Low Energy (GATT) and the Hue Bridge local REST API (v1), built with Flutter. Not affiliated with Signify.

## License

- **License:** MIT ([LICENSE](LICENSE), Copyright (c) 2026 Chris Coetzee).
- **Dependencies:** All pub.dev and local dependencies must remain permissively licensed (MIT, BSD, Apache-2.0) and F-Droid free-software compliant (no proprietary binary blobs, no Google Play Services, no telemetry).

## Layout

- `lib/domain/`: Immutable models (`Home`, `Light`, `Room`, `Profile`, capabilities, power-on, errors).
- `lib/color/`: CIE xy, sRGB, mireds, and gamut math.
- `lib/transport/ble/`: `BleCentral` seam, `HueBleCodec` (GATT TLV), `HueBleDriver`, and `UniversalBleCentral`.
- `lib/transport/bridge/`: `HueBridgeClient` (v1 REST API), `HueV1State`, and local-only `LanBridgeDiscovery`.
- `lib/emulator/`: Hue Bridge v1 emulator (`BridgeApi`, `BridgeServer`, `BridgeExtensions`), mDNS/DNS-SD responder, SSDP, and background lifecycle.
- `lib/plugins/`: `LumenPlugin` boundary, `PluginManager`, and experimental `MusicSyncPlugin`.
- `lib/music/`: Pure-Dart FFT, onset flux, beat tracker, follow modes, effects, and live trace.
- `lib/state/`: `HomeController`, `AppServices`, and JSON stores.
- `lib/sim/`: Byte-level simulated Bluetooth bulbs, simulated bridge, simulated audio, and demo home.
- `lib/ui/`: Material 3 screens and widgets.
- `packages/`: Local Android Flutter plugins (`lumen_bonded_devices`, `lumen_bridge_service`, `lumen_audio_capture`).
- `tool/`: Coverage checker (`coverage.sh`, `check_coverage.dart`), deterministic Android APK packager (`package_android.sh`), and cloud setup (`setup_cloud_env.sh`).
- `scripts/`: Repo guard hooks (`check_*.rb`) and release helper (`prepare_release.rb`), each with a sibling `test_<script>.rb` minitest suite.
- `fastlane/metadata/android/`: F-Droid / Fastlane store metadata and per-versionCode changelogs.
- `packaging/fdroid/`: Draft F-Droid `fdroiddata` reproducible-build recipe.
- `docs/`: Protocol reference (`protocol.md`), architecture (`architecture.md`), music sync (`music-sync.md`), releasing & signing security runbook (`releasing.md`), and screenshots.

## Setup and Checks

- Install git hooks with `lefthook install` (`lefthook.yml`). Never bypass with `--no-verify`.
- Run Dart/Flutter analysis and full test suite (including headless E2E tests): `flutter analyze && flutter test`.
- Enforce 100% line coverage across `lib/`: `bash tool/coverage.sh`.
- Run all Ruby hook and release script tests: `for t in scripts/test_*.rb; do ruby "$t"; done`.

## Signing Key Security

- **Never commit signing keystores (`*.jks`, `*.keystore`, `*.p12`, `*.pfx`, `*.pk8`), `key.properties`, or private keys.** Enforced by `.gitignore` and `scripts/check_signing_secrets.rb`.
- Release signing credentials live **only** as GitHub Environment Secrets inside the protected `release` Environment (restricted to `v*.*.*` tags and `main` with required reviewer approval).
- PR workflows (`ci.yml`) must never reference the `release` environment or read signing secrets; they build unsigned release APKs only.
- See [docs/releasing.md](docs/releasing.md) for keystore generation, backup, repository rulesets, Obtainium, and F-Droid Reproducible Builds.

## Testing: Red-Green TDD, Always

- Write the failing test first, watch it fail, make it pass, then refactor.
- Every Ruby script in `scripts/` needs a sibling `test_<script>.rb` using Ruby 3 stdlib minitest (`test "..." do ... end` DSL; no gems, no Gemfile).
- Expose script logic as classes/modules and guard CLI entry with `if $PROGRAM_NAME == __FILE__`.
- Include the MIT header in every source file and script: copyright line, `SPDX-License-Identifier: MIT`, and pointer to `LICENSE`.

### Codify What Repeats

- Repeated build, packaging, check, or release steps become deterministic scripts with pinned versions, clear exit codes, and `--help`, `--debug`, and `--dry-run` (for state-changing scripts) flags.

## Naming and Writing

- **Branches:** slash-separated kebab-case (`feat/beat-tracker`, `fix/ble-reconnect`), enforced by `scripts/check_branch_name.rb`.
- **No em-dashes:** Never use em-dashes in prose, code comments, commit messages, HTML entities, or `\u` escapes for U+2014. Enforced by `scripts/check_em_dashes.rb`.
- Use plain prose, headings, lists, and tables.

## Commits and Attribution

Enforced by `scripts/check_commit_message.rb` (commit-msg hook).

- Conventional Commits: `type(scope): description` (lowercase start, no trailing period, <=72 chars).
- Author every commit as the repo owner: `Chris Coetzee <chriscz93@gmail.com>`.
- Reserve `Co-Authored-By` trailers for human co-authors only.
- Disclose AI assistance with two kebab-case trailers at the end of each commit:
  - `Assisted-by-AI-model: <kebab-case-model>`
  - `Assisted-by-AI-harness: <kebab-case-harness>`
- Update PRs by rebasing onto `main` and force-pushing with `--force-with-lease`. Never merge `main` into a branch.

## Privacy and Outbound Requests

- Never send the owner's or any email address to external services.
- PreToolUse hook `scripts/check_outbound_email.rb` blocks outbound calls containing an email. Do not work around it.
