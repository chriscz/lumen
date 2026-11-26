#!/usr/bin/env bash
# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.
#
# Deterministic Android APK packager for Lumen (Obtainium and F-Droid friendly).
#
# Builds signed (or explicitly --unsigned) split-per-ABI APKs plus a universal
# APK, renames them with consistent versioned filenames, verifies APK signatures
# via apksigner, and emits SHA256SUMS.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION=""
OUT_DIR="${ROOT_DIR}/dist"
UNSIGNED=0
UNIVERSAL_ONLY=0
DEBUG=0

usage() {
  cat <<'EOF'
Usage: bash tool/package_android.sh [options]

Options:
  --version VER      Semantic version without leading v (default: read from pubspec.yaml)
  --out-dir DIR      Output directory for APKs and SHA256SUMS.txt (default: ./dist)
  --unsigned         Build unsigned release APKs (for PR CI smoke checks or F-Droid)
  --universal-only   Build only the universal APK (faster for CI smoke checks)
  --debug            Print underlying commands to stderr prefixed with +
  -h, --help         Show this help

Environment variables for signed builds (or provide gitignored android/key.properties):
  LUMEN_KEYSTORE_PATH
  LUMEN_KEYSTORE_PASSWORD
  LUMEN_KEY_ALIAS
  LUMEN_KEY_PASSWORD
EOF
}

run_cmd() {
  if [ "${DEBUG}" -eq 1 ]; then
    printf '+ %s\n' "$*" >&2
  fi
  "$@"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="${2#v}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --unsigned)
      UNSIGNED=1
      shift
      ;;
    --universal-only)
      UNIVERSAL_ONLY=1
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "${ROOT_DIR}"

if [ -z "${VERSION}" ]; then
  VERSION="$(sed -n 's/^version:[[:space:]]*\([^[:space:]+#]*\).*/\1/p' pubspec.yaml | head -n 1)"
fi
if [ -z "${VERSION}" ]; then
  printf 'Error: could not determine version from pubspec.yaml\n' >&2
  exit 1
fi

has_signing_env() {
  [ -n "${LUMEN_KEYSTORE_PATH:-}" ] \
    && [ -n "${LUMEN_KEYSTORE_PASSWORD:-}" ] \
    && [ -n "${LUMEN_KEY_ALIAS:-}" ] \
    && [ -n "${LUMEN_KEY_PASSWORD:-}" ]
}

if [ "${UNSIGNED}" -eq 0 ]; then
  if ! has_signing_env && [ ! -f "${ROOT_DIR}/android/key.properties" ]; then
    printf 'Error: release signing credentials are not configured.\n' >&2
    printf 'Set LUMEN_KEYSTORE_* env vars, create android/key.properties, or pass --unsigned.\n' >&2
    exit 1
  fi
else
  # Ensure unsigned mode never picks up ambient signing variables.
  unset LUMEN_KEYSTORE_PATH LUMEN_KEYSTORE_PASSWORD LUMEN_KEY_ALIAS LUMEN_KEY_PASSWORD
  if [ -f "${ROOT_DIR}/android/key.properties" ]; then
    printf 'Error: --unsigned cannot run while android/key.properties exists.\n' >&2
    exit 1
  fi
fi

find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return 0
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -n "${sdk}" ] && [ -d "${sdk}/build-tools" ]; then
    local candidate
    candidate="$(find "${sdk}/build-tools" -maxdepth 2 -type f -name apksigner 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi
  return 1
}

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}"/lumen-v*.apk "${OUT_DIR}/SHA256SUMS.txt"

APK_OUT="${ROOT_DIR}/build/app/outputs/flutter-apk"
BUILT_APKS=()

if [ "${UNIVERSAL_ONLY}" -eq 0 ]; then
  run_cmd flutter build apk --release --split-per-abi
  for abi in arm64-v8a armeabi-v7a x86_64; do
    src="${APK_OUT}/app-${abi}-release.apk"
    if [ ! -f "${src}" ]; then
      printf 'Error: expected split APK not found: %s\n' "${src}" >&2
      exit 1
    fi
    dst="${OUT_DIR}/lumen-v${VERSION}-${abi}.apk"
    run_cmd cp "${src}" "${dst}"
    BUILT_APKS+=("${dst}")
  done
fi

run_cmd flutter build apk --release
src_universal="${APK_OUT}/app-release.apk"
if [ ! -f "${src_universal}" ]; then
  printf 'Error: expected universal APK not found: %s\n' "${src_universal}" >&2
  exit 1
fi
dst_universal="${OUT_DIR}/lumen-v${VERSION}-universal.apk"
run_cmd cp "${src_universal}" "${dst_universal}"
BUILT_APKS+=("${dst_universal}")

if [ "${UNSIGNED}" -eq 0 ]; then
  APKSIGNER="$(find_apksigner || true)"
  if [ -z "${APKSIGNER}" ]; then
    printf 'Error: apksigner not found in PATH or ANDROID_HOME/build-tools.\n' >&2
    exit 1
  fi
  for apk in "${BUILT_APKS[@]}"; do
    printf 'Verifying signature: %s\n' "$(basename "${apk}")"
    run_cmd "${APKSIGNER}" verify --print-certs "${apk}"
  done
fi

(
  cd "${OUT_DIR}"
  # shellcheck disable=SC2046
  sha256sum $(for apk in "${BUILT_APKS[@]}"; do basename "${apk}"; done | LC_ALL=C sort) > SHA256SUMS.txt
)

printf 'Packaged %d APK(s) in %s:\n' "${#BUILT_APKS[@]}" "${OUT_DIR}"
cat "${OUT_DIR}/SHA256SUMS.txt"
