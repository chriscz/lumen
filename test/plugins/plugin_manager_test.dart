// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/plugins/lumen_plugin.dart';
import 'package:lumen/plugins/plugin_manager.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/plugin_store.dart';

class _Plugin extends LumenPlugin {
  _Plugin(this.id, {this.experimental = false, this.enabledByDefault = true});

  @override
  final String id;
  @override
  final bool experimental;
  @override
  final bool enabledByDefault;
  @override
  String get name => 'Plugin $id';
  @override
  String get description => 'Does $id things.';
  @override
  IconData get icon => Icons.extension;

  final events = <String>[];

  /// Makes [attach] throw, as a plugin that cannot start would.
  bool failAttach = false;

  @override
  Future<void> attach(HomeController home) async {
    if (failAttach) throw StateError('cannot attach');
    events.add('attach');
  }

  @override
  Future<void> detach() async => events.add('detach');

  @override
  Map<String, ExtensionHandler> get bridgeApi => {'1.0.0': (r) => (200, {'from': id})};
}

/// A plugin that leaves every optional part to the contract's defaults.
class _Bare extends LumenPlugin {
  @override
  String get id => 'bare';
  @override
  String get name => 'Bare';
  @override
  String get description => 'Does nothing.';
  @override
  IconData get icon => Icons.extension;
  @override
  Future<void> attach(HomeController home) async {}
  @override
  Future<void> detach() async {}
}

void main() {
  late HomeController home;
  late MemoryPluginStore store;

  setUp(() async {
    store = MemoryPluginStore();
    home = HomeController(AppServices.simulated(pluginStore: store));
    await home.load();
  });

  tearDown(() => home.dispose());

  test('attaches the plugins that are on by default and serves their bridge APIs', () async {
    final on = _Plugin('on-one');
    final off = _Plugin('off-one', enabledByDefault: false);
    final plugins = PluginManager(home, plugins: [on, off]);
    await plugins.load();
    expect(plugins.loaded, isTrue);
    expect(plugins.isEnabled('on-one'), isTrue);
    expect(plugins.isEnabled('off-one'), isFalse);
    expect(on.events, ['attach']);
    expect(off.events, isEmpty);
    expect(plugins.enabled, [on]);
    expect(plugins.bridge.plugins, ['on-one']);
  });

  test('switching a plugin off detaches it, drops its API and is remembered', () async {
    final plugin = _Plugin('music-sync', experimental: true);
    final plugins = PluginManager(home, plugins: [plugin]);
    await plugins.load();
    var changes = 0;
    plugins.addListener(() => changes++);
    await plugins.setEnabled('music-sync', false);
    expect(plugin.events, ['attach', 'detach']);
    expect(plugins.bridge.plugins, isEmpty);
    expect(changes, greaterThan(0));
    expect(await store.load(), {'music-sync': false});

    final again = _Plugin('music-sync', experimental: true);
    final restarted = PluginManager(home, plugins: [again]);
    await restarted.load();
    expect(restarted.isEnabled('music-sync'), isFalse);
    expect(again.events, isEmpty);
    await restarted.setEnabled('music-sync', true);
    expect(again.events, ['attach']);
    expect(restarted.bridge.plugins, ['music-sync']);
  });

  test('switching to the state it is in does nothing', () async {
    final plugin = _Plugin('a');
    final plugins = PluginManager(home, plugins: [plugin]);
    await plugins.load();
    await plugins.setEnabled('a', true);
    expect(plugin.events, ['attach']);
  });

  test('two quick switches on attach once, and a quick on then off ends off', () async {
    final plugin = _Plugin('a', enabledByDefault: false);
    final plugins = PluginManager(home, plugins: [plugin]);
    await plugins.load();
    await Future.wait([plugins.setEnabled('a', true), plugins.setEnabled('a', true)]);
    expect(plugin.events, ['attach']);
    expect(plugins.bridge.plugins, ['a']);
    await Future.wait([plugins.setEnabled('a', false), plugins.setEnabled('a', true), plugins.setEnabled('a', false)]);
    expect(plugin.events, ['attach', 'detach', 'attach', 'detach']);
    expect(plugins.isEnabled('a'), isFalse);
    expect(await store.load(), {'a': false});
  });

  test('a switch that fails does not block the next one', () async {
    final plugin = _Plugin('a', enabledByDefault: false)..failAttach = true;
    final plugins = PluginManager(home, plugins: [plugin]);
    await plugins.load();
    await expectLater(plugins.setEnabled('a', true), throwsStateError);
    plugin.failAttach = false;
    await plugins.setEnabled('a', true);
    expect(plugins.isEnabled('a'), isTrue);
  });

  test('finds a plugin by type, and dispose detaches every plugin that is on', () async {
    final plugin = _Plugin('a');
    final plugins = PluginManager(home, plugins: [plugin]);
    await plugins.load();
    expect(plugins.plugin<_Plugin>(), plugin);
    plugins.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(plugin.events, ['attach', 'detach']);
  });

  test('two plugins cannot share an id', () {
    expect(() => PluginManager(home, plugins: [_Plugin('a'), _Plugin('a')]), throwsArgumentError);
  });

  testWidgets('a plugin is stable, on by default, without an API, and adds nothing to the app unless it says', (
    tester,
  ) async {
    final bare = _Bare();
    expect(bare.experimental, isFalse);
    expect(bare.enabledByDefault, isTrue);
    expect(bare.bridgeApi, isEmpty);
    const child = SizedBox();
    expect(bare.wrap(child), same(child));
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          expect(bare.homeActions(context), isEmpty);
          expect(bare.settingsEntries(context), isEmpty);
          return child;
        },
      ),
    );
  });
}
