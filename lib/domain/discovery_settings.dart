// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// The ways the app looks for Hue Bridges on the local network, in the
/// order it tries them: cheapest first.
enum DiscoveryStage {
  known('Known bridges'),
  mdns('mDNS'),
  ssdp('SSDP'),
  sweep('Network scan');

  const DiscoveryStage(this.label);

  final String label;
}

/// Who asks the network over mDNS: Android's own service discovery, or
/// Lumen's query.
enum MdnsImplementation {
  android('Android (system)', 'Android'),
  builtIn('Built-in', 'built-in');

  const MdnsImplementation(this.label, this.short);

  final String label;

  /// For the progress line, such as "mDNS, Android".
  final String short;
}

/// Which discovery methods are on, and the mDNS implementation the user
/// chose. Methods are on unless switched off, so new ones start on.
class DiscoverySettings {
  const DiscoverySettings({this.off = const {}, this.mdns});

  final Set<DiscoveryStage> off;

  /// Null when the user never chose; see [mdnsIn].
  final MdnsImplementation? mdns;

  Set<DiscoveryStage> get enabled => {
    for (final s in DiscoveryStage.values)
      if (!off.contains(s)) s,
  };

  bool get anyOn => off.length < DiscoveryStage.values.length;

  String get summary => switch (enabled.length) {
    0 => 'All methods off',
    final n when n == DiscoveryStage.values.length => 'All methods on',
    final n => '$n of ${DiscoveryStage.values.length} methods on',
  };

  /// The implementation to use: Android's when it can browse and the user
  /// did not choose the built-in one.
  MdnsImplementation mdnsIn({required bool androidAvailable}) =>
      androidAvailable ? (mdns ?? MdnsImplementation.android) : MdnsImplementation.builtIn;

  DiscoverySettings withStage(DiscoveryStage stage, bool on) =>
      DiscoverySettings(off: on ? ({...off}..remove(stage)) : {...off, stage}, mdns: mdns);

  DiscoverySettings withMdns(MdnsImplementation implementation) => DiscoverySettings(off: off, mdns: implementation);

  Map<String, Object?> toJson() => {
    'off': [
      for (final s in DiscoveryStage.values)
        if (off.contains(s)) s.name,
    ],
    'mdns': mdns?.name,
  };

  factory DiscoverySettings.fromJson(Map<String, Object?>? json) {
    final stages = DiscoveryStage.values.asNameMap();
    return DiscoverySettings(
      off: {for (final name in (json?['off'] as List?) ?? const []) ?stages[name]},
      mdns: MdnsImplementation.values.asNameMap()[json?['mdns']],
    );
  }
}
