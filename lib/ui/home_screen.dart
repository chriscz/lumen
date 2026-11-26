// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lumen_bonded_devices/lumen_bonded_devices.dart';

import '../domain/errors.dart';
import '../domain/home.dart';
import '../domain/light.dart';
import '../log/logger.dart';
import '../state/home_controller.dart';
import 'add_light_screen.dart';
import 'home_scope.dart';
import 'group_detail_screen.dart';
import 'light_detail_screen.dart';
import 'plugin_scope.dart';
import 'profiles_screen.dart';
import 'room_editor_screen.dart';
import 'settings_screen.dart';
import 'widgets/light_tile.dart';
import 'widgets/profile_picker.dart';
import 'widgets/profile_swatch.dart';
import 'widgets/prompts.dart';

/// The app shell: Home and Profiles, with errors shown as snack bars.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  StreamSubscription<LightError>? _errors;
  Timer? _poll;
  AppLifecycleListener? _lifecycle;
  HomeController? _home;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _issueSnack;
  int _shownIssueSeq = 0;
  int _tab = 0;

  /// How often bridge lights are re-read, to catch changes made elsewhere.
  static const pollEvery = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    _startPolling();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        HomeScope.read(context)
          ..setForeground(true)
          ..connectAll();
        _startPolling();
      },
      onPause: () {
        _poll?.cancel();
        HomeScope.read(context)
          ..setForeground(false)
          ..log.flush();
      },
    );
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(pollEvery, (_) {
      if (mounted) HomeScope.read(context).refresh(quiet: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _errors ??= HomeScope.read(context).errors.listen((e) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      // A Bluetooth issue snack bar stays; the error queues behind it.
      messenger.show(e.message, replace: _issueSnack == null);
    });
    if (_home == null) {
      _home = HomeScope.read(context)..addListener(_onHome);
      _onHome();
    }
  }

  /// Shows a missing permission or Bluetooth being off as one floating snack
  /// bar that stays until it is dismissed, acted on, or the issue is gone.
  void _onHome() {
    final home = _home;
    if (home == null || !mounted) return;
    final issue = home.bluetoothIssue;
    if (issue == null) {
      if (_issueSnack != null) {
        home.log.debug(LogTag.ui, () => 'Bluetooth issue gone, hiding its snack bar');
        _issueSnack!.close();
        _issueSnack = null;
      }
      return;
    }
    if (home.bluetoothIssueSeq == _shownIssueSeq) return;
    _shownIssueSeq = home.bluetoothIssueSeq;
    final settings = issue is BluetoothPermissionDenied && issue.permanent;
    home.log.debug(
      LogTag.ui,
      () => 'showing Bluetooth issue ${issue.runtimeType}, action ${settings ? 'settings' : 'retry'}',
    );
    final messenger = ScaffoldMessenger.of(context);
    if (_issueSnack != null) {
      messenger.removeCurrentSnackBar();
      _issueSnack = null;
    }
    final snack = messenger.showSnackBar(
      SnackBar(
        // A key of its own: a reused SnackBarAction would ignore a second tap.
        key: ValueKey('bluetooth-issue-${home.bluetoothIssueSeq}'),
        content: Text(issue.message, key: const ValueKey('bluetooth-issue')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(days: 1),
        showCloseIcon: true,
        action: SnackBarAction(
          label: settings ? 'Open settings' : 'Retry',
          onPressed: () {
            // The action closes this snack bar; a failed retry shows a new one.
            _issueSnack = null;
            home.log.info(LogTag.ui, settings ? 'open app settings' : 'retry Bluetooth');
            if (settings) {
              AppSettings.open();
            } else {
              home.retryBluetooth();
            }
          },
        ),
      ),
    );
    _issueSnack = snack;
    snack.closed.then((reason) {
      home.log.debug(LogTag.ui, () => 'Bluetooth issue snack bar closed: ${reason.name}');
      if (identical(_issueSnack, snack)) _issueSnack = null;
    });
  }

  @override
  void dispose() {
    _home?.removeListener(_onHome);
    _errors?.cancel();
    _poll?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: _tab, children: const [HomeScreen(), ProfilesScreen(), SettingsScreen()]),
    floatingActionButton: _tab == 2
        ? null
        : _tab == 0
        ? FloatingActionButton.extended(
            key: const ValueKey('add-light'),
            heroTag: 'add-light',
            onPressed: () => HomeScreen.addLight(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add light'),
          )
        : FloatingActionButton.extended(
            key: const ValueKey('new-profile'),
            heroTag: 'new-profile',
            onPressed: () => ProfilesScreen.newProfile(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('New profile'),
          ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          selectedIcon: Icon(Icons.auto_awesome_rounded),
          label: 'Profiles',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: 'Settings',
        ),
      ],
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static Future<void> addLight(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddLightScreen()));

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Home lists groups and their lights. A long press on a light starts
/// picking lights; the picked lights can then become a new group.
class _HomeScreenState extends State<HomeScreen> {
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  Future<void> _groupSelected({bool linked = false}) async {
    final home = HomeScope.read(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initial: '', title: linked ? 'Link as one light' : 'New group'),
    );
    if (name == null || !mounted) return;
    await home.createRoom(name, _selected, linked: linked);
    setState(_selected.clear);
  }

  Widget _grid(List<Light> lights) => _LightGrid(
    lights: lights,
    selected: _selected,
    onTap: _selecting ? _toggle : null,
    onLongPress: (id) {
      HapticFeedback.selectionClick();
      _toggle(id);
    },
  );

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final lights = home.lights;
    final rooms = home.rooms.where((r) => !r.linked).toList();
    final clusters = home.clusters;
    final others = home.unassigned;
    final favorites = home.favoriteProfiles;
    _selected.removeWhere((id) => home.light(id) == null);

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting
            ? AppBar(
                leading: IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(_selected.clear),
                ),
                title: Text('${_selected.length} selected'),
                actions: [
                  IconButton(
                    key: const ValueKey('link-selected'),
                    tooltip: 'Link as one light',
                    icon: const Icon(Icons.link_rounded),
                    onPressed: _selected.length < 2 ? null : () => _groupSelected(linked: true),
                  ),
                  IconButton(
                    key: const ValueKey('group-selected'),
                    tooltip: 'Group these lights',
                    icon: const Icon(Icons.group_work_rounded),
                    onPressed: _groupSelected,
                  ),
                ],
              )
            : AppBar(
                title: const Text('Home'),
                actions: [
                  for (final plugin in PluginScope.maybeOf(context)?.enabled ?? const []) ...plugin.homeActions(context),
                  IconButton(
                    key: const ValueKey('all-off'),
                    tooltip: 'All off',
                    icon: const Icon(Icons.power_settings_new_rounded),
                    onPressed: lights.isEmpty
                        ? null
                        : () {
                            HapticFeedback.mediumImpact();
                            home.allOff();
                          },
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('home-menu'),
                    onSelected: (v) => switch (v) {
                      'room' => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RoomEditorScreen())),
                      _ => HomeScreen.addLight(context),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'room',
                        child: ListTile(leading: Icon(Icons.group_work_rounded), title: Text('New group')),
                      ),
                      PopupMenuItem(
                        value: 'light',
                        child: ListTile(leading: Icon(Icons.add_rounded), title: Text('Add light')),
                      ),
                    ],
                  ),
                ],
              ),
        body: lights.isEmpty
            ? const _EmptyState()
            : RefreshIndicator(
                onRefresh: home.connectAll,
                child: CustomScrollView(
                  slivers: [
                    if (favorites.isNotEmpty && !_selecting)
                      SliverToBoxAdapter(child: _FavoriteProfiles(profiles: favorites)),
                    if (rooms.isEmpty && lights.length > 1 && !_selecting)
                      const SliverToBoxAdapter(child: _GroupHint()),
                    for (final cluster in clusters) ...[
                      SliverToBoxAdapter(
                        child: _ClusterHeader(
                          room: cluster,
                          expanded: !_collapsed.contains(cluster.id),
                          onExpand: () => setState(
                            () => _collapsed.contains(cluster.id)
                                ? _collapsed.remove(cluster.id)
                                : _collapsed.add(cluster.id),
                          ),
                        ),
                      ),
                      if (!_collapsed.contains(cluster.id)) _grid(home.lightsIn(cluster.id)),
                    ],
                    for (final room in rooms) ...[
                      SliverToBoxAdapter(child: _RoomHeader(room: room)),
                      _grid(home.lightsIn(room.id)),
                    ],
                    if (others.isNotEmpty) ...[
                      if (rooms.isNotEmpty) const SliverToBoxAdapter(child: _SectionTitle('Other lights')),
                      if (others.isNotEmpty) _grid(others),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 96)),
                  ],
                ),
              ),
      ),
    );
  }
}

class _GroupHint extends StatelessWidget {
  const _GroupHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(
        children: [
          Icon(Icons.touch_app_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Long press a light to pick several and group them.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _FavoriteProfiles extends StatelessWidget {
  const _FavoriteProfiles({required this.profiles});

  final List<Profile> profiles;

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.read(context);
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          for (final p in profiles)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: ProfileSwatch(profile: p, size: 20),
                label: Text(p.name),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  home.applyProfile(p.id);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({required this.room});

  final Room room;

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final lights = home.lightsIn(room.id);
    final on = lights.where((l) => l.isOn).length;
    final unreachable = lights.where((l) => !l.reachable).length;
    final theme = Theme.of(context);
    final status = [
      '${lights.length} ${lights.length == 1 ? 'light' : 'lights'}',
      if (on > 0) '$on on',
      if (unreachable > 0) '$unreachable unreachable',
    ].join(', ');
    return InkWell(
      key: ValueKey('room-header-${room.name}'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupDetailScreen(roomId: room.id))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room.name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                  Text(status, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Switch(
              value: home.roomIsOn(room.id),
              onChanged: lights.isEmpty ? null : (v) => home.setRoomPower(room.id, v),
            ),
          ],
        ),
      ),
    );
  }
}

class _LightGrid extends StatelessWidget {
  const _LightGrid({required this.lights, required this.selected, required this.onLongPress, this.onTap});

  final List<Light> lights;
  final Set<String> selected;

  /// Set while picking lights: a tap then picks instead of opening.
  final ValueChanged<String>? onTap;
  final ValueChanged<String> onLongPress;

  @override
  Widget build(BuildContext context) {
    final HomeController home = HomeScope.read(context);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          mainAxisExtent: 168,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: lights.length,
        itemBuilder: (context, i) {
          final light = lights[i];
          return LightTile(
            key: ValueKey(light.id),
            light: light,
            selected: selected.contains(light.id),
            // Only a member of a linked cluster can be detached, and rejoin it.
            onRejoin: home.isDetached(light.id) ? () => home.rejoin(light.roomId!, light.id) : null,
            onPower: (on) => home.setPower(light.id, on),
            onBrightness: (b) => home.setBrightness(light.id, b),
            onLongPress: () => onLongPress(light.id),
            onProfiles: () => showProfilePicker(
              context,
              title: 'Profile for ${light.name}',
              profiles: home.profilesFor(light.id),
              onPick: (p) => home.applyProfile(p.id, to: [light.id]),
            ),
            onTap: onTap != null
                ? () => onTap!(light.id)
                : () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => LightDetailScreen(lightId: light.id))),
          );
        },
      ),
    );
  }
}

/// A linked cluster: a line with its status, Reset and a chevron to show
/// or hide its lights, then one wide tile that controls it as one light.
class _ClusterHeader extends StatelessWidget {
  const _ClusterHeader({required this.room, required this.expanded, required this.onExpand});

  final Room room;
  final bool expanded;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final theme = Theme.of(context);
    final members = home.lightsIn(room.id);
    final detached = home.detachedIn(room.id).length;
    void open() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupDetailScreen(roomId: room.id)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.link_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: open,
                  child: Text(
                    ['Cluster, ${members.length} lights', if (detached > 0) '$detached detached'].join(', '),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              if (detached > 0)
                TextButton.icon(
                  key: const ValueKey('cluster-reset'),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    home.resetCluster(room.id);
                  },
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset'),
                ),
              IconButton(
                key: const ValueKey('cluster-expand'),
                tooltip: expanded ? 'Hide its lights' : 'Show its lights',
                icon: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                onPressed: onExpand,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              height: 168,
              child: LightTile(
                key: ValueKey('cluster:${room.id}'),
                light: home.clusterLight(room),
                linkedCount: members.length,
                onPower: (on) => home.setRoomPower(room.id, on),
                onBrightness: (b) => home.setRoomBrightness(room.id, b),
                onTap: open,
                onProfiles: () => showProfilePicker(
                  context,
                  title: 'Profile for ${room.name}',
                  profiles: home.profilesForCluster(room.id),
                  onPick: (p) => home.applyProfileToCluster(p.id, room.id),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lightbulb_outline_rounded, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('No lights yet', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Add a Hue Bluetooth bulb nearby, or pair a Hue Bridge to bring in all of its lights.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
