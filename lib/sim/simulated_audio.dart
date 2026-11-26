// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:typed_data';

import '../music/audio_chunk.dart';
import '../music/audio_input.dart';
import '../music/spectrum.dart';
import 'click_track.dart';

/// Audio sources that play a [ClickTrack], for tests and demo mode. The
/// microphone and audio capture give 20 ms of samples every 20 ms; the
/// phone's sound gives a spectrum every 50 ms, as the Visualizer does. The
/// track starts when a source is listened to.
class SimulatedAudioInput implements AudioInput {
  SimulatedAudioInput({this.bpm = 120, Map<AudioSource, SourceStatus>? statuses, this.grant = true, this.silent = false})
    : statuses = {for (final s in AudioSource.values) s: SourceStatus.ready, ...?statuses};

  final double bpm;

  /// Each source's status; tests change them.
  final Map<AudioSource, SourceStatus> statuses;

  /// Whether asking for the permission gets it.
  bool grant;

  /// Plays only the noise floor: no beat to find.
  bool silent;

  /// Plays only the noise floor from now on, as when the music stops.
  bool muted = false;

  /// Plays steady noise from now on, as loud as the music: sound with no
  /// beat. Muting wins.
  bool noisy = false;

  int permissionRequests = 0;
  int settingsOpened = 0;
  int listens = 0;

  /// The source playing now, or null.
  AudioSource? listening;

  StreamController<AudioChunk>? _out;
  Timer? _timer;

  static const sampleRate = 44100;
  static const _pcmEvery = Duration(milliseconds: 20);
  static const _fftEvery = Duration(milliseconds: 50);

  @override
  Future<SourceStatus> status(AudioSource source) async => statuses[source]!;

  @override
  Future<SourceStatus> requestPermission(AudioSource source) async {
    permissionRequests++;
    if (grant) {
      for (final s in AudioSource.values) {
        if (statuses[s]!.state == SourceState.needsPermission) statuses[s] = SourceStatus.ready;
      }
    }
    return statuses[source]!;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Stream<AudioChunk> listen(AudioSource source) {
    late final StreamController<AudioChunk> out;
    out = StreamController<AudioChunk>(
      onListen: () {
        listens++;
        listening = source;
        _out = out;
        final track = ClickTrack(bpm: bpm, sampleRate: sampleRate, hats: true, level: silent ? 0 : 0.8);
        // The noise floor alone, in step with the track, for while muted.
        final floor = ClickTrack(bpm: bpm, sampleRate: sampleRate, level: 0);
        List<double> take(int n) {
          final music = track.take(n);
          final quiet = floor.take(n);
          if (muted) return quiet;
          return noisy ? [for (final v in quiet) 30 * v] : music;
        }
        if (source == AudioSource.phoneSound) {
          var ticks = 0;
          final history = <double>[];
          _timer = Timer.periodic(_fftEvery, (_) {
            ticks++;
            history.addAll(take(sampleRate * _fftEvery.inMilliseconds ~/ 1000));
            if (history.length > 4096) history.removeRange(0, history.length - 4096);
            if (history.length < 1024) return;
            // The Visualizer's normalised bytes run to about 128.
            final m = Spectrum.magnitudes(history.sublist(history.length - 1024));
            for (var i = 0; i < m.length; i++) {
              m[i] *= 512;
            }
            out.add(FftChunk(m, sampleRate: sampleRate, at: _fftEvery * ticks));
          });
        } else {
          final count = sampleRate * _pcmEvery.inMilliseconds ~/ 1000;
          _timer = Timer.periodic(
            _pcmEvery,
            (_) => out.add(PcmChunk(Float64List.fromList(take(count)), sampleRate: sampleRate)),
          );
        }
      },
      onCancel: () {
        if (identical(_out, out)) {
          _timer?.cancel();
          listening = null;
          _out = null;
        }
      },
    );
    final status = statuses[source]!;
    if (status.state != SourceState.ready) {
      return Stream.error(AudioInputError('unavailable', status.reason ?? 'Not allowed'));
    }
    return out.stream;
  }

  /// Fails the playing source with [error].
  void fail(Object error) => _out?.addError(error);

  /// Ends the playing source, as when Android stops a capture.
  void end() {
    final out = _out;
    _timer?.cancel();
    listening = null;
    _out = null;
    out?.close();
  }
}
