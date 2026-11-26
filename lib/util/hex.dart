// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// [bytes] as two hex digits each, joined by [separator].
String hex(List<int> bytes, {String separator = ' ', bool upper = false}) {
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(separator);
  return upper ? s.toUpperCase() : s;
}
