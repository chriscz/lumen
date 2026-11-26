// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/light.dart';
import '../log/logger.dart';
import '../state/home_controller.dart';
import 'audio_chunk.dart';
import 'audio_input.dart';
import 'beat_grid.dart';
import 'beat_tracker.dart';
import 'music_analyser.dart';
import 'music_effect.dart';
import 'music_settings.dart';
import 'music_trace.dart';

/// Where music sync is.
enum MusicSyncPhase {
  off,

  /// Checking and asking for permissions, or waiting for the user to allow
  /// a capture.
  starting,

  /// Hearing sound but no steady beat yet: glow still follows it.
  listening,

  /// Following a beat.
  following,

  /// Flashing on each onset as it is heard: the Hits follow mode, or Auto
  /// while the beat is not steady.
  hits,

  /// The beat was lost a moment ago: the lights keep its tempo.
  holding,

  /// The beat has been gone a while: the lights breathe at its tempo until
  /// it comes back.
  breathing,

  /// Stopped by a problem, which [MusicSync.problem] describes.
  failed,
}

/// Moves the lights with the music: listens to the chosen source, follows
/// its beat with a [MusicAnalyser], and sends each predicted beat to the
/// lights a little before it is heard, through [HomeController]. Puts the
/// lights back when it stops. The Music sync screen watches it.
class MusicSync extends ChangeNotifier {
  MusicSync(this.home);

  final HomeController home;

  /// How far ahead of the beat commands go out, for the radio and the bulb.
  static const lead = Duration(milliseconds: 80);

  /// The shortest time between two flashes: no more than three a second.
  static const minFlashGap = Duration(milliseconds: 333);

  /// How long a pulse holds full brightness before it falls.
  static const hold = Duration(milliseconds: 100);

  /// How often glow updates the lights at most.
  static const glowEvery = Duration(milliseconds: 250);

  /// How long the lights keep a lost beat: this many beats or [holdAtLeast],
  /// whichever is longer.
  static const holdBeats = 8;
  static const holdAtLeast = Duration(seconds: 4);

  /// While breathing, a second with no frame louder than this share of the
  /// loudest frame heard while following counts as silence, and the lights
  /// rest. The tracker's own level cannot tell: it is scaled to the last
  /// few seconds, so silence soon reads as loud.
  static const quietShare = 0.05;
  static const quietFor = Duration(seconds: 1);

  /// Hits follow while an onset louder than [quietShare] of the loudest
  /// frame came this recently.
  static const hitsWithin = Duration(milliseconds: 1500);

  /// How many times its threshold an onset must reach to be a hit: 2.5 at
  /// the lowest Sensitivity, 1.6 at the middle and 1.2 at the highest. In
  /// the simulator, kicks reach theirs 2.7 to 4 times over, and the onsets
  /// that steady noise makes, loud or quiet, at most 1.5 times.
  double get hitMargin {
    final v = _settings.sensitivity;
    return v < 0.5 ? 2.5 - 0.9 * v / 0.5 : 1.6 - 0.4 * (v - 0.5) / 0.5;
  }

  /// The beat length a hit's fall assumes before there is a tempo.
  static const hitPeriod = Duration(milliseconds: 500);

  /// How long without a beat before [hint] suggests something.
  static const hintAfter = Duration(seconds: 10);

  AudioInput get _input => home.services.audio;
  Logger get _log => home.log;

  MusicSettings _settings = const MusicSettings();
  bool _loaded = false;
  Map<AudioSource, SourceStatus> _sources = const {};
  MusicSyncPhase _phase = MusicSyncPhase.off;
  String? _problem;
  bool _problemNeedsSettings = false;

  StreamSubscription<AudioChunk>? _subscription;
  MusicAnalyser? _analyser;
  MusicEffect _effect = MusicEffect(const MusicSettings());
  int _run = 0;

  /// What one run of music sync keeps; made fresh by every [start].
  _RunState _state = _RunState();
  double _level = 0;
  bool _disposed = false;

  /// The last few seconds, for the trace on the Music sync screen.
  final MusicTrace trace = MusicTrace();

  /// Each moved light's state from before music sync, to put back.
  final Map<String, LightState> _before = {};

  bool get loaded => _loaded;
  MusicSettings get settings => _settings;
  MusicSyncPhase get phase => _phase;
  bool get running => switch (_phase) {
    MusicSyncPhase.listening ||
    MusicSyncPhase.following ||
    MusicSyncPhase.hits ||
    MusicSyncPhase.holding ||
    MusicSyncPhase.breathing => true,
    _ => false,
  };

  /// Each source's status, as last read.
  Map<AudioSource, SourceStatus> get sources => _sources;

  /// What stopped music sync, for the user.
  String? get problem => _problem;

  /// Whether only Android's app settings can fix [problem].
  bool get problemNeedsSettings => _problemNeedsSettings;

  /// The tempo while following or holding a beat, and the tracker's best
  /// guess while following hits.
  double? get bpm => switch (_phase) {
    MusicSyncPhase.following || MusicSyncPhase.hits => _analyser?.tracker.bpm,
    MusicSyncPhase.holding => _heldBpm,
    _ => null,
  };

  double? get _heldBpm => _state.grid == null ? null : 60e6 / _state.grid!.period.inMicroseconds;

  /// What the beat tracker makes of the music now, while running.
  TrackerReport? get report => _analyser?.tracker.report;

  /// How many beats have reached the lights since starting.
  int get beats => _state.beats;

  /// The loudness, 0 to 1.
  double get level => _level;

  /// Advice when no beat has been found for a while.
  String? get hint {
    final analyser = _analyser;
    final from = _state.heardFrom;
    if (_phase != MusicSyncPhase.listening || analyser == null || from == null) return null;
    if (analyser.now - from < hintAfter) return null;
    return switch (_settings.source) {
      AudioSource.microphone => 'No beat yet. Turn the music up or bring the phone nearer the speaker.',
      AudioSource.phoneSound => 'No beat yet. Is the music playing on this phone? Some phones do not share it.',
      AudioSource.capture =>
        'No beat yet. Some apps, Spotify among them, block audio capture. Try Phone sound or Microphone.',
    };
  }

  /// The lights music sync moves: those picked, of the chosen room, or all,
  /// that can dim.
  List<Light> get targets {
    final picked = _settings.lightIds.toSet();
    if (picked.isNotEmpty) return home.lights.where((l) => picked.contains(l.id) && l.kind.hasBrightness).toList();
    final room = _settings.roomId;
    final lights = room == null || home.room(room) == null ? home.lights : home.lightsIn(room);
    return lights.where((l) => l.kind.hasBrightness).toList();
  }

  Future<void> load() async {
    _settings = await home.services.musicStore.load() ?? const MusicSettings();
    _effect = MusicEffect(_settings);
    _tune();
    _loaded = true;
    await refreshSources();
  }

  /// Reads each source's status again, as after a visit to app settings.
  Future<void> refreshSources() async {
    _sources = {for (final s in AudioSource.values) s: await _input.status(s)};
    _notify();
  }

  /// Saves [next]. A new source restarts a running or starting sync on it;
  /// new lights put back those that leave and take the ones that join.
  Future<void> update(MusicSettings next) async {
    final previous = _settings;
    _settings = next;
    _effect = MusicEffect(next);
    _notify();
    _tune();
    await home.services.musicStore.save(next);
    if (_phase == MusicSyncPhase.starting && next.source != previous.source) {
      // A start still asking about the old source gives way to one on the new.
      _run++;
      _phase = MusicSyncPhase.off;
      return start();
    }
    if (!running) return;
    if (next.source != previous.source) {
      await _halt(restore: false);
      await start(keepLights: true);
    } else if (next.roomId != previous.roomId || !listEquals(next.lightIds, previous.lightIds)) {
      _retarget();
    }
  }

  void openSettings() => _input.openSettings();

  /// Starts listening to the chosen source, asking for the microphone
  /// permission first when it is needed.
  Future<void> start({bool keepLights = false}) async {
    if (running || _phase == MusicSyncPhase.starting) return;
    final run = ++_run;
    final source = _settings.source;
    _phase = MusicSyncPhase.starting;
    _problem = null;
    _problemNeedsSettings = false;
    _notify();
    var status = await _input.status(source);
    if (status.state == SourceState.needsPermission) status = await _input.requestPermission(source);
    if (run != _run) return;
    await refreshSources();
    switch (status.state) {
      case SourceState.ready:
        break;
      case SourceState.needsPermission:
        return _fail('Music sync needs the microphone permission to hear the music.');
      case SourceState.denied:
        return _fail(
          'The microphone permission was refused. Allow it in Android settings to use music sync.',
          needsSettings: true,
        );
      case SourceState.unsupported:
        return _fail(status.reason ?? 'This phone cannot use that source.');
    }
    if (!keepLights) _before.clear();
    _retarget();
    _analyser = MusicAnalyser();
    _tune();
    trace.clear();
    _state = _RunState();
    _phase = MusicSyncPhase.listening;
    _log.info(LogTag.controller, 'music sync started on ${source.name}');
    _subscription = _input
        .listen(source)
        .listen((chunk) => _onChunk(run, chunk), onError: (Object e) => _onError(run, e), onDone: () => _onDone(run));
    _notify();
  }

  /// Stops listening and puts the lights back.
  Future<void> stop() async {
    _run++;
    await _halt(restore: true);
    _problem = null;
    _phase = MusicSyncPhase.off;
    _notify();
  }

  Future<void> _halt({required bool restore}) async {
    _phase = MusicSyncPhase.off;
    _state.beatTimer?.cancel();
    _state.beatTimer = null;
    _state.scheduled = null;
    final subscription = _subscription;
    _subscription = null;
    _analyser = null;
    _level = 0;
    if (restore) _restore(_before.keys.toList());
    if (subscription != null) {
      _log.info(LogTag.controller, 'music sync stopped');
      // Not awaited: nothing waits on the platform letting go of the source.
      unawaited(subscription.cancel());
    }
  }

  Future<void> _fail(String problem, {bool needsSettings = false}) async {
    _log.warning(LogTag.controller, 'music sync: $problem');
    await _halt(restore: true);
    _problem = problem;
    _problemNeedsSettings = needsSettings;
    _phase = MusicSyncPhase.failed;
    _notify();
  }

  /// Remembers the state of lights that join and puts back those that left.
  void _retarget() {
    final ids = {for (final l in targets) l.id};
    _restore([
      for (final id in _before.keys)
        if (!ids.contains(id)) id,
    ]);
    for (final l in targets) {
      _before.putIfAbsent(l.id, () => l.state);
    }
  }

  void _restore(List<String> ids) {
    final commands = <String, LightCommand>{};
    for (final id in ids) {
      final state = _before.remove(id);
      if (state == null || home.light(id) == null) continue;
      final command = state.toCommand(transition: const Duration(milliseconds: 400));
      if (!command.isEmpty) commands[id] = command;
    }
    if (commands.isNotEmpty) unawaited(home.sendEach(commands));
  }

  void _onChunk(int run, AudioChunk chunk) {
    final analyser = _analyser;
    if (run != _run || analyser == null) return;
    final frames = analyser.add(chunk);
    if (frames.isEmpty) return;
    final now = analyser.now;
    _state.heardFrom ??= now;
    _level = frames.last.level;
    final tracker = analyser.tracker;
    for (final f in frames) {
      trace.addFrame(f);
      _hear(f);
    }
    if (_settings.trackingLog) _logInput(now, frames, tracker);
    final phase = _nextPhase(now, tracker);
    final changed = phase != _phase;
    final from = _phase;
    if (changed) {
      _logPhase(from, phase, tracker);
      trace.setBreathing(now, phase == MusicSyncPhase.breathing);
    }
    _phase = phase;
    if (phase != MusicSyncPhase.following && phase != MusicSyncPhase.holding) {
      // A beat timed while following or holding must not fire into hits,
      // a breath or listening.
      _state.beatTimer?.cancel();
      _state.scheduled = null;
    }
    if (changed && from == MusicSyncPhase.hits && phase == MusicSyncPhase.listening) _rest();

    if (_settings.style == MusicStyle.glow) {
      _glow(now, frames.last);
    } else if (phase == MusicSyncPhase.following || phase == MusicSyncPhase.holding) {
      _schedule(now, _state.grid!, held: phase == MusicSyncPhase.holding);
    } else if (phase == MusicSyncPhase.hits) {
      for (final f in frames) {
        if (_loudOnset(f)) _flash(f.at, now, tracker.period ?? hitPeriod, BeatOutcome.hit);
      }
    } else if (phase == MusicSyncPhase.breathing) {
      _breathe(now, frames);
    }
    if (phase != MusicSyncPhase.breathing) {
      _state.quietSince = null;
      _state.resting = false;
    }
    trace.publish();
    if (changed || _state.lastNotify == null || now - _state.lastNotify! >= const Duration(milliseconds: 100)) {
      _state.lastNotify = now;
      _notify();
    }
  }

  /// What the lights follow now. Beat: the locked grid, then holding it,
  /// then breathing. Hits: each loud onset while they keep coming. Auto:
  /// the locked grid, hits while not locked, then holding and breathing.
  /// Glow follows no mode and never holds.
  MusicSyncPhase _nextPhase(Duration now, BeatTracker tracker) {
    final glow = _settings.style == MusicStyle.glow;
    final mode = glow ? FollowMode.beat : _settings.follow;
    final heard = _state.lastHeardOnset;
    final hearing = heard != null && now - heard < hitsWithin;
    if (mode == FollowMode.hits) return hearing ? MusicSyncPhase.hits : MusicSyncPhase.listening;
    final grid = tracker.grid;
    if (grid != null) {
      _state.grid = grid;
      _state.holdUntil = null;
      return MusicSyncPhase.following;
    }
    if (mode == FollowMode.auto && hearing) return MusicSyncPhase.hits;
    final held = _state.grid;
    if (glow || held == null) return MusicSyncPhase.listening;
    if (_phase == MusicSyncPhase.following || _phase == MusicSyncPhase.hits) {
      final beats = held.period * holdBeats;
      _state.holdUntil = now + (beats > holdAtLeast ? beats : holdAtLeast);
    }
    final until = _state.holdUntil;
    return until != null && now < until ? MusicSyncPhase.holding : MusicSyncPhase.breathing;
  }

  /// Keeps the loudest frame, falling by half in five minutes, and the
  /// last onset loud enough to count.
  void _hear(MusicFrame f) {
    final last = _state.loudAt;
    if (last != null && f.at > last) _state.loudest *= pow(0.5, (f.at - last).inMicroseconds / 300e6).toDouble();
    _state.loudAt = f.at;
    _state.loudest = max(_state.loudest, f.peak);
    if (_loudOnset(f)) _state.lastHeardOnset = f.at;
  }

  /// An onset well past its threshold, in a frame louder than [quietShare]
  /// of the loudest: noise makes onsets too, which must not flash the
  /// lights.
  bool _loudOnset(MusicFrame f) =>
      f.onset && f.onsetFlux! >= hitMargin * f.onsetThreshold! && f.peak >= quietShare * _state.loudest;

  /// Fades the lights to rest after the last beat or hit is sent.
  void _rest() {
    final run = _run;
    final pending = _state.inFlight;
    unawaited(() async {
      await pending;
      if (run != _run) return;
      final commands = _effect.rest(targets);
      if (commands.isNotEmpty) await home.sendEach(commands);
    }());
  }

  void _logPhase(MusicSyncPhase from, MusicSyncPhase to, BeatTracker tracker) {
    switch (to) {
      case MusicSyncPhase.following:
        _track(
          () =>
              '${from == MusicSyncPhase.listening ? 'locked' : 'locked again'} at ${tracker.bpm!.toStringAsFixed(1)} BPM',
        );
      case MusicSyncPhase.holding:
        _track(() => 'lost the lock: ${tracker.lockFailures.join('; ')}; holding ${_heldBpm!.toStringAsFixed(1)} BPM');
      case MusicSyncPhase.breathing:
        _track(() => 'holding ran out, breathing');
      case MusicSyncPhase.hits:
        _track(() => 'following hits${from == MusicSyncPhase.following ? ': ${tracker.lockFailures.join('; ')}' : ''}');
      case MusicSyncPhase.listening when from == MusicSyncPhase.hits:
        _track(() => 'no loud onset for ${hitsWithin.inMilliseconds} ms, resting');
      case MusicSyncPhase.listening when from == MusicSyncPhase.following:
        _track(() => 'lost the lock: ${tracker.lockFailures.join('; ')}');
      default:
    }
  }

  /// Times the next beat of [grid]: commands leave [lead] before it, moved
  /// by the timing setting. A beat already timed is timed again with the
  /// newer prediction. [held] beats come from a grid kept after the lock
  /// was lost.
  void _schedule(Duration now, BeatGrid grid, {required bool held}) {
    final shift = _settings.timing - lead;
    final beat = grid.next(now - shift);
    final period = grid.period;
    final fireAt = beat + shift;
    final wait = fireAt - now;
    // Later chunks will time beats further off, with a better prediction.
    if (wait > const Duration(milliseconds: 150)) return;
    final scheduled = _state.scheduled;
    if (scheduled != null && (scheduled - beat).abs() < period ~/ 2) {
      if (_state.beatTimer?.isActive != true) return;
      _state.beatTimer?.cancel();
    }
    _state.scheduled = beat;
    _state.beatTimer = Timer(wait.isNegative ? Duration.zero : wait, () => _beat(beat, fireAt, period, held: held));
  }

  void _beat(Duration beat, Duration at, Duration period, {required bool held}) =>
      _flash(beat, at, period, held ? BeatOutcome.held : BeatOutcome.fired);

  /// Flashes the lights for a beat or a hit heard or predicted at [mark],
  /// sent at [at], unless too soon after the last flash or while the
  /// lights are busy: nothing queues.
  void _flash(Duration mark, Duration at, Duration period, BeatOutcome kind) {
    if (!running) return;
    // Counted only once sent, so drops do not move Pulse's bar of four.
    final index = _state.beats;
    final what = kind == BeatOutcome.hit ? 'hit' : 'beat';
    _notify();
    final last = _state.lastFlash;
    if (last != null && at - last < minFlashGap) {
      trace.addBeat(mark, BeatOutcome.tooSoon);
      _track(() => '$what $index at ${_s(at)} dropped, too soon after the last flash');
      return;
    }
    if (_state.inFlight != null) {
      _log.debug(LogTag.controller, () => 'music sync: $what $index dropped, the lights are still busy');
      trace.addBeat(mark, BeatOutcome.busy);
      _track(() => '$what $index at ${_s(at)} dropped, the lights are still busy');
      return;
    }
    final lights = targets;
    final commands = _effect.beat(lights, index: index, period: period);
    if (commands == null || commands.isEmpty) return;
    _state.beats++;
    trace.addBeat(mark, kind);
    _state.lastFlash = at;
    final effect = _effect;
    final run = _run;
    final watch = Stopwatch()..start();
    _state.inFlight = _whileSending(
      home.sendEach(commands).then((_) async {
        final how = switch (kind) {
          BeatOutcome.held => 'fired while holding',
          _ => 'fired',
        };
        _track(() => '$what $index at ${_s(at)} $how, the lights took ${watch.elapsedMilliseconds} ms');
        await Future<void>.delayed(hold);
        if (run != _run) return;
        // Only lights still moving: one that left during the hold was put back.
        final fall = effect.fall([
          for (final l in lights)
            if (_before.containsKey(l.id)) l,
        ], period: period);
        if (fall.isNotEmpty) await home.sendEach(fall);
      }),
    );
  }

  /// Logs what the source delivers once a second, each onset, and each
  /// tempo estimate.
  void _logInput(Duration now, List<MusicFrame> frames, BeatTracker tracker) {
    final last = _state.statsLast;
    if (last != null && now - last > _state.statsGap) _state.statsGap = now - last;
    _state.statsLast = now;
    final from = _state.statsFrom ??= now;
    for (final f in frames) {
      _state.statsFrames++;
      _state.statsPeak = max(_state.statsPeak, f.peak);
      _state.statsFloor = f.floor;
      if (f.peak < f.floor) _state.statsQuiet++;
      if (f.onset) {
        _track(
          () =>
              'onset at ${_s(f.at)}, flux ${f.onsetFlux!.toStringAsFixed(4)} over ${f.onsetThreshold!.toStringAsFixed(4)}',
        );
      }
    }
    if (tracker.estimates != _state.estimates) {
      _state.estimates = tracker.estimates;
      _track(
        () =>
            'estimate ${tracker.report.format()}, sensitivity ${_settings.sensitivity.toStringAsFixed(2)}, '
            'steadiness ${_settings.steadiness.toStringAsFixed(2)}',
      );
    }
    if (now - from >= const Duration(seconds: 1)) {
      _track(
        () =>
            'input $_state.statsFrames frames, longest gap ${_state.statsGap.inMilliseconds} ms, loudest '
            '${_state.statsPeak.toStringAsPrecision(3)} against floor ${_state.statsFloor.toStringAsPrecision(3)}, '
            '${(100 * _state.statsQuiet / _state.statsFrames).round()}% below the floor',
      );
      _state.statsFrom = now;
      _state.statsGap = Duration.zero;
      _state.statsFrames = 0;
      _state.statsQuiet = 0;
      _state.statsPeak = 0;
    }
  }

  void _tune() {
    trace.hitMargin = hitMargin;
    _analyser?.tracker.tune(sensitivity: _settings.sensitivity, steadiness: _settings.steadiness);
  }

  /// Marks [sending] as this run's light commands in flight until it ends.
  /// A later run has its own state, which this leaves alone.
  Future<void> _whileSending(Future<void> sending) {
    final state = _state;
    return sending.whenComplete(() => state.inFlight = null);
  }

  /// Logs a tracking line, built only while the tracking log is on.
  void _track(String Function() message) {
    if (_settings.trackingLog) _log.info(LogTag.music, 'music: ${message()}');
  }

  static String _s(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(3);

  /// Moves the lights along a slow sine at the held tempo, one cycle a bar,
  /// at most every [glowEvery]; in silence they rest instead.
  void _breathe(Duration now, List<MusicFrame> frames) {
    for (final f in frames) {
      if (f.peak >= quietShare * _state.loudest) {
        _state.quietSince = null;
        _state.resting = false;
      } else {
        _state.quietSince ??= f.at;
      }
    }
    final quietFrom = _state.quietSince;
    if (quietFrom != null && now - quietFrom >= quietFor) {
      if (_state.resting || _state.inFlight != null) return;
      _state.resting = true;
      _track(() => 'breathing: quiet, resting');
      final commands = _effect.rest(targets);
      if (commands.isNotEmpty) _state.inFlight = _whileSending(home.sendEach(commands));
      return;
    }
    final last = _state.lastBreath;
    if (_state.inFlight != null || (last != null && now - last < glowEvery)) return;
    _state.lastBreath = now;
    final grid = _state.grid!;
    final bar = grid.period * MusicEffect.beatsPerBar;
    final turn = ((now - grid.anchor).inMicroseconds / bar.inMicroseconds) % 1.0;
    final commands = _effect.breathe(targets, amount: 0.5 - 0.5 * cos(2 * pi * turn), over: glowEvery);
    if (commands.isNotEmpty) _state.inFlight = _whileSending(home.sendEach(commands));
  }

  void _glow(Duration now, MusicFrame frame) {
    final last = _state.lastGlow;
    if (_state.inFlight != null || (last != null && now - last < glowEvery)) return;
    _state.lastGlow = now;
    final commands = _effect.level(targets, level: frame.level, bass: frame.bass);
    if (commands.isEmpty) return;
    _state.inFlight = _whileSending(home.sendEach(commands));
  }

  void _onError(int run, Object error) {
    if (run != _run) return;
    _run++;
    final message = switch (error) {
      AudioInputError(:final message) => message,
      _ => 'The sound stopped: $error',
    };
    unawaited(_fail(message));
  }

  void _onDone(int run) {
    if (run != _run) return;
    _log.info(LogTag.controller, 'music sync: the source ended');
    unawaited(stop());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _run++;
    unawaited(_halt(restore: true));
    _disposed = true;
    trace.dispose();
    super.dispose();
  }
}

/// The state of one run of music sync, from [MusicSync.start] to the next.
class _RunState {
  Duration? heardFrom;
  Timer? beatTimer;

  /// The beat [beatTimer] is set for.
  Duration? scheduled;
  Duration? lastFlash;
  Duration? lastGlow;
  Duration? lastNotify;

  /// The light commands still on their way; nothing queues behind them.
  Future<void>? inFlight;

  /// Beats and hits sent to the lights.
  int beats = 0;

  /// The tracker's estimates seen, for the tracking log.
  int estimates = 0;

  /// The grid of the last lock, and when holding it ends.
  BeatGrid? grid;
  Duration? holdUntil;

  /// The loudest raw frame heard, falling by half in five minutes; the
  /// last onset loud enough to count against it; since when it has been
  /// quiet while breathing, whether the lights rest, and the last breath.
  double loudest = 0;
  Duration? loudAt;
  Duration? lastHeardOnset;
  Duration? quietSince;
  bool resting = false;
  Duration? lastBreath;

  /// The tracking log's input tallies for the current second.
  Duration? statsFrom;
  Duration? statsLast;
  Duration statsGap = Duration.zero;
  int statsFrames = 0;
  int statsQuiet = 0;
  double statsPeak = 0;
  double statsFloor = 0;
}
