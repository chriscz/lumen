#!/usr/bin/env bash
# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.
#
# Prepares a fresh Claude Code cloud container (Ubuntu 24.04, root) to build
# and test the Flutter app in this repository. Every step checks whether
# it is already done and skips it, so a re-run takes a few seconds.
#
# Usage: bash tool/setup_cloud_env.sh
# Set SKIP_PRECACHE=1 to skip pre-warming the Flutter engine artifacts.
#
# Gradle may hit HTTP 429 from Maven Central on the first Android build. That
# build is not part of this script; retry it later if it happens.

set -euo pipefail

FLUTTER_VERSION="3.47.7"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_SHA256="af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230"
FLUTTER_HOME="/opt/flutter"

ANDROID_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip"
ANDROID_HOME="/opt/android-sdk"
ANDROID_PACKAGES=("platform-tools" "platforms;android-36" "build-tools;36.0.0")

APT_PACKAGES=(libgtk-3-dev liblzma-dev libstdc++-12-dev xz-utils xvfb clang
  cmake ninja-build pkg-config unzip curl)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[setup] %s\n' "$*"; }

export ANDROID_HOME ANDROID_SDK_ROOT="${ANDROID_HOME}"
export PATH="${FLUTTER_HOME}/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin:${PATH}"

install_apt_packages() {
  local missing=() pkg
  for pkg in "${APT_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("${pkg}")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log "apt packages: already installed"
    return
  fi
  log "apt packages: installing ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends "${missing[@]}"
}

flutter_installed_version() {
  local json="${FLUTTER_HOME}/bin/cache/flutter.version.json"
  if [ -f "${json}" ]; then
    sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' "${json}" | head -n 1
  elif [ -f "${FLUTTER_HOME}/version" ]; then
    head -n 1 "${FLUTTER_HOME}/version"
  fi
}

install_flutter() {
  if [ -x "${FLUTTER_HOME}/bin/flutter" ] && [ "$(flutter_installed_version)" = "${FLUTTER_VERSION}" ]; then
    log "flutter ${FLUTTER_VERSION}: already installed"
  else
    if [ -e "${FLUTTER_HOME}" ]; then
      log "flutter: replacing existing ${FLUTTER_HOME} ($(flutter_installed_version || true))"
      rm -rf "${FLUTTER_HOME}"
    fi
    log "flutter ${FLUTTER_VERSION}: downloading"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "${tmp}/flutter.tar.xz" "${FLUTTER_URL}"
    echo "${FLUTTER_SHA256}  ${tmp}/flutter.tar.xz" | sha256sum -c --quiet -
    tar -xJf "${tmp}/flutter.tar.xz" -C "$(dirname "${FLUTTER_HOME}")"
    rm -rf "${tmp}"
  fi

  if ! git config --global --get-all safe.directory 2>/dev/null | grep -qx "${FLUTTER_HOME}"; then
    log "git: marking ${FLUTTER_HOME} as a safe directory"
    git config --global --add safe.directory "${FLUTTER_HOME}"
  fi

  # When Flutter detects a bot environment it accepts --disable-analytics
  # without touching the telemetry config, so a stamp file records the step.
  local analytics_stamp="${HOME}/.config/flutter/.analytics-disabled"
  if [ -f "${analytics_stamp}" ] \
    || grep -qx 'reporting=0' "${HOME}/.dart-tool/dart-flutter-telemetry.config" 2>/dev/null; then
    log "flutter: analytics already disabled"
  else
    log "flutter: disabling analytics"
    flutter --disable-analytics >/dev/null 2>&1
    mkdir -p "$(dirname "${analytics_stamp}")"
    touch "${analytics_stamp}"
  fi

  if ! grep -q '"enable-linux-desktop": *true' "${HOME}/.config/flutter/settings" 2>/dev/null; then
    log "flutter: enabling linux desktop"
    flutter config --enable-linux-desktop >/dev/null 2>&1
  fi
}

install_android_sdk() {
  local sdkmanager="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
  if [ -x "${sdkmanager}" ]; then
    log "android cmdline-tools: already installed"
  else
    log "android cmdline-tools: downloading"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "${tmp}/cmdline-tools.zip" "${ANDROID_TOOLS_URL}"
    unzip -q "${tmp}/cmdline-tools.zip" -d "${tmp}"
    mkdir -p "${ANDROID_HOME}/cmdline-tools"
    rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
    mv "${tmp}/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
    rm -rf "${tmp}"
  fi

  if [ -f "${ANDROID_HOME}/licenses/android-sdk-license" ]; then
    log "android licenses: already accepted"
  else
    log "android licenses: accepting"
    { yes || true; } | "${sdkmanager}" --sdk_root="${ANDROID_HOME}" --licenses >/dev/null
  fi

  local missing=() pkg
  for pkg in "${ANDROID_PACKAGES[@]}"; do
    if [ ! -d "${ANDROID_HOME}/${pkg//;//}" ]; then
      missing+=("${pkg}")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log "android packages: already installed"
  else
    log "android packages: installing ${missing[*]}"
    { yes || true; } | "${sdkmanager}" --sdk_root="${ANDROID_HOME}" "${missing[@]}" >/dev/null
  fi
}

write_env_files() {
  local content
  content="$(cat <<EOF
export ANDROID_HOME=${ANDROID_HOME}
export ANDROID_SDK_ROOT=${ANDROID_HOME}
export PATH=${FLUTTER_HOME}/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin:\$PATH
EOF
)"
  local file
  for file in /etc/profile.d/hue-flutter.sh /root/.hue_env; do
    if [ -f "${file}" ] && [ "$(cat "${file}")" = "${content}" ]; then
      log "env: ${file} up to date"
    else
      log "env: writing ${file}"
      printf '%s\n' "${content}" > "${file}"
    fi
  done
}

pub_get() {
  local config="${APP_DIR}/.dart_tool/package_config.json"
  if [ -f "${config}" ] && [ "${config}" -nt "${APP_DIR}/pubspec.yaml" ] \
    && [ "${config}" -nt "${APP_DIR}/pubspec.lock" ]; then
    log "flutter pub get: dependencies up to date"
  else
    log "flutter pub get: resolving dependencies"
    (cd "${APP_DIR}" && flutter pub get)
  fi
}

precache() {
  if [ "${SKIP_PRECACHE:-0}" = "1" ]; then
    log "flutter precache: skipped (SKIP_PRECACHE=1)"
    return
  fi
  local cache="${FLUTTER_HOME}/bin/cache"
  if [ -f "${cache}/linux-sdk.stamp" ] && [ -f "${cache}/android-sdk.stamp" ] \
    && [ -d "${cache}/artifacts/engine/linux-x64" ] \
    && [ -d "${cache}/artifacts/engine/android-arm64-release" ]; then
    log "flutter precache: linux and android artifacts already cached"
  else
    log "flutter precache: downloading linux and android artifacts"
    flutter precache --linux --android
  fi
}

print_summary() {
  cat <<EOF

Setup complete. In a new shell, run: source /root/.hue_env
Then, from ${APP_DIR}:
  flutter test
  xvfb-run -a flutter test integration_test/<file> -d linux
  flutter build apk --release
EOF
}

install_apt_packages
install_flutter
install_android_sdk
write_env_files
pub_get
precache
print_summary
