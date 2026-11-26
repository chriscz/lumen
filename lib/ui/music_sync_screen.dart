// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../color/color_math.dart';
import '../music/audio_input.dart';
import '../music/music_settings.dart';
import '../music/music_sync.dart';
import 'home_scope.dart';
import 'music_scope.dart';
import 'widgets/experimental_badge.dart';
import 'widgets/music_trace_view.dart';

/// Moves the lights with the music: where to listen, which lights, how
/// they move, and when.
class MusicSyncScreen extends StatefulWidget {
  const MusicSyncScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MusicSyncScreen()));

  @override
  State<MusicSyncScreen> createState() => _MusicSyncScreenState();
}

class _MusicSyncScreenState extends State<MusicSyncScreen> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // A permission given in Android settings shows on the way back.
    _lifecycle = AppLifecycleListener(onResume: () => MusicScope.maybeOf(context)?.refreshSources());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = MusicScope.maybeOf(context);
    // Switched off elsewhere while open: nothing left to show.
    if (music == null) return Scaffold(appBar: AppBar(title: const Text('Music sync')));
    final theme = Theme.of(context);
    final settings = music.settings;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [Text('Music sync'), SizedBox(width: 12), ExperimentalBadge()]),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _StatusCard(music: music),
          header('Listen to'),
          for (final source in AudioSource.values) _SourceTile(music: music, source: source),
          header('Lights'),
          _LightsSection(music: music),
          header('Style'),
          _StyleSection(music: music),
          header('Strength'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Text('Gentle', style: theme.textTheme.bodySmall),
                Expanded(
                  child: _SettledSlider(
                    key: const ValueKey('music-strength'),
                    value: settings.strength,
                    label: (v) => '${(v * 100).round()}%',
                    onDone: (v) => music.update(music.settings.copyWith(strength: v)),
                  ),
                ),
                Text('Strong', style: theme.textTheme.bodySmall),
                _ResetButton(
                  buttonKey: const ValueKey('music-strength-reset'),
                  isDefault: settings.strength == const MusicSettings().strength,
                  onReset: () => music.update(music.settings.copyWith(strength: const MusicSettings().strength)),
                ),
              ],
            ),
          ),
          header('Beat finding'),
          _TuningSlider(
            key: const ValueKey('music-sensitivity'),
            resetKey: const ValueKey('music-sensitivity-reset'),
            value: settings.sensitivity,
            low: 'Strong hits',
            high: 'Faint too',
            onDone: (v) => music.update(music.settings.copyWith(sensitivity: v)),
          ),
          _TuningSlider(
            key: const ValueKey('music-steadiness'),
            resetKey: const ValueKey('music-steadiness-reset'),
            value: settings.steadiness,
            low: 'Loose beat',
            high: 'Strict beat',
            onDone: (v) => music.update(music.settings.copyWith(steadiness: v)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Sensitivity moves the line on the trace that a sound must cross to count. Steadiness is how sure '
              'the beat must be before the lights follow it. The middle of each is the default.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          _TimingFold(music: music),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'Lights flash at most three times a second. If flashing lights affect you, choose Glow.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          SwitchListTile(
            key: const ValueKey('music-tracking-log'),
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('Tracking log'),
            subtitle: const Text('Writes what the beat finder decides to the log in Diagnostics, several lines a second.'),
            value: settings.trackingLog,
            onChanged: (on) => music.update(music.settings.copyWith(trackingLog: on)),
          ),
        ],
      ),
    );
  }
}

/// What music sync is doing, with the one button that starts or stops it.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.music});

  final MusicSync music;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final phase = music.phase;
    final (title, subtitle) = switch (phase) {
      MusicSyncPhase.off => ('Lights follow the music', 'Pick where to listen, then start.'),
      MusicSyncPhase.starting => ('Starting', 'Waiting for Android.'),
      MusicSyncPhase.listening => ('Finding the beat', music.hint ?? 'Listening. The lights join in on the beat.'),
      MusicSyncPhase.following => ('${music.bpm!.round()} BPM', 'Following the beat.'),
      MusicSyncPhase.holding => ('${music.bpm!.round()} BPM', 'Holding the beat.'),
      MusicSyncPhase.hits => (music.bpm == null ? 'Hits' : '${music.bpm!.round()} BPM', 'Following the hits.'),
      MusicSyncPhase.breathing => ('Finding the beat', 'Breathing until the beat comes back.'),
      MusicSyncPhase.failed => ('Stopped', music.problem ?? 'Something went wrong.'),
    };
    final active = music.running || phase == MusicSyncPhase.starting;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            MusicTraceView(trace: music.trace, active: music.running),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: const ValueKey('music-trace-help'),
                tooltip: 'What the trace shows',
                icon: const Icon(Icons.info_outline_rounded),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (context) => SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Reading the trace', style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                            'The last five seconds, newest on the right.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          const TraceGuide(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              subtitle,
              key: const ValueKey('music-status'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: phase == MusicSyncPhase.failed ? scheme.error : scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (music.running) LockBars(report: music.report),
            const SizedBox(height: 16),
            if (active)
              FilledButton.tonalIcon(
                key: const ValueKey('music-stop'),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  music.stop();
                },
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop'),
              )
            else
              FilledButton.icon(
                key: const ValueKey('music-start'),
                onPressed: music.loaded && HomeScope.of(context).lights.isNotEmpty
                    ? () {
                        HapticFeedback.selectionClick();
                        music.start();
                      }
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Start'),
              ),
            if (phase == MusicSyncPhase.failed && music.problemNeedsSettings)
              TextButton.icon(
                key: const ValueKey('music-open-settings'),
                onPressed: music.openSettings,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open Android settings'),
              ),
            if (HomeScope.of(context).lights.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Add a light first.', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// One way to hear the music: what it is good for, and what it needs.
class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.music, required this.source});

  final MusicSync music;
  final AudioSource source;

  static (IconData, String, String) describe(AudioSource source) => switch (source) {
    AudioSource.microphone => (
      Icons.mic_rounded,
      'Microphone',
      'Hears the room, so it works with any speaker and any app, Spotify included.',
    ),
    AudioSource.phoneSound => (
      Icons.speaker_phone_rounded,
      'Phone sound',
      'Follows what this phone plays, Spotify included on most phones. No room noise.',
    ),
    AudioSource.capture => (
      Icons.cast_rounded,
      'Audio capture',
      'The cleanest signal from what this phone plays. Android asks each time, and some apps, '
          'Spotify among them, block it.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = music.sources[source];
    final unsupported = status?.state == SourceState.unsupported;
    final selected = music.settings.source == source;
    final (icon, title, body) = describe(source);
    final note = switch (status?.state) {
      SourceState.needsPermission => 'Needs the microphone permission',
      SourceState.denied => 'Microphone permission refused',
      SourceState.unsupported => status?.reason ?? 'Not on this phone',
      _ => null,
    };
    final scheme = theme.colorScheme;
    return Card(
      key: ValueKey('music-source-${source.name}'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      color: selected ? scheme.secondaryContainer : null,
      child: ListTile(
        enabled: !unsupported,
        selected: selected,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  note,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: status?.state == SourceState.denied ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        trailing: Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
        onTap: unsupported || selected ? null : () => music.update(music.settings.copyWith(source: source)),
      ),
    );
  }
}

/// All lights, or the lights of one room.
class _LightsSection extends StatelessWidget {
  const _LightsSection({required this.music});

  final MusicSync music;

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final theme = Theme.of(context);
    final room = music.settings.roomId;
    final picked = room != null && home.room(room) != null ? room : null;
    final count = music.targets.length;
    final ids = music.settings.lightIds;
    final dimmable = home.lights.where((l) => l.kind.hasBrightness).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const ValueKey('music-room-all'),
                label: const Text('All lights'),
                selected: picked == null && ids.isEmpty,
                onSelected: (_) => music.update(music.settings.copyWith(clearRoom: true)),
              ),
              for (final r in home.rooms)
                ChoiceChip(
                  key: ValueKey('music-room-${r.id}'),
                  label: Text(r.name),
                  selected: picked == r.id,
                  onSelected: (_) => music.update(music.settings.copyWith(roomId: r.id)),
                ),
            ],
          ),
          if (dimmable.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Or pick lights', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final l in dimmable)
                  FilterChip(
                    key: ValueKey('music-light-${l.id}'),
                    label: Text(l.name),
                    selected: ids.contains(l.id),
                    onSelected: (on) {
                      final next = on ? [...ids, l.id] : [for (final id in ids) if (id != l.id) id];
                      music.update(music.settings.copyWith(lightIds: next, clearRoom: next.isEmpty));
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Text(
            switch (count) {
              0 => 'No lights here can dim, so none will move.',
              1 => '1 light will move.',
              _ => '$count lights will move.',
            },
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// How the lights move, and in which colours.
class _StyleSection extends StatelessWidget {
  const _StyleSection({required this.music});

  final MusicSync music;

  static String describe(MusicStyle style) => switch (style) {
    MusicStyle.pulse => 'Every light flashes up on the beat and falls away, with a new colour each bar.',
    MusicStyle.colours => 'Every beat moves each light on to the next colour.',
    MusicStyle.glow => 'Brightness follows the loudness and colour the bass. No flashing.',
  };

  static String follows(FollowMode mode) => switch (mode) {
    FollowMode.auto => 'The predicted beat when it is steady, each hit as it is heard when it is not.',
    FollowMode.beat => 'Only the predicted beat: right on time, but it waits for a steady tempo.',
    FollowMode.hits => 'Each hit as it is heard: a little late, but it never waits for a steady tempo.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = music.settings;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<MusicStyle>(
            segments: const [
              ButtonSegment(
                value: MusicStyle.pulse,
                icon: Icon(Icons.flash_on_rounded, key: ValueKey('music-style-pulse')),
                label: Text('Pulse'),
              ),
              ButtonSegment(
                value: MusicStyle.colours,
                icon: Icon(Icons.palette_rounded, key: ValueKey('music-style-colours')),
                label: Text('Colours'),
              ),
              ButtonSegment(
                value: MusicStyle.glow,
                icon: Icon(Icons.wb_twilight_rounded, key: ValueKey('music-style-glow')),
                label: Text('Glow'),
              ),
            ],
            selected: {settings.style},
            onSelectionChanged: (s) => music.update(music.settings.copyWith(style: s.single)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Text(describe(settings.style), style: theme.textTheme.bodySmall),
          ),
          if (settings.style != MusicStyle.glow) ...[
            SegmentedButton<FollowMode>(
              segments: const [
                ButtonSegment(
                  value: FollowMode.auto,
                  icon: Icon(Icons.auto_awesome_rounded, key: ValueKey('music-follow-auto')),
                  label: Text('Auto'),
                ),
                ButtonSegment(
                  value: FollowMode.beat,
                  icon: Icon(Icons.timeline_rounded, key: ValueKey('music-follow-beat')),
                  label: Text('Beat'),
                ),
                ButtonSegment(
                  value: FollowMode.hits,
                  icon: Icon(Icons.graphic_eq_rounded, key: ValueKey('music-follow-hits')),
                  label: Text('Hits'),
                ),
              ],
              selected: {settings.follow},
              onSelectionChanged: (s) => music.update(music.settings.copyWith(follow: s.single)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Text(follows(settings.follow), style: theme.textTheme.bodySmall),
            ),
          ],
          SegmentedButton<MusicPalette>(
            segments: [
              for (final p in MusicPalette.values)
                ButtonSegment(
                  value: p,
                  icon: _Swatch(palette: p, key: ValueKey('music-palette-${p.name}')),
                  label: Text(switch (p) {
                    MusicPalette.party => 'Party',
                    MusicPalette.warm => 'Warm',
                    MusicPalette.cool => 'Cool',
                  }),
                ),
            ],
            selected: {settings.palette},
            showSelectedIcon: false,
            onSelectionChanged: (s) => music.update(music.settings.copyWith(palette: s.single)),
          ),
        ],
      ),
    );
  }
}

/// The first three colours of a palette, overlapping.
class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.palette});

  final MusicPalette palette;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 26,
    height: 14,
    child: Stack(
      children: [
        for (final (i, hue) in palette.hues.take(3).indexed)
          Positioned(
            left: i * 6.0,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ColorMath.xyToRgb(ColorMath.hueSatToXy(hue, 1)),
                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1),
              ),
            ),
          ),
      ],
    ),
  );
}

/// When the lights change against the beat, closed until opened.
class _TimingFold extends StatelessWidget {
  const _TimingFold({required this.music});

  final MusicSync music;

  static String label(int ms) => switch (ms) {
    0 => 'In time',
    < 0 => '${-ms} ms earlier',
    _ => '$ms ms later',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ms = music.settings.timing.inMilliseconds;
    return ExpansionTile(
      key: const ValueKey('music-timing'),
      leading: const Icon(Icons.timer_outlined),
      title: const Text('Timing'),
      subtitle: Text(label(ms)),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Earlier', style: theme.textTheme.bodySmall),
            Expanded(
              child: _SettledSlider(
                key: const ValueKey('music-timing-slider'),
                value: ms.toDouble(),
                min: MusicSettings.minTiming.inMilliseconds.toDouble(),
                max: MusicSettings.maxTiming.inMilliseconds.toDouble(),
                divisions: 30,
                label: (v) => label(v.round()),
                onDone: (v) => music.update(music.settings.copyWith(timing: Duration(milliseconds: v.round()))),
              ),
            ),
            Text('Later', style: theme.textTheme.bodySmall),
          ],
        ),
        Text(
          'If the lights change before you hear the beat, as with a Bluetooth speaker, move this towards Later. '
          'If they change after it, move it towards Earlier.',
          style: theme.textTheme.bodySmall,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: ms == 0 ? null : () => music.update(music.settings.copyWith(timing: Duration.zero)),
            child: const Text('Reset'),
          ),
        ),
      ],
    );
  }
}

/// Puts a slider back to its default; greyed out while it is there.
class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.buttonKey, required this.isDefault, required this.onReset});

  final Key buttonKey;
  final bool isDefault;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => IconButton(
    key: buttonKey,
    tooltip: 'Reset',
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.restart_alt_rounded),
    onPressed: isDefault ? null : onReset,
  );
}

/// A beat finding slider from 0 to 1, between two labels, with a reset to
/// the middle, the default.
class _TuningSlider extends StatelessWidget {
  const _TuningSlider({
    super.key,
    required this.resetKey,
    required this.value,
    required this.low,
    required this.high,
    required this.onDone,
  });

  final Key resetKey;
  final double value;
  final String low;
  final String high;
  final ValueChanged<double> onDone;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const SizedBox(width: 12),
          SizedBox(width: 72, child: Text(low, style: small)),
          Expanded(
            child: _SettledSlider(value: value, divisions: 20, label: (v) => '${(v * 100).round()}%', onDone: onDone),
          ),
          SizedBox(width: 72, child: Text(high, style: small, textAlign: TextAlign.end)),
          _ResetButton(buttonKey: resetKey, isDefault: value == 0.5, onReset: () => onDone(0.5)),
        ],
      ),
    );
  }
}

/// A slider that shows the dragged value and saves it when let go.
class _SettledSlider extends StatefulWidget {
  const _SettledSlider({
    super.key,
    required this.value,
    required this.onDone,
    required this.label,
    this.min = 0,
    this.max = 1,
    this.divisions,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double) label;
  final ValueChanged<double> onDone;

  @override
  State<_SettledSlider> createState() => _SettledSliderState();
}

class _SettledSliderState extends State<_SettledSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final value = (_drag ?? widget.value).clamp(widget.min, widget.max);
    return Slider(
      value: value,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      label: widget.label(value),
      onChanged: (v) => setState(() => _drag = v),
      onChangeEnd: (v) {
        widget.onDone(v);
        setState(() => _drag = null);
      },
    );
  }
}
