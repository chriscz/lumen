// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// Where a phone acting as a Hue Bridge listens, so a client on the same
/// network knows exactly where to look. Stock Android keeps apps off ports
/// below 1024, so the bridge takes the first free port of [lan].
abstract final class BridgePorts {
  /// 1818, 1919, 2020 and so on: ten ports, 101 apart.
  static final lan = List<int>.unmodifiable([for (var i = 0; i < 10; i++) 1818 + 101 * i]);

  /// The ports a client tries on a host: a real bridge's 80, then [lan].
  static final probe = List<int>.unmodifiable([80, ...lan]);
}
