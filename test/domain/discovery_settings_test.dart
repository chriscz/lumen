// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/discovery_settings.dart';

void main() {
  test('every method is on by default, with no mDNS implementation chosen', () {
    const settings = DiscoverySettings();
    expect(settings.enabled, DiscoveryStage.values.toSet());
    expect(settings.mdns, isNull);
    expect(settings.summary, 'All methods on');
    expect(settings.anyOn, isTrue);
  });

  test('turning methods off and on keeps the rest', () {
    final settings = const DiscoverySettings()
        .withStage(DiscoveryStage.ssdp, false)
        .withStage(DiscoveryStage.known, false);
    expect(settings.enabled, {DiscoveryStage.mdns, DiscoveryStage.sweep});
    expect(settings.summary, '2 of 4 methods on');
    expect(settings.withStage(DiscoveryStage.ssdp, true).summary, '3 of 4 methods on');
    final none = DiscoveryStage.values.fold(settings, (s, stage) => s.withStage(stage, false));
    expect(none.summary, 'All methods off');
    expect(none.anyOn, isFalse);
  });

  test('round-trips through JSON, storing the methods that are off', () {
    final settings = const DiscoverySettings()
        .withStage(DiscoveryStage.sweep, false)
        .withMdns(MdnsImplementation.builtIn);
    final json = settings.toJson();
    expect(json, {
      'off': ['sweep'],
      'mdns': 'builtIn',
    });
    final back = DiscoverySettings.fromJson(json);
    expect(back.enabled, settings.enabled);
    expect(back.mdns, MdnsImplementation.builtIn);
  });

  test('reads missing or unknown values as the defaults', () {
    final back = DiscoverySettings.fromJson(const {
      'off': ['teleport'],
      'mdns': 'carrier pigeon',
    });
    expect(back.enabled, DiscoveryStage.values.toSet());
    expect(back.mdns, isNull);
    expect(DiscoverySettings.fromJson(null).enabled, DiscoveryStage.values.toSet());
  });

  test('the mDNS implementation in use is the chosen one only when Android can browse', () {
    const unset = DiscoverySettings();
    expect(unset.mdnsIn(androidAvailable: true), MdnsImplementation.android);
    expect(unset.mdnsIn(androidAvailable: false), MdnsImplementation.builtIn);
    final builtIn = unset.withMdns(MdnsImplementation.builtIn);
    expect(builtIn.mdnsIn(androidAvailable: true), MdnsImplementation.builtIn);
    final android = unset.withMdns(MdnsImplementation.android);
    expect(android.mdnsIn(androidAvailable: false), MdnsImplementation.builtIn);
  });

  test('names each method and implementation for the user', () {
    expect([for (final s in DiscoveryStage.values) s.label], ['Known bridges', 'mDNS', 'SSDP', 'Network scan']);
    expect(MdnsImplementation.android.label, 'Android (system)');
    expect(MdnsImplementation.builtIn.label, 'Built-in');
    expect(MdnsImplementation.android.short, 'Android');
    expect(MdnsImplementation.builtIn.short, 'built-in');
  });
}
