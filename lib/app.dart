// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import 'domain/home.dart';
import 'emulator/bridge_emulator.dart';
import 'plugins/plugin_manager.dart';
import 'state/home_controller.dart';
import 'ui/emulator_scope.dart';
import 'ui/home_scope.dart';
import 'ui/home_screen.dart';
import 'ui/plugin_scope.dart';
import 'ui/reconnect_bar.dart';
import 'ui/theme.dart';

class HueApp extends StatefulWidget {
  const HueApp({super.key, required this.home, this.emulator, this.plugins});

  final HomeController home;

  /// The Hue Bridge emulator; the app makes its own when none is given.
  final BridgeEmulator? emulator;

  /// The plugins; the app makes the standard set when none is given.
  final PluginManager? plugins;

  @override
  State<HueApp> createState() => _HueAppState();
}

class _HueAppState extends State<HueApp> {
  late final PluginManager _plugins = widget.plugins ?? PluginManager.standard(widget.home);
  late final BridgeEmulator _emulator = widget.emulator ?? BridgeEmulator(widget.home, extensions: _plugins.bridge);
  final ThemeData _light = AppTheme.light();
  final ThemeData _dark = AppTheme.dark();

  /// The home's theme choice. The app rebuilds when it changes, not on
  /// every change to the home.
  late final ValueNotifier<ThemeChoice> _themeChoice = ValueNotifier(widget.home.themeChoice);

  @override
  void initState() {
    super.initState();
    widget.home.addListener(_onHome);
    if (!widget.home.loaded) {
      widget.home.load().then((_) {
        widget.home.connectAll();
        _loadEmulator();
      });
    } else {
      _loadEmulator();
    }
  }

  void _onHome() => _themeChoice.value = widget.home.themeChoice;

  /// Starts the emulated bridge at launch when it was left on, and the
  /// plugins that are on.
  void _loadEmulator() {
    if (!_emulator.loaded) _emulator.load();
    if (!_plugins.loaded) _plugins.load();
  }

  @override
  void dispose() {
    widget.home.removeListener(_onHome);
    _themeChoice.dispose();
    if (widget.emulator == null) _emulator.dispose();
    if (widget.plugins == null) _plugins.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HomeScope(
    home: widget.home,
    child: EmulatorScope(
      emulator: _emulator,
      child: PluginScope(
        plugins: _plugins,
        // Every plugin wraps the app, on or off, so the tree keeps its shape.
        child: ListenableBuilder(
          listenable: _plugins,
          builder: (context, child) => _plugins.plugins.fold(child!, (app, plugin) => plugin.wrap(app)),
          child: _app(),
        ),
      ),
    ),
  );

  Widget _app() => ValueListenableBuilder<ThemeChoice>(
    valueListenable: _themeChoice,
    builder: (context, choice, _) => MaterialApp(
      title: 'Lumen',
      debugShowCheckedModeBanner: false,
      theme: _light,
      darkTheme: _dark,
      themeMode: switch (choice) {
        ThemeChoice.system => ThemeMode.system,
        ThemeChoice.dark => ThemeMode.dark,
        ThemeChoice.light => ThemeMode.light,
      },
      builder: (context, child) => ReconnectBar(child: child!),
      home: const ShellScreen(),
    ),
  );
}
