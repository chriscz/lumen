# Releasing Lumen & Signing Key Security

This guide covers everything needed to safely sign Android APKs on GitHub Actions, protect your signing key from pull requests and leaks, back up the keystore, distribute via Obtainium, and submit to F-Droid (including Reproducible Builds).

---

## 1. Security Model: Why PRs Cannot Read Signing Keys

Android release signing keys are permanent cryptographic identity credentials. If leaked, an attacker could sign malicious updates; if lost, existing users can never install updates without uninstalling and losing app data.

Lumen enforces strict separation between untrusted PR CI and release signing:

1. **Zero signing secrets in `ci.yml`:** Pull request and branch CI builds an **unsigned** release APK (`--unsigned`) and never references any signing environment or secret.
2. **Environment-scoped secrets only:** Signing secrets are stored **only** inside a protected GitHub Environment named `release`, never as repository-wide secrets.
3. **Tag/branch deployment restrictions + manual approval:** The `release` Environment only allows deployment from `v*.*.*` tags (and `main` for manual `workflow_dispatch`) and requires explicit owner approval before any signing job can start.
4. **Clean release environment:** `release.yml`'s `build-and-sign` job does not restore PR build caches, downloads a fresh SHA-256-verified Flutter SDK, decodes the keystore into a `chmod 600` temp file outside the workspace, shreds it in `if: always()`, verifies every APK with `apksigner`, and attaches SLSA build provenance attestations (`actions/attest-build-provenance`).
5. **Local secret guards:** `.gitignore` and `scripts/check_signing_secrets.rb` (pre-commit and pre-push via `lefthook`) block accidental commits of `*.jks`, `*.keystore`, `*.p12`, `*.pfx`, `*.pk8`, `key.properties`, or PEM private keys.

---

## 2. Generate Your Release Keystore (One-Time Setup)

Run this **outside** the repository (for example in `~/.secrets/lumen/`):

```sh
mkdir -p ~/.secrets/lumen
chmod 700 ~/.secrets/lumen

keytool -genkeypair -v \
  -storetype PKCS12 \
  -keystore ~/.secrets/lumen/lumen-release.p12 \
  -alias lumen \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=Lumen, O=chriscz"
```

Choose a strong, unique keystore password (with PKCS12, store password and key password are the same).

### Record the Certificate SHA-256 Fingerprint

Print the public certificate fingerprint and publish it in `README.md` (and release notes) so users can verify APK authenticity:

```sh
keytool -list -v -keystore ~/.secrets/lumen/lumen-release.p12 -alias lumen | grep -E "SHA256:|SHA1:"
```

### Base64-Encode for GitHub Environment Secrets

Copy the single-line base64 output directly to your clipboard or a temporary variable (avoid leaving unencrypted base64 text files lying around):

```sh
base64 -w 0 ~/.secrets/lumen/lumen-release.p12
```

---

## 3. Keystore Backup Checklist (Critical)

Before uploading your keystore to GitHub, store a verified backup in **at least two independent places**:

- [ ] **Password manager** (e.g. Bitwarden, 1Password, or KeePassXC): attach `lumen-release.p12` and save:
  - Keystore filename (`lumen-release.p12`)
  - Keystore password (`ANDROID_KEYSTORE_PASSWORD`)
  - Key alias (`lumen`)
  - Key password (`ANDROID_KEY_PASSWORD`)
  - Public certificate SHA-256 fingerprint
- [ ] **Offline encrypted backup** (e.g. encrypted USB drive or encrypted archive stored offline): copy `lumen-release.p12` + a note with the alias and SHA-256 fingerprint (keep the password in your password manager or separate secure location).
- [ ] **Test restore once:** Verify your backup opens cleanly with `keytool -list -keystore <backup-copy> -alias lumen` before deleting any temporary files.

If you ever lose this keystore, you cannot update existing Obtainium or F-Droid Reproducible Build installations without changing `applicationId` or asking users to uninstall and reinstall.

---

## 4. Configure GitHub Repository Rules & `release` Environment

Complete these one-time settings in `https://github.com/chriscz/lumen/settings`:

### A. Create the Protected `release` Environment

Go to **Settings > Environments > New environment** and name it exactly **`release`**.

1. **Deployment protection rules:**
   - Check **Required reviewers** and add yourself (`chriscz`). Every release signing run will pause and wait for your explicit approval in GitHub UI.
2. **Deployment branches and tags:**
   - Select **Selected branches and tags**.
   - Add tag rule: `v*.*.*`
   - Add branch rule: `main` (needed when triggering `workflow_dispatch` from `main`).
   - Do **not** allow all branches or pull requests.
3. **Environment secrets** (add these four secrets **inside `release`**, NOT in Repository Secrets):
   - `ANDROID_KEYSTORE_BASE64`: single-line base64 of `lumen-release.p12`
   - `ANDROID_KEYSTORE_PASSWORD`: keystore password
   - `ANDROID_KEY_ALIAS`: `lumen`
   - `ANDROID_KEY_PASSWORD`: key password (same as keystore password for PKCS12)

### B. Configure Repository Rulesets

Go to **Settings > Rules > Rulesets**:

1. **Branch ruleset (`protect-main`):**
   - Target: default branch (`main`).
   - Enable: Restrict deletions, Block force pushes.
   - Optionally require pull requests and the `ci / test-and-build` status check. (Note: if using `workflow_dispatch` in `release.yml`, allow GitHub Actions or push release prep commits via PR and trigger releases by pushing a tag.)
2. **Tag ruleset (`protect-release-tags`):**
   - Target: `refs/tags/v*.*.*`.
   - Enable: Restrict creations, Restrict updates, Restrict deletions.
   - Bypass list: Repository admin (`chriscz`) and GitHub Actions (if using `workflow_dispatch` tagging). This prevents any other contributor from creating a `v*.*.*` tag to trigger `release.yml`.

### C. Harden GitHub Actions General Settings

Go to **Settings > Actions > General**:

- **Workflow permissions:** Select **Read repository contents and packages permissions** (least privilege by default).
- **Fork pull request workflows from outside collaborators:** Select **Require approval for all outside collaborators**.

---

## 5. Publishing a Release

Two pure GitHub-native paths are supported (`.github/workflows/release.yml`):

### Option A: One-Click from GitHub UI (Recommended)

1. Update the `## [Unreleased]` section of `CHANGELOG.md` on `main`.
2. Open **Actions > release > Run workflow** on `main`.
3. Enter the version (for example `0.1.0`, without leading `v`) and keep **draft** checked to review before publishing.
4. Approve the `release` environment deployment prompt when `build-and-sign` pauses for your review.
5. The workflow updates `pubspec.yaml` (incrementing `+versionCode`), rolls `CHANGELOG.md`, writes `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`, tags `v0.1.0`, runs all Ruby and Flutter tests (100% coverage gate), builds and verifies signed `arm64-v8a`, `armeabi-v7a`, `x86_64`, and `universal` APKs + `SHA256SUMS.txt`, generates SLSA provenance attestations, and creates a draft GitHub Release.
6. Inspect the draft release and click **Publish release**.

### Option B: Local Prep + Tag Push

```sh
ruby scripts/prepare_release.rb --version 0.1.0 --debug
git add pubspec.yaml CHANGELOG.md fastlane/
git commit -m "chore(release): prepare v0.1.0" \
  -m "Assisted-by-AI-model: none" \
  -m "Assisted-by-AI-harness: none"
git push origin main
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

Approve the `release` environment prompt in GitHub Actions when notified.

---

## 6. Obtainium Compatibility

Obtainium tracks `https://github.com/chriscz/lumen` directly via GitHub Releases:

- Release assets always follow the deterministic naming scheme:
  - `lumen-vX.Y.Z-arm64-v8a.apk`
  - `lumen-vX.Y.Z-armeabi-v7a.apk`
  - `lumen-vX.Y.Z-x86_64.apk`
  - `lumen-vX.Y.Z-universal.apk`
  - `SHA256SUMS.txt`
- Because ABI tokens (`arm64-v8a`, `armeabi-v7a`, `x86_64`) appear directly in the filenames, Obtainium automatically selects the matching split APK for each device (or `universal` as fallback) with no manual regex required.

---

## 7. Submitting to F-Droid (and Reproducible Builds)

Lumen is already prepared for F-Droid's free-software and reproducible-build requirements:

- **Application ID:** `dev.chriscz.lumen` (permanent).
- **100% FOSS dependencies:** All pub.dev packages are MIT/BSD-3-Clause/Apache-2.0 with zero Google Play Services or proprietary SDKs.
- **No Play dependency blob:** `android/app/build.gradle.kts` sets `dependenciesInfo { includeInApk = false; includeInBundle = false }`.
- **Fastlane metadata:** `fastlane/metadata/android/en-US/` holds title, descriptions, icon, screenshots, and per-`versionCode` changelogs (automatically kept in sync by `scripts/prepare_release.rb`).
- **Pinned toolchain:** Exact Flutter version (`3.47.7`), `pubspec.lock`, and Gradle wrapper are committed.

### Why Reproducible Builds Matter

By default, F-Droid builds from source and signs the APK with **F-Droid's own key**, which would prevent users from switching between Obtainium (signed with your key) and F-Droid without reinstalling.

When F-Droid's metadata recipe sets `Binaries: https://github.com/chriscz/lumen/releases/download/v%v/lumen-v%v-universal.apk` (see [packaging/fdroid/dev.chriscz.lumen.yml](../packaging/fdroid/dev.chriscz.lumen.yml)), F-Droid compiles from your git tag and compares the unsigned APK contents byte-for-byte against your GitHub Release APK. When they match, F-Droid publishes your **developer-signed APK**, so Obtainium and F-Droid share the exact same signing key.

### Submission Steps

1. Publish your first signed GitHub Release (e.g. `v0.1.0`).
2. Test reproducibility locally against `fdroidserver` (or open an [RFP issue](https://gitlab.com/fdroid/rfp/-/issues) / merge request on [`fdroid/fdroiddata`](https://gitlab.com/fdroid/fdroiddata)) using `packaging/fdroid/dev.chriscz.lumen.yml` as the starting recipe (`metadata/dev.chriscz.lumen.yml`).
3. If `diffoscope` reports any non-reproducible native build IDs from Flutter/JNI plugins, check F-Droid's Flutter build recipes for any needed Gradle or CMake flags and update `packaging/fdroid/dev.chriscz.lumen.yml`.
