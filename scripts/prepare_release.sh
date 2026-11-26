#!/usr/bin/env bash
# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.
#
# Pure-bash release automation helper for Lumen (Conventional Commits ->
# automatic semantic version bump, CHANGELOG.md generation, pubspec.yaml
# +versionCode bump, and F-Droid Fastlane release notes).

set -euo pipefail

REPO_SLUG="chriscz/lumen"
FASTLANE_MAX_CHARS=500
FASTLANE_CHANGELOG_DIR="fastlane/metadata/android/en-US/changelogs"

MODE=""
VERSION_ARG=""
OUT_FILE=""
DATE_STR="$(date +%Y-%m-%d)"
ROOT_DIR="${PWD}"
DRY_RUN=0
DEBUG=0

usage() {
  cat <<'EOF'
Usage: bash scripts/prepare_release.sh [options]

Modes (pick one):
  --version auto|VER   Bump pubspec.yaml (+versionCode), auto-generate
                       CHANGELOG.md from Conventional Commits since the last
                       v*.*.* tag, and write Fastlane changelog notes.
                       With 'auto': first release uses pubspec.yaml version;
                       thereafter breaking (!) bumps major (>=1.0) or minor
                       (0.x), feat bumps minor, and fix/perf bumps patch.
  --next-version       Print the computed next semantic version (auto) and exit
  --check-version VER  Verify pubspec.yaml matches VER (exit 1 on mismatch)
  --read-version-code  Print integer Android versionCode (+N) from pubspec.yaml
  --extract-notes VER  Print CHANGELOG.md notes for VER (or write to --out)

Options:
  --out FILE           Output path for --extract-notes
  --date YYYY-MM-DD    Release date for CHANGELOG.md (default: today)
  --root DIR           Repository root (default: current directory)
  --dry-run            Show planned file updates without modifying files
  --debug              Print actions to stderr prefixed with +
  -h, --help           Show this help
EOF
}

dbg() {
  if [ "${DEBUG}" -eq 1 ]; then
    printf '+ %s\n' "$*" >&2
  fi
}

valid_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

read_pubspec_fields() {
  local pubspec="$1"
  local line
  line="$(grep -E '^version:[[:space:]]*[^[:space:]+#]+(\+[0-9]+)?[[:space:]]*$' "${pubspec}" | head -n 1 || true)"
  if [ -z "${line}" ]; then
    printf 'Error: could not find version: line in %s\n' "${pubspec}" >&2
    return 1
  fi
  local raw="${line#version:}"
  raw="$(printf '%s' "${raw}" | tr -d '[:space:]')"
  PUB_VER="${raw%%+*}"
  if [[ "${raw}" == *"+"* ]]; then
    PUB_BUILD="${raw#*+}"
  else
    PUB_BUILD=""
  fi
}

latest_version_tag() {
  git -C "${ROOT_DIR}" tag --list 'v*.*.*' --sort=-v:refname 2>/dev/null | head -n 1 || true
}

# Scans commits since LAST_TAG (or all commits if none) and populates:
#   HAS_BREAKING, HAS_FEAT, HAS_FIX, HAS_PERF
#   GENERATED_NOTES (markdown sections grouped by Conventional Commit type)
analyze_commits() {
  local last_tag="$1"
  local range="HEAD"
  if [ -n "${last_tag}" ]; then
    range="${last_tag}..HEAD"
  fi
  dbg "git -C ${ROOT_DIR} log ${range}"

  HAS_BREAKING=0
  HAS_FEAT=0
  HAS_FIX=0
  HAS_PERF=0

  local sec_breaking="" sec_feat="" sec_fix="" sec_perf="" sec_other=""
  local record sha subject body type scope bang desc bullet

  while IFS= read -r -d $'\x1e' record; do
    # Strip leading/trailing newlines introduced by git log between records
    record="${record#$'\n'}"
    [ -z "${record}" ] && continue

    sha="${record%%$'\x1f'*}"
    local rest="${record#*$'\x1f'}"
    subject="${rest%%$'\x1f'*}"
    body="${rest#*$'\x1f'}"

    # Ignore automated release prep commits
    if [[ "${subject}" =~ ^chore\(release\): ]]; then
      continue
    fi

    type=""
    scope=""
    bang=""
    desc="${subject}"
    if [[ "${subject}" =~ ^([a-z]+)(\(([a-zA-Z0-9._/-]+)\))?(!)?:[[:space:]]+(.+)$ ]]; then
      type="${BASH_REMATCH[1]}"
      scope="${BASH_REMATCH[3]}"
      bang="${BASH_REMATCH[4]}"
      desc="${BASH_REMATCH[5]}"
    fi

    if [ -n "${scope}" ]; then
      bullet="- **${scope}:** ${desc} (\`${sha}\`)"
    else
      bullet="- ${desc} (\`${sha}\`)"
    fi

    local is_breaking=0
    if [ -n "${bang}" ] || printf '%s' "${body}" | grep -Eq '^(BREAKING CHANGE|BREAKING-CHANGE):'; then
      is_breaking=1
      HAS_BREAKING=1
      sec_breaking+="${bullet}"$'\n'
    fi

    case "${type}" in
      feat)
        HAS_FEAT=1
        if [ "${is_breaking}" -eq 0 ]; then
          sec_feat+="${bullet}"$'\n'
        fi
        ;;
      fix)
        HAS_FIX=1
        if [ "${is_breaking}" -eq 0 ]; then
          sec_fix+="${bullet}"$'\n'
        fi
        ;;
      perf)
        HAS_PERF=1
        if [ "${is_breaking}" -eq 0 ]; then
          sec_perf+="${bullet}"$'\n'
        fi
        ;;
      *)
        if [ "${is_breaking}" -eq 0 ]; then
          sec_other+="${bullet}"$'\n'
        fi
        ;;
    esac
  done < <(git -C "${ROOT_DIR}" log "${range}" --format='%h%x1f%s%x1f%b%x1e' 2>/dev/null || true)

  GENERATED_NOTES=""
  if [ -n "${sec_breaking}" ]; then
    GENERATED_NOTES+="### Breaking Changes"$'\n\n'"${sec_breaking}"$'\n'
  fi
  if [ -n "${sec_feat}" ]; then
    GENERATED_NOTES+="### Features"$'\n\n'"${sec_feat}"$'\n'
  fi
  if [ -n "${sec_fix}" ]; then
    GENERATED_NOTES+="### Bug Fixes"$'\n\n'"${sec_fix}"$'\n'
  fi
  if [ -n "${sec_perf}" ]; then
    GENERATED_NOTES+="### Performance"$'\n\n'"${sec_perf}"$'\n'
  fi
  if [ -z "${GENERATED_NOTES}" ] && [ -n "${sec_other}" ]; then
    GENERATED_NOTES+="### Maintenance"$'\n\n'"${sec_other}"$'\n'
  fi
}

compute_auto_version() {
  local last_tag="$1"
  if [ -z "${last_tag}" ]; then
    printf '%s\n' "${PUB_VER}"
    return 0
  fi

  local base="${last_tag#v}"
  local core="${base%%-*}"
  local major minor patch
  IFS='.' read -r major minor patch <<< "${core}"

  if [ "${HAS_BREAKING}" -eq 1 ]; then
    if [ "${major}" -ge 1 ]; then
      printf '%d.0.0\n' "$((major + 1))"
    else
      printf '0.%d.0\n' "$((minor + 1))"
    fi
  elif [ "${HAS_FEAT}" -eq 1 ]; then
    printf '%d.%d.0\n' "${major}" "$((minor + 1))"
  elif [ "${HAS_FIX}" -eq 1 ] || [ "${HAS_PERF}" -eq 1 ]; then
    printf '%d.%d.%d\n' "${major}" "${minor}" "$((patch + 1))"
  else
    printf 'Error: no releasable commits (feat, fix, perf, or breaking) since %s; pass --version X.Y.Z explicitly to force.\n' "${last_tag}" >&2
    return 1
  fi
}

extract_changelog_section() {
  local changelog_file="$1" ver="$2"
  awk -v ver="${ver}" '
    BEGIN { found = 0; body = "" }
    $0 ~ "^## \\[" ver "\\]([[:space:]]+-.*)?[[:space:]]*$" { found = 1; next }
    found {
      if ($0 ~ "^## \\[" || $0 ~ "^\\[[^\\]]+\\]:[[:space:]]+https?://") {
        exit
      }
      body = body $0 "\n"
    }
    END {
      if (!found) exit 1
      gsub(/^[[:space:]]+/, "", body)
      gsub(/[[:space:]]+$/, "", body)
      if (length(body) == 0) exit 1
      print body
    }
  ' "${changelog_file}"
}

format_fastlane_notes() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s\n' "${raw}" | awk '
    /^#+[[:space:]]+/ { next }
    {
      gsub(/\*\*/, "")
      gsub(/`/, "")
      while (match($0, /\[[^\]]+\]\([^)]+\)/)) {
        m = substr($0, RSTART, RLENGTH)
        sub(/^\[/, "", m)
        sub(/\]\([^)]+\)$/, "", m)
        $0 = substr($0, 1, RSTART - 1) m substr($0, RSTART + RLENGTH)
      }
      print
    }
  ' | awk 'NF { blank=0; print; next } !blank { blank=1; print }')"

  # Trim leading/trailing blank lines
  cleaned="$(printf '%s' "${cleaned}" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed '/./,$!d')"
  [ -z "${cleaned}" ] && return 0

  if [ "$(( ${#cleaned} + 1 ))" -le "${FASTLANE_MAX_CHARS}" ]; then
    printf '%s\n' "${cleaned}"
  else
    local cut_len=$(( FASTLANE_MAX_CHARS - 5 ))
    local truncated="${cleaned:0:${cut_len}}"
    truncated="$(printf '%s' "${truncated}" | sed 's/[[:space:]]*$//')"
    printf '%s...\n' "${truncated}"
  fi
}

roll_changelog_file() {
  local changelog_file="$1" new_ver="$2" date_str="$3" gen_notes="$4" out_file="$5"

  if extract_changelog_section "${changelog_file}" "${new_ver}" >/dev/null 2>&1; then
    cp "${changelog_file}" "${out_file}"
    return 0
  fi

  if ! grep -Eq '^## \[Unreleased\][[:space:]]*$' "${changelog_file}"; then
    printf 'Error: %s is missing "## [Unreleased]" heading\n' "${changelog_file}" >&2
    return 1
  fi

  local prev_ver
  prev_ver="$(awk '
    /^## \[[0-9]+\.[0-9]+\.[0-9]+/ {
      s = $0
      sub(/^## \[/, "", s)
      sub(/\].*$/, "", s)
      print s
      exit
    }
  ' "${changelog_file}")"

  local unreleased_link="[Unreleased]: https://github.com/${REPO_SLUG}/compare/v${new_ver}...HEAD"
  local version_link
  if [ -n "${prev_ver}" ]; then
    version_link="[${new_ver}]: https://github.com/${REPO_SLUG}/compare/v${prev_ver}...v${new_ver}"
  else
    version_link="[${new_ver}]: https://github.com/${REPO_SLUG}/releases/tag/v${new_ver}"
  fi

  local notes_file
  notes_file="$(mktemp)"
  printf '%s' "${gen_notes}" > "${notes_file}"

  awk -v new_ver="${new_ver}" \
      -v date_str="${date_str}" \
      -v ulink="${unreleased_link}" \
      -v vlink="${version_link}" \
      -v notes_file="${notes_file}" '
    BEGIN {
      in_unreleased = 0
      inserted_notes = 0
      updated_links = 0
      gen = ""
      while ((getline line < notes_file) > 0) {
        gen = gen line "\n"
      }
      close(notes_file)
      gsub(/^[[:space:]]+/, "", gen)
      gsub(/[[:space:]]+$/, "", gen)
    }
    /^## \[Unreleased\][[:space:]]*$/ {
      print "## [Unreleased]"
      print ""
      print "## [" new_ver "] - " date_str
      in_unreleased = 1
      next
    }
    in_unreleased && (/^## \[/ || /^\[[^\]]+\]:[[:space:]]+https?:\/\//) {
      if (length(gen) > 0) {
        print ""
        print gen
      }
      print ""
      in_unreleased = 0
      inserted_notes = 1
    }
    /^\[Unreleased\]:[[:space:]]+https?:\/\// {
      print ulink
      print vlink
      updated_links = 1
      next
    }
    { print }
    END {
      if (in_unreleased && !inserted_notes && length(gen) > 0) {
        print ""
        print gen
      }
      if (!updated_links) {
        print ""
        print ulink
        print vlink
      }
    }
  ' "${changelog_file}" | awk '
    # Collapse 3+ consecutive blank lines to 1 blank line
    NF == 0 { blank++; if (blank <= 1) print; next }
    { blank = 0; print }
  ' > "${out_file}"

  rm -f "${notes_file}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      MODE="prepare"
      VERSION_ARG="${2#v}"
      shift 2
      ;;
    --next-version)
      MODE="next"
      shift
      ;;
    --check-version)
      MODE="check"
      VERSION_ARG="${2#v}"
      shift 2
      ;;
    --read-version-code)
      MODE="version_code"
      shift
      ;;
    --extract-notes)
      MODE="extract"
      VERSION_ARG="${2#v}"
      shift 2
      ;;
    --out)
      OUT_FILE="$2"
      shift 2
      ;;
    --date)
      DATE_STR="$2"
      shift 2
      ;;
    --root)
      ROOT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

if [ -z "${MODE}" ]; then
  usage >&2
  exit 2
fi

PUBSPEC_PATH="${ROOT_DIR}/pubspec.yaml"
CHANGELOG_PATH="${ROOT_DIR}/CHANGELOG.md"

read_pubspec_fields "${PUBSPEC_PATH}"

case "${MODE}" in
  version_code)
    if [ -z "${PUB_BUILD}" ]; then
      printf 'Error: pubspec.yaml version is missing +<versionCode>\n' >&2
      exit 1
    fi
    printf '%s\n' "${PUB_BUILD}"
    exit 0
    ;;

  check)
    if ! valid_semver "${VERSION_ARG}"; then
      printf 'Error: invalid semantic version: %s\n' "${VERSION_ARG}" >&2
      exit 2
    fi
    dbg "check pubspec.yaml version (${PUB_VER}) == ${VERSION_ARG}"
    if [ "${PUB_VER}" != "${VERSION_ARG}" ]; then
      printf 'Version mismatch: pubspec.yaml has %s, expected %s\n' "${PUB_VER}" "${VERSION_ARG}" >&2
      exit 1
    fi
    printf 'OK: pubspec.yaml version matches %s\n' "${VERSION_ARG}"
    exit 0
    ;;

  extract)
    if ! valid_semver "${VERSION_ARG}"; then
      printf 'Error: invalid semantic version: %s\n' "${VERSION_ARG}" >&2
      exit 2
    fi
    dbg "extract CHANGELOG.md section for ${VERSION_ARG}"
    if ! notes="$(extract_changelog_section "${CHANGELOG_PATH}" "${VERSION_ARG}")"; then
      printf 'No CHANGELOG.md entry found for %s\n' "${VERSION_ARG}" >&2
      exit 1
    fi
    if [ -n "${OUT_FILE}" ]; then
      printf '%s\n' "${notes}" > "${OUT_FILE}"
    else
      printf '%s\n' "${notes}"
    fi
    exit 0
    ;;

  next)
    LAST_TAG="$(latest_version_tag)"
    analyze_commits "${LAST_TAG}"
    compute_auto_version "${LAST_TAG}"
    exit 0
    ;;

  prepare)
    LAST_TAG="$(latest_version_tag)"
    analyze_commits "${LAST_TAG}"

    if [ "${VERSION_ARG}" = "auto" ]; then
      TARGET_VER="$(compute_auto_version "${LAST_TAG}")"
    else
      if ! valid_semver "${VERSION_ARG}"; then
        printf 'Error: invalid semantic version: %s\n' "${VERSION_ARG}" >&2
        exit 2
      fi
      TARGET_VER="${VERSION_ARG}"
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    NEW_PUBSPEC="${TMP_DIR}/pubspec.yaml"
    NEW_CHANGELOG="${TMP_DIR}/CHANGELOG.md"
    NEW_BUILD="${PUB_BUILD:-1}"

    if [ "${PUB_VER}" != "${TARGET_VER}" ]; then
      NEW_BUILD=$(( ${PUB_BUILD:-0} + 1 ))
      sed -E "s|^version:[[:space:]]*[^[:space:]+#]+(\+[0-9]+)?[[:space:]]*$|version: ${TARGET_VER}+${NEW_BUILD}|" \
        "${PUBSPEC_PATH}" > "${NEW_PUBSPEC}"
    else
      cp "${PUBSPEC_PATH}" "${NEW_PUBSPEC}"
    fi

    roll_changelog_file "${CHANGELOG_PATH}" "${TARGET_VER}" "${DATE_STR}" "${GENERATED_NOTES}" "${NEW_CHANGELOG}"

    CHANGED=()
    if ! cmp -s "${PUBSPEC_PATH}" "${NEW_PUBSPEC}"; then
      CHANGED+=("${PUBSPEC_PATH}")
    fi
    if ! cmp -s "${CHANGELOG_PATH}" "${NEW_CHANGELOG}"; then
      CHANGED+=("${CHANGELOG_PATH}")
    fi

    FL_PATH=""
    NEW_FL="${TMP_DIR}/fastlane.txt"
    FL_DIR="${ROOT_DIR}/${FASTLANE_CHANGELOG_DIR}"
    if [ -n "${NEW_BUILD}" ] && [ -d "${FL_DIR}" ]; then
      if ver_notes="$(extract_changelog_section "${NEW_CHANGELOG}" "${TARGET_VER}")"; then
        formatted="$(format_fastlane_notes "${ver_notes}")"
        if [ -n "${formatted}" ]; then
          FL_PATH="${FL_DIR}/${NEW_BUILD}.txt"
          printf '%s\n' "${formatted}" > "${NEW_FL}"
          if [ ! -f "${FL_PATH}" ] || ! cmp -s "${FL_PATH}" "${NEW_FL}"; then
            CHANGED+=("${FL_PATH}")
          fi
        fi
      fi
    fi

    if [ "${DEBUG}" -eq 1 ] || [ "${DRY_RUN}" -eq 1 ]; then
      if [ "${#CHANGED[@]}" -eq 0 ]; then
        printf '+ no changes needed for %s\n' "${TARGET_VER}" >&2
      else
        for p in "${CHANGED[@]}"; do
          printf '+ update %s for %s\n' "${p}" "${TARGET_VER}" >&2
        done
      fi
    fi

    if [ "${DRY_RUN}" -eq 0 ]; then
      if ! cmp -s "${PUBSPEC_PATH}" "${NEW_PUBSPEC}"; then
        cp "${NEW_PUBSPEC}" "${PUBSPEC_PATH}"
      fi
      if ! cmp -s "${CHANGELOG_PATH}" "${NEW_CHANGELOG}"; then
        cp "${NEW_CHANGELOG}" "${CHANGELOG_PATH}"
      fi
      if [ -n "${FL_PATH}" ] && [ -f "${NEW_FL}" ]; then
        if [ ! -f "${FL_PATH}" ] || ! cmp -s "${FL_PATH}" "${NEW_FL}"; then
          cp "${NEW_FL}" "${FL_PATH}"
        fi
      fi
    fi

    if [ "${#CHANGED[@]}" -eq 0 ]; then
      printf 'Already prepared for %s\n' "${TARGET_VER}"
    else
      printf 'Prepared release %s (%d files)\n' "${TARGET_VER}" "${#CHANGED[@]}"
    fi
    ;;
esac
