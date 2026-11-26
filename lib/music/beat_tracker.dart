// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'beat_grid.dart';

/// What one analysis frame heard.
class MusicFrame {
  const MusicFrame({
    required this.at,
    required this.level,
    required this.bass,
    this.onset = false,
    this.onsetFlux,
    this.onsetThreshold,
    this.peak = 0,
    this.floor = 0,
    this.flux = 0,
    this.threshold,
  });

  /// The middle of the frame, on the audio clock; for an onset, the onset's
  /// time.
  final Duration at;

  /// Loudness from 0 to 1, against the loudest of the last few seconds.
  final double level;

  /// Bass loudness from 0 to 1, against the loudest bass of the last few
  /// seconds.
  final double bass;

  /// Whether a note or drum hit starts here.
  final bool onset;

  /// For an onset, its spectral flux and the threshold it passed.
  final double? onsetFlux;
  final double? onsetThreshold;

  /// The largest magnitude of the frame and the quietest worth hearing, in
  /// the source's own units.
  final double peak;
  final double floor;

  /// This frame's onset signal (spectral flux), and the threshold an onset
  /// must pass now; null until there is enough history.
  final double flux;
  final double? threshold;
}

/// What the tracker made of the last few seconds, for the tracking log.
class TrackerReport {
  const TrackerReport({
    required this.bpm,
    required this.confidence,
    required this.coverage,
    required this.onsets,
    required this.sinceOnset,
    required this.level,
    required this.failures,
    required this.candidates,
    this.confidenceNeeded = BeatTracker.minConfidence,
    this.coverageNeeded = BeatTracker.minCoverage,
  });

  final double? bpm;
  final double confidence;
  final double coverage;

  /// Onsets in the grid window, and seconds since the last one.
  final int onsets;
  final double? sinceOnset;
  final double level;

  /// The lock tests that fail; empty while locked.
  final List<String> failures;

  /// The best tempos of the last estimate, best first: BPM and score
  /// against the best.
  final List<(double, double)> candidates;

  /// What confidence and coverage the lock needs, as tuned.
  final double confidenceNeeded;
  final double coverageNeeded;

  bool get locked => failures.isEmpty;

  String format() {
    String f2(double v) => v.toStringAsFixed(2);
    final tempo = bpm == null ? 'no tempo' : '${bpm!.toStringAsFixed(1)} BPM';
    final since = sinceOnset == null ? 'none' : '${sinceOnset!.toStringAsFixed(1)} s ago';
    final best = candidates.map((c) => '${c.$1.toStringAsFixed(1)} (${f2(c.$2)})').join(', ');
    return '$tempo, confidence ${f2(confidence)}, coverage ${f2(coverage)}, onsets $onsets, last onset $since, '
        'level ${f2(level)}, ${locked ? 'locked' : 'not locked: ${failures.join('; ')}'}, candidates [$best]';
  }
}

/// Finds the beat in a stream of spectra, in real time.
///
/// Each frame's spectral flux (how much louder each frequency got since the
/// last frame) marks onsets where it peaks above a running threshold. The
/// tempo comes from the intervals between all pairs of recent onsets, and
/// the beat grid from a straight line fitted through the onsets that fall
/// near it, so the next beat can be predicted before it is heard. Works the
/// same from 80 frames a second (samples) or 20 (the Visualizer).
class BeatTracker {
  BeatTracker({this.minBpm = 70, this.maxBpm = 160});

  /// The tempo range. Faster music is followed at half its tempo.
  final double minBpm;
  final double maxBpm;

  /// How sure the grid must be before beats are given, untuned.
  static const minConfidence = 0.55;

  /// The onset threshold's parts, standard deviations and times the mean,
  /// and what the lock needs, as tuned.
  double _sds = 1.5;
  double _means = 2.0;
  double _confidenceNeeded = minConfidence;
  double _coverageNeeded = minCoverage;
  double? _threshold;

  /// Tunes the onset threshold by [sensitivity] and the lock by
  /// [steadiness], each 0 to 1 with the untuned rule at 0.5.
  void tune({required double sensitivity, required double steadiness}) {
    double through(double v, double lo, double mid, double hi) {
      final x = v.clamp(0.0, 1.0);
      return x < 0.5 ? lo + (mid - lo) * x / 0.5 : mid + (hi - mid) * (x - 0.5) / 0.5;
    }

    _sds = through(sensitivity, 2.5, 1.5, 0.5);
    _means = through(sensitivity, 3.0, 2.0, 1.2);
    _confidenceNeeded = through(steadiness, 0.35, minConfidence, 0.75);
    _coverageNeeded = through(steadiness, 0.40, minCoverage, 0.80);
  }

  static const _fluxWindow = 1.0;
  static const _tempoWindow = 8.0;
  static const _gridWindow = 6.0;
  static const _recency = 3.0;
  static const _minGap = 0.08;
  static const _updateEvery = 0.5;

  Float64List? _previous;
  final _flux = ListQueue<(double, double)>();
  (double, double)? _f1;
  (double, double)? _f2;
  double? _lastOnset;
  final _onsets = ListQueue<(double, double)>();
  final _intervals = ListQueue<double>();
  double? _lastFrame;
  double _spectrumPeak = 0;
  double _levelPeak = 0;
  double _bassPeak = 0;
  double _level = 0;
  double _bass = 0;
  double _now = 0;
  double? _lastUpdate;

  double? _period;
  double? _anchor;
  double? _candidate;
  int _candidateHits = 0;
  /// How much of the recent onset strength falls on the beat grid, 0 to 1.
  double _confidence = 0;

  /// The share of recent beats of the grid that had an onset, 0 to 1. Noise
  /// can line up with a grid by chance, but not on most of its beats.
  double _coverage = 0;
  double? _first;

  /// The tempo, while there is one.
  double? get bpm => _period == null ? null : 60 / _period!;

  /// The time between beats.
  Duration? get period => _period == null ? null : _duration(_period!);

  /// How many of the grid's beats must be heard, untuned.
  static const minCoverage = 0.6;

  /// Why the beat is not steady enough to follow, one entry per test that
  /// fails: a tempo, a confident grid heard on most beats, enough recent
  /// onsets and none missing for long. Empty while [locked].
  List<String> get lockFailures {
    final p = _period;
    if (p == null) return const ['no tempo'];
    String f2(double v) => v.toStringAsFixed(2);
    return [
      if (_confidence < _confidenceNeeded) 'confidence ${f2(_confidence)} < ${f2(_confidenceNeeded)}',
      if (_coverage < _coverageNeeded) 'coverage ${f2(_coverage)} < ${f2(_coverageNeeded)}',
      if (_quietFor(p)) 'last onset ${_sinceOnset.toStringAsFixed(1)} s ago',
      if (_recentOnsets < 6) 'onsets $_recentOnsets < 6',
    ];
  }

  /// Whether the beat is steady enough to follow: the same tests as
  /// [lockFailures], without building their descriptions, since this is
  /// asked on every chunk.
  bool get locked {
    final p = _period;
    return p != null &&
        _confidence >= _confidenceNeeded &&
        _coverage >= _coverageNeeded &&
        !_quietFor(p) &&
        _recentOnsets >= 6;
  }

  // A tempo comes only from onsets, so there has been one.
  double get _sinceOnset => _now - _lastOnset!;

  /// Whether no onset has come for longer than a lock allows at period [p].
  bool _quietFor(double p) => _sinceOnset >= max(2.5, 2.5 * p);

  int get _recentOnsets => _onsets.where((o) => o.$1 > _now - _gridWindow).length;

  /// The beat grid while [locked], else null.
  BeatGrid? get grid {
    final p = _period;
    final a = _anchor;
    if (p == null || a == null || !locked) return null;
    return BeatGrid(period: _duration(p), anchor: _duration(a));
  }

  /// The first predicted beat at or after [t], or null while not [locked].
  Duration? nextBeat(Duration t) => grid?.next(t);

  /// Goes up with every tempo estimate, twice a second.
  int get estimates => _estimates;
  int _estimates = 0;

  List<(double, double)> _candidates = const [];

  TrackerReport get report {
    final last = _lastOnset;
    return TrackerReport(
      bpm: bpm,
      confidence: _confidence,
      coverage: _coverage,
      onsets: _onsets.where((o) => o.$1 > _now - _gridWindow).length,
      sinceOnset: last == null ? null : _now - last,
      level: _level,
      failures: lockFailures,
      candidates: _candidates,
      confidenceNeeded: _confidenceNeeded,
      coverageNeeded: _coverageNeeded,
    );
  }

  /// Adds the magnitudes of one frame, its bins [binHz] apart, centred on
  /// [at]. [floor] is the quietest magnitude worth hearing in the source's
  /// units, so that silence is not amplified into noise.
  MusicFrame add(Float64List magnitudes, {required double binHz, required Duration at, required double floor}) {
    final t = _seconds(at);
    _first ??= t;
    final dt = _lastFrame == null ? 0.0 : (t - _lastFrame!).clamp(0.0, 1.0);
    if (_lastFrame != null && dt > 0) {
      _intervals.add(dt);
      if (_intervals.length > 50) _intervals.removeFirst();
    }
    _lastFrame = t;
    _now = max(_now, t);

    // Loudness against a peak that falls by half in 5 s.
    final decay = pow(0.5, dt / 5).toDouble();
    var energy = 0.0;
    var bassEnergy = 0.0;
    var top = 0.0;
    final bassBins = max(1, (150 / binHz).ceil());
    for (var k = 1; k < magnitudes.length; k++) {
      final m = magnitudes[k];
      energy += m * m;
      if (k <= bassBins) bassEnergy += m * m;
      if (m > top) top = m;
    }
    energy = sqrt(energy);
    bassEnergy = sqrt(bassEnergy);
    _levelPeak = max(max(energy, floor), _levelPeak * decay);
    _bassPeak = max(max(bassEnergy, floor), _bassPeak * decay);
    _spectrumPeak = max(max(top, floor), _spectrumPeak * decay);
    final release = pow(0.5, dt / 0.15).toDouble();
    _level = max(energy / _levelPeak, _level * release);
    _bass = max(bassEnergy / _bassPeak, _bass * release);

    // Spectral flux on a log scale: the mean rise of the bass bins and of
    // all bins, half each, so kicks and bass notes lead.
    final maxBin = min(magnitudes.length, (10000 / binHz).floor());
    final compressed = Float64List(maxBin);
    for (var k = 0; k < maxBin; k++) {
      compressed[k] = log(1 + 100 * magnitudes[k] / _spectrumPeak);
    }
    var flux = 0.0;
    final previous = _previous;
    if (previous != null && previous.length == compressed.length && maxBin > 1) {
      var all = 0.0;
      var low = 0.0;
      for (var k = 1; k < maxBin; k++) {
        final rise = max(0.0, compressed[k] - previous[k]);
        all += rise;
        if (k <= bassBins) low += rise;
      }
      flux = 0.5 * all / (maxBin - 1) + 0.5 * low / min(bassBins, maxBin - 1);
    }
    _previous = compressed;

    final onset = _pick(t, flux);
    if (_lastUpdate == null || _now - _lastUpdate! >= _updateEvery) {
      _lastUpdate = _now;
      _update();
    }
    return MusicFrame(
      at: _duration(onset?.$1 ?? t),
      level: _level,
      bass: _bass,
      onset: onset != null,
      onsetFlux: onset?.$2,
      onsetThreshold: onset?.$3,
      peak: top,
      floor: floor,
      flux: flux,
      threshold: _threshold,
    );
  }

  /// Marks the previous frame as an onset when its flux peaked well above
  /// the last second's (untuned, 1.5 standard deviations and twice the
  /// mean, which steady noise does not reach), and returns its time, flux
  /// and threshold.
  (double, double, double)? _pick(double t, double flux) {
    _flux.add((t, flux));
    while (_flux.first.$1 < t - _fluxWindow) {
      _flux.removeFirst();
    }
    final f1 = _f1;
    final f2 = _f2;
    _f2 = f1;
    _f1 = (t, flux);
    // The threshold needs half a second of history to mean anything.
    if (f1 == null || f2 == null || t - _first! < 0.5) return null;
    final values = [for (final (_, v) in _flux) v];
    final mean = values.reduce((a, b) => a + b) / values.length;
    final sd = sqrt(values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / values.length);
    final threshold = max(max(mean + _sds * sd, _means * mean), 0.01);
    _threshold = threshold;
    final (at, value) = f1;
    if (value <= threshold || value < f2.$2 || value <= flux) return null;
    if (_lastOnset != null && at - _lastOnset! < _minGap) return null;
    _lastOnset = at;
    _onsets.add((at, value - threshold));
    while (_onsets.isNotEmpty && _onsets.first.$1 < _now - _tempoWindow) {
      _onsets.removeFirst();
    }
    return (at, value, threshold);
  }

  /// Re-estimates the tempo, then fits the beat grid.
  void _update() {
    _estimates++;
    while (_onsets.isNotEmpty && _onsets.first.$1 < _now - _tempoWindow) {
      _onsets.removeFirst();
    }
    if (_onsets.length < 4) {
      _confidence = 0;
      _candidates = const [];
      return;
    }
    final estimate = _tempo();
    if (estimate != null) {
      final current = _period;
      if (current == null || _ratio(estimate, current) < 1.04) {
        _fit(estimate, keep: current != null);
        _candidate = null;
      } else if (_candidate != null && _ratio(estimate, _candidate!) < 1.04) {
        if (++_candidateHits >= 2) {
          _anchor = null;
          _fit(estimate, keep: false);
          _candidate = null;
        }
      } else {
        _candidate = estimate;
        _candidateHits = 1;
      }
    }
    if (_period != null) {
      if (estimate == null || _candidate != null) _fit(_period!, keep: true);
      _confidence = _gridConfidence();
      _coverage = _gridCoverage();
    }
  }

  /// The beat period that best explains the intervals between all pairs of
  /// recent onsets, with its double and triple, nearer 120 BPM preferred.
  double? _tempo() {
    final pMin = 60 / maxBpm;
    final pMax = 60 / minBpm;
    final step = 0.002;
    final maxLag = 3 * pMax + 0.05;
    final bins = Float64List((maxLag / step).ceil() + 1);
    final typical = _intervals.isEmpty ? 0.01 : (_intervals.toList()..sort())[_intervals.length ~/ 2];
    final sigma = max(0.01, 0.5 * typical);
    final spread = (3 * sigma / step).ceil();
    final onsets = _onsets.toList();
    final weights = [for (final (t, s) in onsets) s * exp(-(_now - t) / _recency)];
    for (var i = 0; i < onsets.length; i++) {
      for (var j = i + 1; j < onsets.length; j++) {
        final d = onsets[j].$1 - onsets[i].$1;
        if (d > maxLag) break;
        final w = weights[i] * weights[j];
        final c = (d / step).round();
        for (var b = max(0, c - spread); b <= min(bins.length - 1, c + spread); b++) {
          final x = (b * step - d) / sigma;
          bins[b] += w * exp(-0.5 * x * x);
        }
      }
    }
    double h(double lag) {
      final x = lag / step;
      final i = x.floor();
      if (i + 1 >= bins.length) return 0;
      return bins[i] + (bins[i + 1] - bins[i]) * (x - i);
    }

    final scores = <(double, double)>[];
    for (var p = pMin; p <= pMax; p += step) {
      final bpm = 60 / p;
      final octaves = log(bpm / 120) / ln2;
      scores.add((p, (h(p) + 0.5 * h(2 * p) + 0.33 * h(3 * p)) * exp(-0.5 * octaves * octaves)));
    }
    final peaks = <(double, double)>[
      for (var i = 0; i < scores.length; i++)
        if ((i == 0 || scores[i].$2 > scores[i - 1].$2) && (i == scores.length - 1 || scores[i].$2 >= scores[i + 1].$2))
          scores[i],
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    if (peaks.isEmpty || peaks.first.$2 <= 0) {
      _candidates = const [];
      return null;
    }
    final best = peaks.first.$2;
    _candidates = [for (final (p, s) in peaks.take(3)) (60 / p, s / best)];
    return peaks.first.$1;
  }

  /// Fits the beat grid near [p]: the phase that lines up the most onset
  /// strength (or the current one, when [keep]), then a weighted straight
  /// line through the onsets near it for the exact period and phase.
  void _fit(double p, {required bool keep}) {
    final recent = _onsets.where((o) => o.$1 > _now - _gridWindow).toList();
    if (recent.isEmpty) return;
    double weight(double t, double s) => s * exp(-(_now - t) / _recency);
    double distance(double t, double phase) {
      final x = (t - phase) / p;
      return (x - x.round()).abs() * p;
    }

    var phase = _anchor;
    if (!keep || phase == null) {
      var best = -1.0;
      for (final (c, _) in recent.where((o) => o.$1 > _now - 4)) {
        var score = 0.0;
        for (final (t, s) in recent) {
          final d = distance(t, c) / (0.08 * p);
          score += weight(t, s) * exp(-0.5 * d * d);
        }
        if (score > best) {
          best = score;
          phase = c;
        }
      }
    }
    if (phase == null) return;

    var sw = 0.0, sn = 0.0, st = 0.0, snn = 0.0, snt = 0.0;
    var count = 0;
    var last = 0;
    for (final (t, s) in recent) {
      if (distance(t, phase) > 0.15 * p) continue;
      final n = ((t - phase) / p).round();
      final w = weight(t, s);
      sw += w;
      sn += w * n;
      st += w * t;
      snn += w * n * n;
      snt += w * n * t;
      count++;
      last = max(last, n);
    }
    final det = sw * snn - sn * sn;
    if (count >= 4 && det.abs() > 1e-12) {
      final slope = (sw * snt - sn * st) / det;
      final intercept = (st - slope * sn) / sw;
      if (_ratio(slope, p) < 1.1) {
        _period = slope;
        _anchor = intercept + slope * last;
        return;
      }
    }
    _period = p;
    _anchor = phase;
  }

  /// The share of recent onset strength on the beat grid, with onsets half
  /// way between beats counting half.
  double _gridConfidence() {
    final p = _period!;
    final a = _anchor!;
    var on = 0.0;
    var total = 0.0;
    for (final (t, s) in _onsets.where((o) => o.$1 > _now - _gridWindow)) {
      final x = (t - a) / p;
      final d = (x - x.round()).abs();
      total += s;
      if (d < 0.1) {
        on += s;
      } else if ((d - 0.5).abs() < 0.1) {
        on += 0.5 * s;
      }
    }
    return total == 0 ? 0 : on / total;
  }

  /// The share of the grid's beats in the last few seconds with an onset
  /// within a tenth of a beat.
  double _gridCoverage() {
    final p = _period!;
    final a = _anchor!;
    final from = max(_now - _gridWindow, _first! + 0.5);
    var beats = 0;
    var heard = 0;
    for (var b = a + ((from - a) / p).ceil() * p; b <= _now; b += p) {
      beats++;
      if (_onsets.any((o) => (o.$1 - b).abs() < 0.1 * p)) heard++;
    }
    return beats == 0 ? 0 : heard / beats;
  }

  static double _ratio(double a, double b) => max(a, b) / min(a, b);
  static double _seconds(Duration d) => d.inMicroseconds / 1e6;
  static Duration _duration(double s) => Duration(microseconds: (s * 1e6).round());
}
