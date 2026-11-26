// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import '../emulator/bridge_background.dart';
import '../emulator/nsd.dart';

/// Android's mDNS responder, simulated: it remembers what is registered and
/// fails with [failWith] when set.
class SimulatedSystemMdns implements SystemMdns {
  SimulatedSystemMdns({this.available = true});

  @override
  final bool available;

  /// The reason the next registrations fail; null succeeds.
  String? failWith;

  ({String name, int port, Map<String, String> txt})? registered;
  final calls = <String>[];

  @override
  Future<String?> register({required String name, required int port, required Map<String, String> txt}) async {
    calls.add('register');
    if (failWith case final reason?) return reason;
    registered = (name: name, port: port, txt: txt);
    return null;
  }

  @override
  Future<void> unregister() async {
    calls.add('unregister');
    registered = null;
  }
}

/// The Android foreground service, simulated: it remembers whether it runs
/// and what its notification says.
class SimulatedBridgeBackground implements BridgeBackground {
  bool running = false;
  String? text;
  bool stayAwakeWhileCharging = false;

  /// What the notification permission request answers.
  bool notificationsGranted = false;
  final calls = <String>[];

  @override
  bool get supported => true;

  @override
  Future<void> run({required String text, required bool stayAwakeWhileCharging}) async {
    calls.add('run');
    running = true;
    this.text = text;
    this.stayAwakeWhileCharging = stayAwakeWhileCharging;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<bool> requestNotifications() async {
    calls.add('requestNotifications');
    return notificationsGranted;
  }

  @override
  Future<bool> openBatterySettings() async {
    calls.add('openBatterySettings');
    return true;
  }
}
