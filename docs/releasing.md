# Releasing Lumen & Signing Key Security

This guide covers everything needed to safely sign Android APKs on GitHub Actions, protect your signing key from pull requests and leaks, back up the keystore, distribute via Obtainium, and submit to F-Droid (including Reproducible Builds).

---

## 1. Security Model: Why PRs Cannot Read Signing Keys

Android release signing keys are permanent cryptographic identity credentials. If leaked, an attacker could sign malicious updates; if lost, existing users can never install updates without uninstalling and losing app data.

Lumen enforces strict separation between untrusted PR CI and release signing:

1. **Zero signing secrets in `ci.yml`:** Pull request and branch CI builds an **unsigned** release APK (`--unsigned`) and never references any signing environment or secret.
2. **Two isolated GitHub Environments:**
   - **`release-bot` (`main` branch only):** Holds the dedicated GitHub App credentials (`RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY`) used solely to push `chore(release)` commits to `main` and push `v*.*.*` tags via a ruleset bypass.
   - **`release` (`v*.*.*` tags only + required reviewer):** Holds the Android release signing keystore (`ANDROID_KEYSTORE_*`). Not even `main` can touch the signing keystore; only a tagged release approved by you can sign APKs.
3. **Clean release environment:** `release.yml`'s `build-and-sign` job does not restore PR build caches, downloads a fresh SHA-256-verified Flutter SDK, decodes the keystore into a `chmod 600` temp file outside the workspace, shreds it in `if: always()`, verifies every APK with `apksigner`, and attaches SLSA build provenance attestations (`actions/attest-build-provenance`).
4. **Local secret guards:** `.gitignore` and `scripts/check_signing_secrets.rb` (pre-commit and pre-push via `lefthook`) block accidental commits of `*.jks`, `*.keystore`, `*.p12`, `*.pfx`, `*.pk8`, `key.properties`, or PEM private keys.

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

## 4. Configure GitHub App Bypass, Environments & Repository Rules

Complete these one-time settings so `main` and `v*.*.*` tags stay strictly protected while `workflow_dispatch` can still commit release prep files and trigger signed builds:

### A. Create a Dedicated Release GitHub App (Least-Privilege Bypass)

1. Go to **GitHub Settings > Developer settings > GitHub Apps > New GitHub App**.
2. Name it (e.g. `chriscz-lumen-release-bot`), set any homepage URL (`https://github.com/chriscz/lumen`), and **uncheck** Webhook -> Active.
3. Under **Repository permissions**, set **Contents: Read and write** (leave every other permission as **No access**).
4. Set **Where can this GitHub App be installed?** to **Only on this account**, then create the app.
5. Note the **App ID**, scroll to **Private keys**, and click **Generate a private key** (downloads a `.pem` file; delete the local copy after uploading to GitHub Environment Secrets, or keep a backup in your password manager).
6. Go to **Install App** and install it on **`chriscz/lumen` only**.

### B. Create the Two Protected GitHub Environments

Go to `https://github.com/chriscz/lumen/settings/environments`:

1. **Environment 1: `release-bot`**
   - **Deployment branches and tags:** Selected branches and tags -> add branch **`main`** only (no PRs, no other branches).
   - **Environment secrets:**
     - `RELEASE_APP_ID`: your GitHub App's numeric App ID
     - `RELEASE_APP_PRIVATE_KEY`: full PEM contents of the downloaded `.pem` key
2. **Environment 2: `release`**
   - **Deployment protection rules:** Check **Required reviewers** and add yourself (`chriscz`). Every APK signing run will pause and wait for your explicit approval in GitHub UI.
   - **Deployment branches and tags:** Selected branches and tags -> add tag rule **`v*.*.*`** ONLY (not even `main`, never PRs).
   - **Environment secrets** (NEVER store these in Repository Secrets):
     - `ANDROID_KEYSTORE_BASE64`: single-line base64 of `lumen-release.p12`
     - `ANDROID_KEYSTORE_PASSWORD`: keystore password
     - `ANDROID_KEY_ALIAS`: `lumen`
     - `ANDROID_KEY_PASSWORD`: key password (same as keystore password for PKCS12)

### C. Configure Repository Rulesets

Go to **Settings > Rules > Rulesets**:

1. **Branch ruleset (`protect-main`):**
   - Target: default branch (`main`).
   - Enable: Require a pull request before merging, Restrict deletions, Block force pushes, Require status checks (`ci / test-and-build`).
   - **Bypass list:** Add your **`chriscz-lumen-release-bot` GitHub App** (and optionally Repository admin).
2. **Tag ruleset (`protect-release-tags`):**
   - Target: `refs/tags/v*.*.*`.
   - Enable: Restrict creations, Restrict updates, Restrict deletions.
   - **Bypass list:** Add **`chriscz-lumen-release-bot` GitHub App** and Repository admin (`chriscz`). No other workflow or contributor can forge a `v*.*.*` tag.

### D. Harden GitHub Actions General Settings

Go to **Settings > Actions > General**:

- **Workflow permissions:** Select **Read repository contents and packages permissions** (least privilege by default).
- **Fork pull request workflows from outside collaborators:** Select **Require approval for all outside collaborators**.

---

## 5. Publishing a Release

Two pure GitHub-native paths are supported (`.github/workflows/release.yml`):

### Option A: One-Click from GitHub UI (Recommended)

No manual changelog edits required: `scripts/prepare_release.sh` automatically computes the next semantic version from Conventional Commits since the last `v*.*.*` tag (breaking `!` bumps major on `>=1.0` or minor on `0.x`; `feat` bumps minor; `fix`/`perf` bumps patch) and generates the grouped `CHANGELOG.md` and Fastlane notes.

1. Open **Actions > release > Run workflow** on `main`.
2. Leave **version** as `auto` (or enter an explicit version such as `1.0.0`) and click **Run workflow**.
3. `prepare` runs in the `release-bot` environment, updates `pubspec.yaml` (+`versionCode`), `CHANGELOG.md`, and `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`, pushes `chore(release): prepare vX.Y.Z` to `main`, and pushes tag `vX.Y.Z` using the GitHub App token.
4. That tag push automatically triggers a second `release` workflow run on `vX.Y.Z`, which pauses at your **`release` environment** approval gate.
5. Click **Review deployments > Approve and deploy**. `build-and-sign` verifies the tag, runs all script and Flutter tests (100% coverage gate), builds and `apksigner`-verifies signed `arm64-v8a`, `armeabi-v7a`, `x86_64`, and `universal` APKs + `SHA256SUMS.txt`, attaches SLSA provenance attestations, and `publish` creates a **draft GitHub Release**.
6. Inspect the draft release and click **Publish release**.

### Option B: Local Prep + Tag Push

```sh
bash scripts/prepare_release.sh --version auto --debug
VER="$(sed -n 's/^version:[[:space:]]*\([^[:space:]+#]*\).*/\1/p' pubspec.yaml | head -n 1)"
git add pubspec.yaml CHANGELOG.md fastlane/
git commit -m "chore(release): prepare v${VER}" \
  -m "Assisted-by-AI-model: none" \
  -m "Assisted-by-AI-harness: none"
git push origin main
git tag -a "v${VER}" -m "Release v${VER}"
git push origin "v${VER}"
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
- **Fastlane metadata:** `fastlane/metadata/android/en-US/` holds title, descriptions, icon, screenshots, and per-`versionCode` changelogs (automatically kept in sync by `scripts/prepare_release.sh`).
- **Pinned toolchain:** Exact Flutter version (`3.47.7`), `pubspec.lock`, and Gradle wrapper are committed.

### Why Reproducible Builds Matter

By default, F-Droid builds from source and signs the APK with **F-Droid's own key**, which would prevent users from switching between Obtainium (signed with your key) and F-Droid without reinstalling.

When F-Droid's metadata recipe sets `Binaries: https://github.com/chriscz/lumen/releases/download/v%v/lumen-v%v-universal.apk` (see [packaging/fdroid/dev.chriscz.lumen.yml](../packaging/fdroid/dev.chriscz.lumen.yml)), F-Droid compiles from your git tag and compares the unsigned APK contents byte-for-byte against your GitHub Release APK. When they match, F-Droid publishes your **developer-signed APK**, so Obtainium and F-Droid share the exact same signing key.

### Submission Steps

1. Publish your first signed GitHub Release (e.g. `v0.1.0`).
2. Test reproducibility locally against `fdroidserver` (or open an [RFP issue](https://gitlab.com/fdroid/rfp/-/issues) / merge request on [`fdroid/fdroiddata`](https://gitlab.com/fdroid/fdroiddata)) using `packaging/fdroid/dev.chriscz.lumen.yml` as the starting recipe (`metadata/dev.chriscz.lumen.yml`).
3. If `diffoscope` reports any non-reproducible native build IDs from Flutter/JNI plugins, check F-Droid's Flutter build recipes for any needed Gradle or CMake flags and update `packaging/fdroid/dev.chriscz.lumen.yml`.
