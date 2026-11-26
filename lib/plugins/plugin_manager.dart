// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../emulator/bridge_extensions.dart';
import '../log/logger.dart';
import '../state/home_controller.dart';
import 'lumen_plugin.dart';
import 'music_sync_plugin.dart';

/// Holds the app's plugins: which are on (remembered between runs),
/// attaching and detaching them, and serving their bridge APIs from
/// [bridge]. Settings and Home watch it.
class PluginManager extends ChangeNotifier {
  PluginManager(this.home, {required List<LumenPlugin> plugins, BridgeExtensions? bridge})
    : plugins = List.unmodifiable(plugins),
      bridge = bridge ?? BridgeExtensions() {
    final ids = <String>{};
    for (final p in plugins) {
      if (!ids.add(p.id)) throw ArgumentError.value(p.id, 'plugins', 'two plugins share an id');
    }
  }

  /// Every plugin the app has. Taking one out of this list removes it
  /// from the app entirely.
  factory PluginManager.standard(HomeController home) => PluginManager(home, plugins: [MusicSyncPlugin()]);

  final HomeController home;
  final List<LumenPlugin> plugins;

  /// The plugins' APIs, for the emulated Hue Bridge.
  final BridgeExtensions bridge;

  Map<String, bool> _choices = {};
  final Set<String> _attached = {};
  bool _loaded = false;
  bool _disposed = false;

  bool get loaded => _loaded;

  bool isEnabled(String id) => _attached.contains(id);

  /// The plugins that are on, in [plugins] order.
  List<LumenPlugin> get enabled => [for (final p in plugins) if (_attached.contains(p.id)) p];

  /// The plugin of type [T], whether on or off.
  T? plugin<T extends LumenPlugin>() => plugins.whereType<T>().firstOrNull;

  /// Reads which plugins are on and attaches them.
  Future<void> load() async {
    _choices = await home.services.pluginStore.load();
    for (final p in plugins) {
      if (_choices[p.id] ?? p.enabledByDefault) await _attach(p);
    }
    _loaded = true;
    _notify();
  }

  /// Switches the plugin [id] on or off, and remembers it.
  Future<void> setEnabled(String id, bool on) {
    // One switch at a time: two quick taps would otherwise both find the
    // plugin off and attach it twice. A switch that fails ends the wait
    // for the next one all the same.
    final next = _switching.catchError((Object _) {}).then((_) => _setEnabled(id, on));
    _switching = next;
    return next;
  }

  Future<void> _switching = Future.value();

  Future<void> _setEnabled(String id, bool on) async {
    final plugin = plugins.firstWhere((p) => p.id == id);
    _choices = {..._choices, id: on};
    await home.services.pluginStore.save(_choices);
    if (on == isEnabled(id)) return;
    if (on) {
      await _attach(plugin);
    } else {
      await _detach(plugin);
    }
    _notify();
  }

  Future<void> _attach(LumenPlugin p) async {
    await p.attach(home);
    for (final version in p.bridgeApi.keys) {
      bridge.register(
        plugin: p.id,
        version: version,
        title: p.name,
        experimental: p.experimental,
        handler: (request) => p.bridgeApi[version]!(request),
      );
    }
    _attached.add(p.id);
    home.log.info(LogTag.controller, 'plugin ${p.id} on');
  }

  Future<void> _detach(LumenPlugin p) async {
    _attached.remove(p.id);
    bridge.unregister(p.id);
    await p.detach();
    home.log.info(LogTag.controller, 'plugin ${p.id} off');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final p in enabled) {
      unawaited(_detach(p));
    }
    super.dispose();
  }
}
