// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../emulator/bridge_extensions.dart';
import '../music/music_sync.dart';
import '../music/music_sync_api.dart';
import '../state/home_controller.dart';
import '../ui/music_scope.dart';
import '../ui/music_sync_screen.dart';
import 'lumen_plugin.dart';

/// Music sync as a plugin: experimental, on by default. Off, its button,
/// its Settings entry and its bridge API are gone, and the lights it moved
/// are put back.
class MusicSyncPlugin extends LumenPlugin {
  @override
  String get id => 'music-sync';

  @override
  String get name => 'Music sync';

  @override
  String get description => "Lights follow the music, heard through the microphone or the phone's own sound.";

  @override
  IconData get icon => Icons.graphic_eq_rounded;

  @override
  bool get experimental => true;

  /// Music sync while the plugin is on.
  MusicSync? get music => _music;
  MusicSync? _music;

  @override
  Future<void> attach(HomeController home) async {
    final music = _music = MusicSync(home);
    await music.load();
  }

  @override
  Future<void> detach() async {
    _music?.dispose();
    _music = null;
  }

  @override
  Map<String, ExtensionHandler> get bridgeApi => {
    MusicSyncApi.version: (request) => switch (_music) {
      final music? => MusicSyncApi(music).handle(request),
      null => BridgeExtensions.error(503, 'unavailable', 'Music sync is off'),
    },
  };

  @override
  Widget wrap(Widget child) => MusicScope(music: _music, child: child);

  @override
  List<Widget> homeActions(BuildContext context) {
    final running = MusicScope.maybeOf(context)?.running ?? false;
    return [
      IconButton(
        key: const ValueKey('open-music-sync'),
        tooltip: running ? 'Music sync, running' : 'Music sync',
        isSelected: running,
        icon: Icon(icon),
        selectedIcon: Icon(icon, color: Theme.of(context).colorScheme.primary),
        onPressed: () => MusicSyncScreen.open(context),
      ),
    ];
  }

  @override
  List<Widget> settingsEntries(BuildContext context) {
    final running = MusicScope.maybeOf(context)?.running ?? false;
    return [
      ListTile(
        key: const ValueKey('settings-music-sync'),
        contentPadding: const EdgeInsets.only(left: 72, right: 24),
        title: const Text('Open music sync'),
        subtitle: Text(running ? 'Running. Lights follow the music.' : 'Where to listen, which lights, and how.'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => MusicSyncScreen.open(context),
      ),
    ];
  }
}
