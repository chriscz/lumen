#!/usr/bin/env bash
# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.
#
# Pure-bash test suite for scripts/prepare_release.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/prepare_release.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

fail_msg() {
  printf '  FAIL: %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "${expected}" != "${actual}" ]; then
    fail_msg "${label}: expected [${expected}], got [${actual}]"
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! printf '%s' "${haystack}" | grep -Fq -- "${needle}"; then
    fail_msg "${label}: expected output to contain [${needle}]"
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if printf '%s' "${haystack}" | grep -Fq -- "${needle}"; then
    fail_msg "${label}: expected output NOT to contain [${needle}]"
    return 1
  fi
}

make_repo() {
  local dir="$1" version="${2:-0.1.0+1}"
  mkdir -p "${dir}/fastlane/metadata/android/en-US/changelogs"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.name "Chris Coetzee"
  git -C "${dir}" config user.email "chriscz93@gmail.com"
  cat > "${dir}/pubspec.yaml" <<EOF
name: lumen
description: "Philips Hue light controller"
version: ${version}
EOF
  cat > "${dir}/CHANGELOG.md" <<'EOF'
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

[Unreleased]: https://github.com/chriscz/lumen/compare/HEAD...HEAD
EOF
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "feat(lumen): initial standalone Lumen app"
}

commit_change() {
  local dir="$1" file="$2" content="$3" msg="$4"
  printf '%s\n' "${content}" > "${dir}/${file}"
  git -C "${dir}" add "${file}"
  git -C "${dir}" commit -q -m "${msg}"
}

run_test() {
  local name="$1" fn="$2"
  printf '==> %s\n' "${name}"
  if "${fn}"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

test_help_flag() {
  local out
  out="$(bash "${SCRIPT}" --help)"
  assert_contains "${out}" "Usage:" "help prints usage"
  assert_contains "${out}" "--version" "help lists --version"
  assert_contains "${out}" "--dry-run" "help lists --dry-run"
}

test_first_release_auto() {
  local dir="${TMP_ROOT}/first"
  make_repo "${dir}" "0.1.0+1"
  commit_change "${dir}" "a.txt" "1" "fix(ble): retry GATT error 133"
  commit_change "${dir}" "b.txt" "2" "perf(music): draw trace from fixed buffers"

  local next
  next="$(bash "${SCRIPT}" --root "${dir}" --next-version)"
  assert_eq "0.1.0" "${next}" "first release uses pubspec version"

  bash "${SCRIPT}" --root "${dir}" --version auto --date 2026-11-26 --debug >/dev/null 2>&1

  local pub cl fl
  pub="$(cat "${dir}/pubspec.yaml")"
  cl="$(cat "${dir}/CHANGELOG.md")"
  fl="$(cat "${dir}/fastlane/metadata/android/en-US/changelogs/1.txt")"

  assert_contains "${pub}" "version: 0.1.0+1" "first release keeps +1"
  assert_contains "${cl}" "## [0.1.0] - 2026-11-26" "changelog heading"
  assert_contains "${cl}" "### Features" "features section"
  assert_contains "${cl}" "**lumen:** initial standalone Lumen app" "feat bullet"
  assert_contains "${cl}" "### Bug Fixes" "bug fixes section"
  assert_contains "${cl}" "**ble:** retry GATT error 133" "fix bullet"
  assert_contains "${cl}" "### Performance" "perf section"
  assert_contains "${cl}" "**music:** draw trace from fixed buffers" "perf bullet"
  assert_contains "${cl}" "[Unreleased]: https://github.com/chriscz/lumen/compare/v0.1.0...HEAD" "unreleased link"
  assert_contains "${cl}" "[0.1.0]: https://github.com/chriscz/lumen/releases/tag/v0.1.0" "v0.1.0 link"
  assert_contains "${fl}" "initial standalone Lumen app" "fastlane changelog written"
}

test_patch_minor_major_bumps() {
  local dir="${TMP_ROOT}/bumps"
  make_repo "${dir}" "0.1.0+1"
  bash "${SCRIPT}" --root "${dir}" --version auto --date 2026-11-26 >/dev/null
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "chore(release): prepare v0.1.0"
  git -C "${dir}" tag -a v0.1.0 -m "Release v0.1.0"

  # 1. Fix commit -> patch bump (0.1.1+2)
  commit_change "${dir}" "f1.txt" "1" "fix(bridge): keep removed lights out"
  assert_eq "0.1.1" "$(bash "${SCRIPT}" --root "${dir}" --next-version)" "patch bump"
  bash "${SCRIPT}" --root "${dir}" --version auto --date 2026-11-27 >/dev/null
  assert_contains "$(cat "${dir}/pubspec.yaml")" "version: 0.1.1+2" "pubspec 0.1.1+2"
  assert_contains "$(cat "${dir}/CHANGELOG.md")" "[0.1.1]: https://github.com/chriscz/lumen/compare/v0.1.0...v0.1.1" "compare link"
  assert_not_contains "$(cat "${dir}/CHANGELOG.md")" "prepare v0.1.0" "ignores release prep commit"
  test -f "${dir}/fastlane/metadata/android/en-US/changelogs/2.txt"

  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "chore(release): prepare v0.1.1"
  git -C "${dir}" tag -a v0.1.1 -m "Release v0.1.1"

  # 2. Feat commit -> minor bump (0.2.0+3)
  commit_change "${dir}" "f2.txt" "2" "feat(music): add beat follow mode"
  assert_eq "0.2.0" "$(bash "${SCRIPT}" --root "${dir}" --next-version)" "minor bump"
  bash "${SCRIPT}" --root "${dir}" --version auto --date 2026-11-28 >/dev/null
  assert_contains "$(cat "${dir}/pubspec.yaml")" "version: 0.2.0+3" "pubspec 0.2.0+3"
  test -f "${dir}/fastlane/metadata/android/en-US/changelogs/3.txt"

  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "chore(release): prepare v0.2.0"
  git -C "${dir}" tag -a v0.2.0 -m "Release v0.2.0"

  # 3. Breaking commit on 0.x -> minor bump (0.3.0+4) + Breaking Changes section
  commit_change "${dir}" "f3.txt" "3" "feat(api)!: change plugin route schema"
  assert_eq "0.3.0" "$(bash "${SCRIPT}" --root "${dir}" --next-version)" "0.x breaking bumps minor"
  bash "${SCRIPT}" --root "${dir}" --version auto --date 2026-11-29 >/dev/null
  assert_contains "$(cat "${dir}/CHANGELOG.md")" "### Breaking Changes" "breaking section"
  assert_contains "$(cat "${dir}/CHANGELOG.md")" "**api:** change plugin route schema" "breaking bullet"

  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "chore(release): prepare v0.3.0"
  git -C "${dir}" tag -a v0.3.0 -m "Release v0.3.0"

  # 4. Explicit major 1.0.0, then breaking on 1.x -> 2.0.0
  commit_change "${dir}" "f4.txt" "4" "docs: mark stable 1.0 release"
  bash "${SCRIPT}" --root "${dir}" --version 1.0.0 --date 2026-11-30 >/dev/null
  assert_contains "$(cat "${dir}/pubspec.yaml")" "version: 1.0.0+5" "explicit 1.0.0+5"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "chore(release): prepare v1.0.0"
  git -C "${dir}" tag -a v1.0.0 -m "Release v1.0.0"

  commit_change "${dir}" "f5.txt" "5" "feat!: drop legacy protocol"
  assert_eq "2.0.0" "$(bash "${SCRIPT}" --root "${dir}" --next-version)" "1.x breaking bumps major"
}

test_no_releasable_commits_fails_auto() {
  local dir="${TMP_ROOT}/noop"
  make_repo "${dir}" "0.1.0+1"
  git -C "${dir}" tag -a v0.1.0 -m "Release v0.1.0"
  commit_change "${dir}" "docs.txt" "x" "chore(ci): tweak cache key"

  if bash "${SCRIPT}" --root "${dir}" --next-version >/dev/null 2>&1; then
    fail_msg "expected --next-version to fail when only chore commits exist since last tag"
    return 1
  fi
}

test_dry_run_and_read_helpers() {
  local dir="${TMP_ROOT}/helpers"
  make_repo "${dir}" "0.1.0+1"
  local before_pub before_cl
  before_pub="$(cat "${dir}/pubspec.yaml")"
  before_cl="$(cat "${dir}/CHANGELOG.md")"

  bash "${SCRIPT}" --root "${dir}" --version 0.2.0 --date 2026-11-26 --dry-run >/dev/null 2>&1
  assert_eq "${before_pub}" "$(cat "${dir}/pubspec.yaml")" "dry-run leaves pubspec untouched"
  assert_eq "${before_cl}" "$(cat "${dir}/CHANGELOG.md")" "dry-run leaves changelog untouched"

  bash "${SCRIPT}" --root "${dir}" --check-version 0.1.0 >/dev/null
  if bash "${SCRIPT}" --root "${dir}" --check-version 9.9.9 >/dev/null 2>&1; then
    fail_msg "expected --check-version mismatch to exit non-zero"
    return 1
  fi
  assert_eq "1" "$(bash "${SCRIPT}" --root "${dir}" --read-version-code)" "read-version-code"

  bash "${SCRIPT}" --root "${dir}" --version 0.1.0 --date 2026-11-26 >/dev/null
  local out_file="${TMP_ROOT}/notes.md"
  bash "${SCRIPT}" --root "${dir}" --extract-notes 0.1.0 --out "${out_file}"
  assert_contains "$(cat "${out_file}")" "initial standalone Lumen app" "extract-notes wrote notes"
}

test_preserves_unreleased_manual_notes_and_truncates_fastlane() {
  local dir="${TMP_ROOT}/manual"
  make_repo "${dir}" "0.1.0+1"
  cat > "${dir}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added
- Hand-written highlight kept during release.

[Unreleased]: https://github.com/chriscz/lumen/compare/HEAD...HEAD
EOF
  local i
  for i in $(seq 1 15); do
    commit_change "${dir}" "file_${i}.txt" "${i}" "feat(ui): add very descriptive feature number ${i} for light tiles"
  done

  bash "${SCRIPT}" --root "${dir}" --version 0.1.0 --date 2026-11-26 >/dev/null
  local cl fl fl_len
  cl="$(cat "${dir}/CHANGELOG.md")"
  fl="$(cat "${dir}/fastlane/metadata/android/en-US/changelogs/1.txt")"
  fl_len="${#fl}"

  assert_contains "${cl}" "Hand-written highlight kept during release." "keeps manual unreleased notes"
  assert_contains "${cl}" "add very descriptive feature number 15" "includes generated commit notes"
  if [ "${fl_len}" -gt 500 ]; then
    fail_msg "fastlane changelog exceeded 500 chars (${fl_len})"
    return 1
  fi
  assert_not_contains "${cl}" $'\xe2\x80\x94' "no em-dashes in changelog"
}

run_test "help flag" test_help_flag
run_test "first release auto-generates changelog and fastlane" test_first_release_auto
run_test "patch, minor, breaking, and explicit major bumps" test_patch_minor_major_bumps
run_test "fails cleanly in auto mode when no releasable commits exist" test_no_releasable_commits_fails_auto
run_test "dry-run, check-version, read-version-code, extract-notes" test_dry_run_and_read_helpers
run_test "preserves manual unreleased notes and truncates fastlane to 500 chars" test_preserves_unreleased_manual_notes_and_truncates_fastlane

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
