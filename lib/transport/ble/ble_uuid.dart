// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// Bluetooth UUIDs in one comparable form. Platforms report them in upper
/// or lower case, and Apple and some Android stacks use the 16-bit short
/// form ("FE0F") for assigned numbers.
abstract final class BleUuid {
  /// The Bluetooth base UUID after the first 32 bits.
  static const _base = '-0000-1000-8000-00805f9b34fb';

  static final _short = RegExp(r'^[0-9a-f]{4}$|^[0-9a-f]{8}$');

  /// [uuid] as a full 128-bit UUID in lower case: a 16- or 32-bit short
  /// form is expanded onto the base UUID, braces and space are dropped.
  static String normalize(String uuid) {
    final u = uuid.trim().toLowerCase().replaceAll(RegExp(r'[{}]'), '');
    return _short.hasMatch(u) ? '${u.padLeft(8, '0')}$_base' : u;
  }

  /// Whether [a] and [b] name the same UUID, in whatever form.
  static bool same(String a, String b) => normalize(a) == normalize(b);
}
