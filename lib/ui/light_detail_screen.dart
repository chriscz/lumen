// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';

import 'package:flutter/material.dart';

import '../color/color_math.dart';
import '../domain/errors.dart';
import '../domain/light.dart';
import '../domain/power_on.dart';
import '../state/home_controller.dart';
import 'home_scope.dart';
import 'widgets/detail_frame.dart';
import 'widgets/gradient_card.dart';
import 'widgets/light_controls.dart';
import 'widgets/profile_swatch.dart';
import 'widgets/prompts.dart';
import 'widgets/sleep_fade.dart';

/// The light menu's entries, in menu order.
enum _MenuAction {
  discoverable(Icons.wifi_tethering_rounded, 'Make discoverable'),
  powerOn(Icons.power_rounded, 'When power returns'),
  minDim(Icons.brightness_low_rounded, 'Minimum brightness'),
  rename(Icons.edit_rounded, 'Rename'),
  identify(Icons.flare_rounded, 'Identify'),
  fade(Icons.bedtime_rounded, 'Sleep fade'),
  profile(Icons.bookmark_add_rounded, 'Save as profile'),
  remove(Icons.delete_outline_rounded, 'Remove');

  const _MenuAction(this.icon, this.label);

  final IconData icon;
  final String label;

  /// Bluetooth-only settings are offered for the bulbs that have them.
  bool offeredFor(Light light) {
    final ble = light.transport == Transport.ble;
    return switch (this) {
      discoverable => ble,
      powerOn => ble && light.powerOnConfigurable,
      minDim => ble && light.minDimConfigurable && light.kind.hasBrightness,
      _ => true,
    };
  }

  PopupMenuItem<_MenuAction> get item => PopupMenuItem(
    value: this,
    child: ListTile(leading: Icon(icon), title: Text(label)),
  );
}

class LightDetailScreen extends StatefulWidget {
  const LightDetailScreen({super.key, required this.lightId});

  final String lightId;

  @override
  State<LightDetailScreen> createState() => _LightDetailScreenState();
}

class _LightDetailScreenState extends State<LightDetailScreen> {
  /// White chosen over colour; unset follows the light's colour.
  bool? _white;

  /// Where the user last put the wheel's thumb. The light's colour is
  /// clamped to its gamut, so hue and saturation derived from it can sit a
  /// little off the finger; this keeps the thumb where it was put until the
  /// colour changes from somewhere else (a report, a poll, a profile).
  (double, double)? _wheel;

  /// Colours this screen sent since the user last moved the wheel.
  final Set<LightColor> _sent = {};
  LightColor? _seen;

  Future<void> _rename(Light light) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initial: light.name),
    );
    if (name != null && mounted) await HomeScope.read(context).rename(light.id, name);
  }

  Future<void> _saveAsProfile(Light light) async {
    final home = HomeScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const RenameDialog(initial: '', title: 'Save as profile'),
    );
    if (name == null) return;
    final state = light.state;
    await home.savePreset(name, LightState(on: true, brightness: state.brightness, color: state.color));
    messenger.show('Saved $name to Profiles');
  }

  Future<void> _remove(Light light) async {
    final ok = await confirm(
      context,
      title: 'Remove ${light.name}?',
      body: light.transport == Transport.ble
          ? 'The app forgets this bulb. To unpair it fully, also forget it in Android Bluetooth settings.'
          : 'The app forgets this light. It stays on your bridge, and Settings lists it under the bridge to add back.',
      action: 'Remove',
    );
    if (!ok || !mounted) return;
    final home = HomeScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    await home.remove(light.id);
    messenger.show('Removed ${light.name}', undo: () => home.restore(light));
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final light = home.light(widget.lightId);
    if (light == null) return const Scaffold();
    final theme = Theme.of(context);
    final glow = ColorMath.displayColor(light.state);
    final profiles = home.profilesFor(light.id);
    final effects = light.effects;
    final gradientModes = light.supportsGradient ? light.gradientModes : null;
    final white = _white ?? !(light.kind.hasColor && light.state.color is! WhiteColor);
    if (light.state.color != _seen) {
      _seen = light.state.color;
      if (!_sent.contains(_seen)) {
        _wheel = null;
        _sent.clear();
      }
    }
    final wheel =
        _wheel ??
        switch (light.state.color) {
          final XyColor xy => ColorMath.xyToHueSat(xy),
          _ => (30.0, 0.0),
        };

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(light.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: light.favorite ? 'Remove from favourites' : 'Add to favourites',
            icon: Icon(light.favorite ? Icons.star_rounded : Icons.star_outline_rounded),
            onPressed: () => home.toggleFavorite(light.id),
          ),
          PopupMenuButton<_MenuAction>(
            key: const ValueKey('light-menu'),
            onSelected: (action) => switch (action) {
              _MenuAction.rename => _rename(light),
              _MenuAction.identify => home.identify(light.id),
              _MenuAction.profile => _saveAsProfile(light),
              _MenuAction.fade => showSleepFade(context, [light.id]),
              _MenuAction.powerOn => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => _PowerOnSheet(home: home, lightId: light.id),
              ),
              _MenuAction.minDim => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => _MinDimSheet(home: home, lightId: light.id),
              ),
              _MenuAction.discoverable => showModalBottomSheet<void>(
                context: context,
                isDismissible: false,
                builder: (_) => _DiscoverableSheet(home: home, lightId: light.id),
              ),
              _MenuAction.remove => _remove(light),
            },
            itemBuilder: (_) => [
              for (final action in _MenuAction.values)
                if (action.offeredFor(light)) action.item,
            ],
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: DetailFrame(
        glow: glow,
        on: light.isOn,
        children: [
          if (home.needsAppSecurity(light.id))
            Card(
              key: const ValueKey('app-security-banner'),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        const NeedsAppSecurity().message,
                        style: TextStyle(color: theme.colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          PowerRow(
            on: light.isOn,
            status: light.reachable ? null : 'Unreachable',
            onChanged: (on) => home.setPower(light.id, on),
          ),
          const SizedBox(height: 12),
          WheelCard(
            white: white,
            onWhite: (w) => setState(() => _white = w),
            showToggle: light.kind.hasColor,
            showWheel: light.kind.hasColor && !white,
            hue: wheel.$1,
            saturation: wheel.$2,
            onColor: (h, s, color) {
              setState(() {
                _wheel = (h, s);
                _sent.add(color);
              });
              home.setColor(light.id, color);
            },
          ),
          if (light.kind.hasTemperature && (white || !light.kind.hasColor))
            TemperatureSlider(
              mireds: switch (light.state.color) {
                WhiteColor(:final mireds) => mireds,
                _ => HueRange.defaultMireds,
              },
              minMireds: light.miredsRange.$1,
              maxMireds: light.miredsRange.$2,
              onChanged: (m) => home.setColor(light.id, WhiteColor(m)),
            ),
          if (light.kind.hasBrightness) ...[
            const SizedBox(height: 16),
            BrightnessSlider(
              brightness: light.state.brightness ?? 254,
              onChanged: (b) => home.setBrightness(light.id, b),
            ),
          ],
          const SizedBox(height: 16),
          if (light.kind.hasTemperature)
            Swatches(
              colors: light.kind.hasColor ? Swatches.all : Swatches.whites,
              onPick: (c) {
                setState(() {
                  _white = c is WhiteColor;
                  _wheel = null;
                  _sent.clear();
                });
                home.setColor(light.id, c);
              },
            ),
          if (gradientModes != null) ...[
            const SizedBox(height: 16),
            GradientCard(
              key: const ValueKey('gradient-card'),
              gradient: light.state.gradient,
              modes: gradientModes,
              onChanged: (g) => home.setGradient(light.id, g),
            ),
          ],
          if (profiles.isNotEmpty) ...[
            const SizedBox(height: 16),
            ControlCard(
              icon: Icons.auto_awesome_rounded,
              title: 'Profiles',
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in profiles)
                      ActionChip(
                        key: ValueKey('detail-profile-${p.name}'),
                        avatar: ProfileSwatch(profile: p, size: 20),
                        label: Text(p.name),
                        onPressed: () {
                          setState(() {
                            _white = null;
                            _wheel = null;
                          });
                          home.applyProfile(p.id, to: [light.id]);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (effects.isNotEmpty) ...[
            const SizedBox(height: 16),
            EffectsCard(
              effects: effects,
              effect: light.state.effect ?? HueEffect.none,
              speed: light.state.effectSpeed ?? 128,
              onEffect: (e) => home.setEffect(light.id, e, speed: light.state.effectSpeed ?? 128),
              onSpeed: (v) => home.setEffect(light.id, light.state.effect ?? HueEffect.none, speed: v),
            ),
          ],
        ],
      ),
    );
  }
}

/// Reads the lowest level the light dims to, and sets it.
class _MinDimSheet extends StatefulWidget {
  const _MinDimSheet({required this.home, required this.lightId});

  final HomeController home;
  final String lightId;

  @override
  State<_MinDimSheet> createState() => _MinDimSheetState();
}

class _MinDimSheetState extends State<_MinDimSheet> {
  double? _level;

  /// The light's current level is known. The characteristic is write-only,
  /// so it is not until Lumen has set it.
  bool _known = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.home
        .minDim(widget.lightId)
        .then(
          (level) {
            if (mounted) {
              setState(() {
                _level = level ?? 0;
                _known = level != null;
              });
            }
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = e is LightError ? e.message : '$e');
          },
        );
  }

  Future<void> _save() async {
    final level = _level;
    if (level == null) return;
    setState(() => _saving = true);
    try {
      await widget.home.setMinDim(widget.lightId, level);
      if (mounted) Navigator.pop(context);
    } on LightError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = _level;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Minimum brightness', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('The lowest level the light dims to, also from switches and other apps.'),
            if (level == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (level != null)
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      key: const ValueKey('min-dim-slider'),
                      value: level,
                      onChanged: _saving ? null : (v) => setState(() => _level = v),
                    ),
                  ),
                  SizedBox(width: 48, child: Text('${(level * 100).round()}%')),
                ],
              ),
            if (level != null && !_known)
              Text(
                'The light does not tell its current level. Pick one and save it.',
                key: const ValueKey('min-dim-unknown'),
                style: theme.textTheme.bodySmall,
              ),
            if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('min-dim-save'),
                onPressed: level == null || _saving ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reads what the light does when its power returns, and sets it.
class _PowerOnSheet extends StatefulWidget {
  const _PowerOnSheet({required this.home, required this.lightId});

  final HomeController home;
  final String lightId;

  static const choices = {
    PowerOnMode.lastState: ('Last state', 'As it was before the power went'),
    PowerOnMode.alwaysOn: ('Always on', 'At the brightness and colour it has now'),
    PowerOnMode.alwaysOff: ('Always off', 'Stays off until you switch it on'),
  };

  @override
  State<_PowerOnSheet> createState() => _PowerOnSheetState();
}

class _PowerOnSheetState extends State<_PowerOnSheet> {
  PowerOnMode? _mode;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final behavior = await widget.home.powerOnBehavior(widget.lightId);
      if (mounted) setState(() => _mode = behavior?.mode);
    } on LightError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick(PowerOnMode mode) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.home.setPowerOnMode(widget.lightId, mode);
      if (mounted) setState(() => _mode = mode);
    } on LightError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrolls so a long error under the three choices fits on a phone.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('When power returns', style: theme.textTheme.titleLarge),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_mode == PowerOnMode.custom)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Another app set a custom behaviour. Pick one to replace it.'),
                ),
              RadioGroup<PowerOnMode>(
                groupValue: _mode,
                onChanged: (m) {
                  if (m != null && !_saving) _pick(m);
                },
                child: Column(
                  children: [
                    for (final MapEntry(key: mode, value: (title, subtitle)) in _PowerOnSheet.choices.entries)
                      RadioListTile<PowerOnMode>(
                        key: ValueKey('power-on-${mode.name}'),
                        value: mode,
                        title: Text(title),
                        subtitle: Text(subtitle),
                      ),
                  ],
                ),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Keeps a Bluetooth bulb open for bonding while it is shown: the bulb
/// stays open for about five minutes per request, so the request repeats
/// every four.
class _DiscoverableSheet extends StatefulWidget {
  const _DiscoverableSheet({required this.home, required this.lightId});

  final HomeController home;
  final String lightId;

  static const repeatEvery = Duration(minutes: 4);

  @override
  State<_DiscoverableSheet> createState() => _DiscoverableSheetState();
}

class _DiscoverableSheetState extends State<_DiscoverableSheet> {
  Timer? _repeat;
  String? _error;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _send();
    _repeat = Timer.periodic(_DiscoverableSheet.repeatEvery, (_) => _send());
  }

  Future<void> _send() async {
    try {
      await widget.home.makeDiscoverable(widget.lightId);
      if (mounted) setState(() => _open = true);
    } on LightError catch (e) {
      _repeat?.cancel();
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Make discoverable', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            else ...[
              Row(
                children: [
                  if (!_open)
                    const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(Icons.wifi_tethering_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_open ? 'The light is discoverable.' : 'Asking the light...')),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Another phone or app (such as Alexa or Google Home) can now pair with this light for about 5 minutes. '
                'Keep this open to keep it discoverable longer.',
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('discoverable-done'),
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
