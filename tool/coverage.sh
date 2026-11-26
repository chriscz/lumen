#!/usr/bin/env bash
# Copyright (c) 2026 Chris Coetzee
# SPDX-License-Identifier: MIT
# The full license text is in LICENSE at the repository root.
#
# Runs every test with coverage and checks it against every file in lib/.
#   tool/coverage.sh            # whole suite, fails below 100%
#   tool/coverage.sh test/ble   # only these tests; prints the report
set -euo pipefail
cd "$(dirname "$0")/.."
out="coverage/lcov.info"
if [ "$#" -gt 0 ]; then
  out="coverage/partial-$$.info"
  flutter test --coverage --coverage-path "$out" "$@"
  dart run tool/check_coverage.dart "$out" --min 0
  rm -f "$out"
else
  flutter test --coverage --coverage-path "$out"
  dart run tool/check_coverage.dart "$out"
fi
