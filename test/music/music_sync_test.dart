// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/log/logger.dart';
import 'package:lumen/music/audio_input.dart';
import 'package:lumen/music/music_settings.dart';
import 'package:lumen/music/music_sync.dart';
import 'package:lumen/music/music_trace.dart';
import 'package:lumen/sim/click_track.dart';
import 'package:lumen/sim/simulated_audio.dart';
import 'package:lumen/sim/simulated_ble.dart';
import 'package:lumen/state/app_services.dart';
import 'package:lumen/state/home_controller.dart';
import 'package:lumen/state/music_store.dart';

void main() {
  late SimulatedBleCentral central;
  late SimulatedAudioInput input;
  late MemoryMusicStore store;
  late HomeController home;
  late MusicSync sync;
  const before = LightState(on: true, brightness: 100, color: XyColor(0.3, 0.3));

  /// Runs [body] in fake time with two bulbs, Desk and Lamp, added; Lamp is
  /// in a room called Den.
  void run(void Function(FakeAsync async) body, {SimulatedAudioInput? audio, Duration latency = Duration.zero}) =>
      fakeAsync((async) {
        central = SimulatedBleCentral(scanDelay: Duration.zero, latency: latency)
          ..addBulb(SimulatedHueBulb(id: 'aa', name: 'Desk', state: before))
          ..addBulb(SimulatedHueBulb(id: 'bb', name: 'Lamp', state: before));
        input = audio ?? SimulatedAudioInput();
        store = MemoryMusicStore();
        home = HomeController(AppServices.simulated(central: central, audio: input, musicStore: store));
        home.load();
        async.flushMicrotasks();
        for (final id in ['aa', 'bb']) {
          home.scanBluetooth().firstWhere((b) => b.deviceId == id).then(home.addBluetoothLight);
          async.elapse(const Duration(seconds: 2));
        }
        home.createRoom('Den', [HomeController.bleId('bb')]);
        sync = MusicSync(home)..load();
        async.flushMicrotasks();
        body(async);
        sync.dispose();
        async.elapse(const Duration(seconds: 1));
      });

  /// The fake times at which [bulb] reached full brightness, sampled every
  /// 5 ms for [over].
  List<Duration> peaks(FakeAsync async, String bulb, Duration over) {
    final out = <Duration>[];
    var was = central.bulbs[bulb]!.state.brightness == 254;
    final end = async.elapsed + over;
    while (async.elapsed < end) {
      async.elapse(const Duration(milliseconds: 5));
      final full = central.bulbs[bulb]!.state.brightness == 254;
      if (full && !was) out.add(async.elapsed);
      was = full;
    }
    return out;
  }

  /// How far [t] is from the nearest beat of a 120 BPM track that started
  /// at [start], shifted by [shift].
  Duration offBeat(Duration t, Duration start, Duration shift) {
    final beats = ClickTrack(bpm: 120).beatTimes(t - start + const Duration(seconds: 1));
    return beats.map((b) => (start + b + shift - t).abs()).reduce((a, b) => a < b ? a : b);
  }

  test('pulses the lights on the beat of the music, a little ahead for the lights to catch up', () {
    run((async) {
      sync.start();
      async.flushMicrotasks();
      final start = async.elapsed;
      expect(sync.phase, MusicSyncPhase.listening);
      expect(input.listening, AudioSource.microphone);
      async.elapse(const Duration(seconds: 7));
      expect(sync.phase, MusicSyncPhase.following);
      expect(sync.bpm, closeTo(120, 1.5));
      final seen = peaks(async, 'aa', const Duration(seconds: 4));
      expect(seen.length, inInclusiveRange(7, 9));
      for (final p in seen) {
        expect(offBeat(p, start, -MusicSync.lead), lessThan(const Duration(milliseconds: 30)));
      }
      expect(sync.beats, greaterThan(8));
    });
  });

  test('the timing setting moves the lights later', () {
    run((async) {
      sync.update(sync.settings.copyWith(timing: const Duration(milliseconds: 200)));
      sync.start();
      async.flushMicrotasks();
      final start = async.elapsed;
      async.elapse(const Duration(seconds: 7));
      final seen = peaks(async, 'aa', const Duration(seconds: 3));
      expect(seen, isNotEmpty);
      for (final p in seen) {
        final shift = const Duration(milliseconds: 200) - MusicSync.lead;
        expect(offBeat(p, start, shift), lessThan(const Duration(milliseconds: 30)));
      }
    });
  });

  test('stopping puts the lights back as they were', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 8));
      sync.stop();
      async.elapse(const Duration(seconds: 1));
      expect(sync.phase, MusicSyncPhase.off);
      expect(input.listening, isNull);
      expect(central.bulbs['aa']!.state.brightness, 100);
      expect(home.light(HomeController.bleId('aa'))!.state.color, before.color);
    });
  });

  test('a room setting moves only the lights of that room', () {
    run((async) {
      sync.update(sync.settings.copyWith(roomId: home.rooms.single.id));
      sync.start();
      async.elapse(const Duration(seconds: 7));
      expect(peaks(async, 'bb', const Duration(seconds: 2)), isNotEmpty);
      expect(central.bulbs['aa']!.state.brightness, 100);
    });
  });

  test('asks for the microphone permission when starting needs it', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 1));
      expect(input.permissionRequests, 1);
      expect(sync.phase, MusicSyncPhase.listening);
    }, audio: SimulatedAudioInput(statuses: {AudioSource.microphone: SourceStatus.needsPermission}));
  });

  test('a refused permission stops it with the reason, and a permanent refusal points to settings', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 1));
      expect(sync.phase, MusicSyncPhase.failed);
      expect(sync.problem, contains('microphone'));
      expect(sync.problemNeedsSettings, isFalse);
      input.statuses[AudioSource.microphone] = SourceStatus.denied;
      sync.start();
      async.elapse(const Duration(seconds: 1));
      expect(sync.problemNeedsSettings, isTrue);
      sync.openSettings();
      expect(input.settingsOpened, 1);
    }, audio: SimulatedAudioInput(grant: false, statuses: {AudioSource.microphone: SourceStatus.needsPermission}));
  });

  test('a source the phone does not have cannot start, and says why', () {
    run(
      (async) {
        sync.update(sync.settings.copyWith(source: AudioSource.capture));
        sync.start();
        async.elapse(const Duration(seconds: 1));
        expect(sync.phase, MusicSyncPhase.failed);
        expect(sync.problem, 'Needs Android 10 or later');
        expect(sync.sources[AudioSource.capture]!.state, SourceState.unsupported);
      },
      audio: SimulatedAudioInput(
        statuses: {
          AudioSource.capture: const SourceStatus(SourceState.unsupported, reason: 'Needs Android 10 or later'),
        },
      ),
    );
  });

  test('an error from the source stops it, puts the lights back and says what happened', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 8));
      input.fail(const AudioInputError('cancelled', 'Recording was not allowed.'));
      async.elapse(const Duration(seconds: 1));
      expect(sync.phase, MusicSyncPhase.failed);
      expect(sync.problem, 'Recording was not allowed.');
      expect(central.bulbs['aa']!.state.brightness, 100);
    });
  });

  test('the source ending, as when Android stops a capture, stops music sync', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 3));
      input.end();
      async.elapse(const Duration(seconds: 1));
      expect(sync.phase, MusicSyncPhase.off);
      expect(central.bulbs['aa']!.state.brightness, 100);
    });
  });

  test("follows the beat from the phone's sound, 20 spectra a second", () {
    run((async) {
      sync.update(sync.settings.copyWith(source: AudioSource.phoneSound));
      sync.start();
      async.elapse(const Duration(seconds: 8));
      expect(input.listening, AudioSource.phoneSound);
      expect(sync.bpm, closeTo(120, 3));
      expect(peaks(async, 'aa', const Duration(seconds: 2)), isNotEmpty);
    });
  });

  test('changing the source while running restarts on the new one', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 2));
      sync.update(sync.settings.copyWith(source: AudioSource.phoneSound));
      async.elapse(const Duration(seconds: 1));
      expect(input.listening, AudioSource.phoneSound);
      expect(input.listens, 2);
      // A fresh run with no lock yet: Auto may already follow the hits.
      expect(sync.phase, isIn([MusicSyncPhase.listening, MusicSyncPhase.hits]));
    });
  });

  test('glow follows the loudness a few times a second and never on the beat', () {
    run((async) {
      sync.update(sync.settings.copyWith(style: MusicStyle.glow));
      sync.start();
      async.elapse(const Duration(seconds: 6));
      final desk = central.bulbs['aa']!;
      final writes = desk.writes.length;
      async.elapse(const Duration(seconds: 2));
      expect(desk.writes.length - writes, inInclusiveRange(4, 9));
    });
  });

  test('without a beat it keeps listening, and after a while says how to help it', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 5));
      expect(sync.phase, MusicSyncPhase.listening);
      expect(sync.hint, isNull);
      async.elapse(const Duration(seconds: 7));
      expect(sync.hint, contains('nearer'));
    }, audio: SimulatedAudioInput(silent: true));
  });

  test('settings are saved and come back', () {
    run((async) {
      sync.update(sync.settings.copyWith(style: MusicStyle.colours, strength: 0.4));
      async.flushMicrotasks();
      final again = MusicSync(home)..load();
      async.flushMicrotasks();
      expect(again.settings.style, MusicStyle.colours);
      expect(again.settings.strength, 0.4);
      again.dispose();
    });
  });

  test('reads which sources are ready when it loads', () {
    run((async) {
      expect(sync.sources[AudioSource.microphone], SourceStatus.ready);
      expect(sync.sources[AudioSource.phoneSound]!.state, SourceState.needsPermission);
    }, audio: SimulatedAudioInput(statuses: {AudioSource.phoneSound: SourceStatus.needsPermission}));
  });

  List<String> musicLines() => [
    for (final e in home.log.entries)
      if (e.tag == LogTag.music) e.message,
  ];

  test('with the tracking log on, it logs the input, estimates, onsets, the lock and beats', () {
    run((async) {
      sync.update(sync.settings.copyWith(trackingLog: true));
      async.flushMicrotasks();
      sync.start();
      async.elapse(const Duration(seconds: 8));
      final lines = musicLines();
      for (final kind in ['music: input ', 'music: estimate ', 'music: onset ', 'music: locked', 'music: beat ']) {
        expect(lines.any((l) => l.startsWith(kind)), isTrue, reason: 'no "$kind" line in ${lines.take(5)}');
      }
      expect(lines.firstWhere((l) => l.startsWith('music: beat ')), contains('ms'));
      expect(sync.report!.locked, isTrue);
    });
  });

  test('without a beat the estimates name the failed lock tests', () {
    run((async) {
      sync.update(sync.settings.copyWith(trackingLog: true));
      async.flushMicrotasks();
      sync.start();
      async.elapse(const Duration(seconds: 6));
      expect(musicLines().where((l) => l.startsWith('music: estimate ')).last, contains('not locked'));
    }, audio: SimulatedAudioInput(silent: true));
  });

  test('with the tracking log off, nothing is logged under music', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 8));
      expect(musicLines(), isEmpty);
    });
  });

  test('muting the simulated music leaves only the noise floor', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 7));
      expect(sync.phase, MusicSyncPhase.following);
      input.muted = true;
      async.elapse(const Duration(seconds: 12));
      expect(sync.phase, isNot(MusicSyncPhase.following));
    });
  });

  /// Mutes the music and waits, up to 10 s, until the lock goes: the noise
  /// floor keeps the old grid for a few seconds.
  void muteUntilLost(FakeAsync async, {bool noise = false}) {
    if (noise) {
      input.noisy = true;
    } else {
      input.muted = true;
    }
    for (var i = 0; i < 100 && sync.phase == MusicSyncPhase.following; i++) {
      async.elapse(const Duration(milliseconds: 100));
    }
  }

  test('when the beat goes, it keeps pulsing at the same tempo for 8 beats or 4 s', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 7));
      expect(sync.phase, MusicSyncPhase.following);
      muteUntilLost(async);
      expect(sync.phase, MusicSyncPhase.holding);
      expect(sync.bpm, closeTo(120, 1.5));
      final held = peaks(async, 'aa', const Duration(seconds: 3));
      expect(held.length, inInclusiveRange(5, 7), reason: 'about two flashes a second while holding');
      expect(sync.phase, MusicSyncPhase.holding, reason: 'holding lasts 4 s at 120 BPM');
      async.elapse(const Duration(milliseconds: 1500));
      expect(sync.phase, MusicSyncPhase.breathing);
      expect(sync.running, isTrue);
    });
  });

  test('a beat that comes back while holding is followed again without a double flash', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 7));
      muteUntilLost(async);
      expect(sync.phase, MusicSyncPhase.holding);
      input.muted = false;
      final flashes = peaks(async, 'aa', const Duration(seconds: 6));
      expect(sync.phase, MusicSyncPhase.following);
      for (var i = 1; i < flashes.length; i++) {
        expect(flashes[i] - flashes[i - 1], greaterThanOrEqualTo(MusicSync.minFlashGap));
      }
    });
  });

  test('glow does not hold a beat', () {
    run((async) {
      sync.update(sync.settings.copyWith(style: MusicStyle.glow));
      async.flushMicrotasks();
      sync.start();
      async.elapse(const Duration(seconds: 7));
      muteUntilLost(async);
      async.elapse(const Duration(seconds: 1));
      expect(sync.phase, MusicSyncPhase.listening);
    });
  });

  test('breathing rises and falls once a bar at the held tempo while there is sound, and never flashes', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 7));
      muteUntilLost(async, noise: true);
      async.elapse(const Duration(seconds: 5));
      expect(sync.phase, MusicSyncPhase.breathing);
      final seen = <int>[];
      for (var i = 0; i < 80; i++) {
        async.elapse(const Duration(milliseconds: 50));
        seen.add(central.bulbs['aa']!.state.brightness!);
      }
      expect(seen.reduce(max) - seen.reduce(min), greaterThan(40), reason: 'it moves');
      expect(seen, isNot(contains(HueRange.maxBrightness)), reason: 'no flashes');
    });
  });

  test('silence while breathing settles the lights at rest', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 7));
      muteUntilLost(async);
      async.elapse(const Duration(seconds: 5));
      expect(sync.phase, MusicSyncPhase.breathing);
      async.elapse(const Duration(seconds: 3));
      final settled = central.bulbs['aa']!.state.brightness;
      for (var i = 0; i < 20; i++) {
        async.elapse(const Duration(milliseconds: 100));
        expect(central.bulbs['aa']!.state.brightness, settled);
      }
      expect(sync.phase, MusicSyncPhase.breathing, reason: 'still waiting for the beat');
    });
  });

  test('feeds the trace with frames and beats while running, and clears it on start', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 8));
      expect(sync.trace.onsets, isNotEmpty);
      expect(sync.trace.beats.where((b) => b.$2 == BeatOutcome.fired), isNotEmpty);
      sync.stop();
      async.flushMicrotasks();
      sync.start();
      async.flushMicrotasks();
      expect(sync.trace.beats, isEmpty);
    });
  });

  test('the tracker follows the sensitivity and steadiness settings, at start and while running', () {
    run((async) {
      sync.update(sync.settings.copyWith(steadiness: 0, trackingLog: true));
      async.flushMicrotasks();
      sync.start();
      async.elapse(const Duration(seconds: 1));
      expect(sync.report!.confidenceNeeded, closeTo(0.35, 1e-9));
      sync.update(sync.settings.copyWith(steadiness: 1, sensitivity: 0.9));
      async.elapse(const Duration(seconds: 1));
      expect(sync.report!.confidenceNeeded, closeTo(0.75, 1e-9));
      expect(
        musicLines().where((l) => l.startsWith('music: estimate ')).last,
        contains('sensitivity 0.90, steadiness 1.00'),
      );
    });
  });

  void follow(FakeAsync async, FollowMode mode) {
    sync.update(sync.settings.copyWith(follow: mode));
    async.flushMicrotasks();
  }

  test('hits flash on each onset as it is heard, without waiting for a steady beat', () {
    run((async) {
      follow(async, FollowMode.hits);
      sync.start();
      async.flushMicrotasks();
      final start = async.elapsed;
      final flashes = peaks(async, 'aa', const Duration(seconds: 3));
      expect(sync.phase, MusicSyncPhase.hits);
      expect(flashes.length, inInclusiveRange(4, 6), reason: 'the kicks of 2.5 s heard, two a second');
      for (final f in flashes) {
        expect(
          offBeat(f, start, Duration.zero),
          lessThan(const Duration(milliseconds: 120)),
          reason: 'close to a kick',
        );
      }
      expect(sync.trace.beats.where((b) => b.$2 == BeatOutcome.hit), isNotEmpty);
    });
  });

  test('hits never come closer than the flash gap', () {
    run((async) {
      follow(async, FollowMode.hits);
      sync.update(sync.settings.copyWith(sensitivity: 1));
      async.flushMicrotasks();
      sync.start();
      final flashes = peaks(async, 'aa', const Duration(seconds: 4));
      for (var i = 1; i < flashes.length; i++) {
        expect(flashes[i] - flashes[i - 1], greaterThanOrEqualTo(MusicSync.minFlashGap));
      }
    });
  });

  test('hits rest the lights when the onsets stop', () {
    run((async) {
      follow(async, FollowMode.hits);
      sync.start();
      async.elapse(const Duration(seconds: 3));
      input.muted = true;
      async.elapse(const Duration(seconds: 8));
      expect(sync.phase, MusicSyncPhase.listening);
      final settled = central.bulbs['aa']!.state.brightness;
      async.elapse(const Duration(seconds: 1));
      expect(central.bulbs['aa']!.state.brightness, settled);
      expect(settled, lessThan(HueRange.maxBrightness));
    });
  });

  test('auto follows hits until the beat locks, then the predicted beat', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(milliseconds: 2500));
      expect(sync.phase, MusicSyncPhase.hits);
      async.elapse(const Duration(seconds: 5));
      expect(sync.phase, MusicSyncPhase.following);
    });
  });

  test('beat mode waits for the lock, flashing nothing before it', () {
    run((async) {
      follow(async, FollowMode.beat);
      sync.start();
      final early = peaks(async, 'aa', const Duration(milliseconds: 2500));
      expect(sync.phase, MusicSyncPhase.listening);
      expect(early, isEmpty);
    });
  });

  test('the trace tells the screen about every chunk, about fifty a second from the microphone', () {
    run((async) {
      var told = 0;
      sync.trace.addListener(() => told++);
      sync.start();
      async.elapse(const Duration(seconds: 2));
      expect(told, inInclusiveRange(90, 110));
    });
  });

  for (final (source, advice) in [
    (AudioSource.phoneSound, 'playing on this phone'),
    (AudioSource.capture, 'block audio capture'),
  ]) {
    test('without a beat from ${source.name} the hint says what to check', () {
      run((async) {
        sync.update(sync.settings.copyWith(source: source));
        async.flushMicrotasks();
        sync.start();
        async.elapse(const Duration(seconds: 12));
        expect(sync.hint, contains(advice));
      }, audio: SimulatedAudioInput(silent: true));
    });
  }

  test('choosing a room while running puts back the lights that leave it', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 8));
      sync.update(sync.settings.copyWith(roomId: home.rooms.single.id));
      async.elapse(const Duration(seconds: 1));
      expect(central.bulbs['aa']!.state.brightness, before.brightness);
      expect(sync.targets.map((l) => l.name), ['Lamp']);
    });
  });

  test('a beat that comes while the lights are still busy is dropped, not queued', () {
    run((async) {
      sync.update(sync.settings.copyWith(follow: FollowMode.beat));
      async.flushMicrotasks();
      sync.start();
      async.elapse(const Duration(seconds: 10));
      expect(sync.trace.beats.where((b) => b.$2 == BeatOutcome.busy), isNotEmpty);
    }, latency: const Duration(milliseconds: 700));
  });

  test('an error that is not an audio error still stops it, and says so', () {
    run((async) {
      sync.start();
      async.elapse(const Duration(seconds: 1));
      input.fail(StateError('the stream broke'));
      async.flushMicrotasks();
      expect(sync.phase, MusicSyncPhase.failed);
      expect(sync.problem, contains('the stream broke'));
    });
  });

  test('the simulator refuses to play a source that is not ready', () async {
    final audio = SimulatedAudioInput(statuses: {AudioSource.capture: SourceStatus.needsPermission});
    await expectLater(audio.listen(AudioSource.capture), emitsError(isA<AudioInputError>()));
  });

  test('picked lights are the only ones that move, and a light dropped while running is put back', () {
    run((async) {
      sync.update(sync.settings.copyWith(lightIds: [HomeController.bleId('aa'), HomeController.bleId('bb')]));
      async.flushMicrotasks();
      expect(sync.targets.map((l) => l.name), ['Desk', 'Lamp']);
      sync.start();
      async.elapse(const Duration(seconds: 8));
      sync.update(sync.settings.copyWith(lightIds: [HomeController.bleId('bb')]));
      async.elapse(const Duration(seconds: 1));
      expect(sync.targets.map((l) => l.name), ['Lamp']);
      expect(central.bulbs['aa']!.state.brightness, before.brightness);
    });
  });

  test('a second run tells the screen about the music as often as the first', () {
    run((async) {
      var told = 0;
      sync.addListener(() => told++);
      sync.start();
      async.elapse(const Duration(seconds: 8));
      sync.stop();
      async.flushMicrotasks();
      sync.start();
      async.flushMicrotasks();
      told = 0;
      async.elapse(const Duration(seconds: 2));
      expect(told, greaterThanOrEqualTo(15), reason: 'about ten updates a second, not only phase changes');
    });
  });

  test('only flashes that reach the lights count as beats', () {
    run((async) {
      sync.update(sync.settings.copyWith(follow: FollowMode.hits));
      async.flushMicrotasks();
      sync.start();
      async.elapse(const Duration(milliseconds: 5500));
      final sent = sync.trace.beats.where((b) => b.$2 == BeatOutcome.hit).length;
      final dropped = sync.trace.beats.where((b) => b.$2 == BeatOutcome.busy || b.$2 == BeatOutcome.tooSoon).length;
      expect(dropped, greaterThan(0), reason: 'slow lights drop some hits');
      expect(sync.beats, sent);
    }, latency: const Duration(milliseconds: 700));
  });

  test('a source picked while starting is the one it listens to', () {
    run((async) {
      sync.start();
      sync.update(sync.settings.copyWith(source: AudioSource.phoneSound));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      expect(input.listening, AudioSource.phoneSound);
      expect(sync.running, isTrue);
    });
  });

  test('no beat fires once the lights have gone on to breathing', () {
    // Whether a beat is still timed when holding runs out depends on where
    // the beat falls, so try muting at offsets across a whole beat.
    for (var offset = 0; offset < 500; offset += 50) {
      run((async) {
        sync.update(sync.settings.copyWith(follow: FollowMode.beat));
        async.flushMicrotasks();
        sync.start();
        async.elapse(Duration(milliseconds: 7000 + offset));
        muteUntilLost(async);
        for (var i = 0; i < 1000 && sync.phase != MusicSyncPhase.breathing; i++) {
          async.elapse(const Duration(milliseconds: 5));
        }
        expect(sync.phase, MusicSyncPhase.breathing);
        final before = sync.trace.beats.toSet();
        async.elapse(const Duration(milliseconds: 400));
        expect(sync.trace.beats.toSet().difference(before), isEmpty, reason: 'muted at +$offset ms');
      });
    }
  });

  test('the bar for a hit follows Sensitivity, and the trace draws it', () {
    run((async) {
      expect(sync.hitMargin, closeTo(1.6, 1e-9));
      expect(sync.trace.hitMargin, closeTo(1.6, 1e-9));
      sync.update(sync.settings.copyWith(sensitivity: 0));
      async.flushMicrotasks();
      expect(sync.hitMargin, closeTo(2.5, 1e-9));
      sync.update(sync.settings.copyWith(sensitivity: 1));
      async.flushMicrotasks();
      expect(sync.hitMargin, closeTo(1.2, 1e-9));
      expect(sync.trace.hitMargin, closeTo(1.2, 1e-9));
    });
  });
}
