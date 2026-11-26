// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/music/audio_input.dart';
import 'package:lumen/music/music_settings.dart';

import 'harness.dart';

void main() {
  initE2eBinding();

  Future<void> openMusicSync(WidgetTester tester) async {
    await tester.tapAndSettle(find.byKey(const ValueKey('open-music-sync')));
    await tester.pumpUntilFound(find.text('Listen to'));
  }

  Future<void> tapInList(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).last);
    await tester.tapAndSettle(finder);
  }

  e2e('pulse a bulb with the music from the microphone, then stop and get the light back', (tester, world) async {
    final bulb = world.bulb('b1', name: 'Desk lamp')..state = const LightState(on: true, brightness: 120);
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await openMusicSync(tester);

    expect(find.text('Lights follow the music'), findsOneWidget);
    await tester.tapAndSettle(find.byKey(const ValueKey('music-start')));
    expect(world.audio.listening, AudioSource.microphone);
    await tester.pumpUntilFound(find.text('Finding the beat'));
    await tester.pumpUntilFound(find.text('120 BPM'), timeout: const Duration(seconds: 15));

    var flashes = 0;
    var was = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final full = bulb.state.brightness == HueRange.maxBrightness;
      if (full && !was) flashes++;
      was = full;
    }
    expect(flashes, inInclusiveRange(5, 7), reason: 'about two flashes a second for 3 s');

    await tester.tapAndSettle(find.byKey(const ValueKey('music-stop')));
    await tester.pumpUntil(() => bulb.state.brightness == 120);
    expect(world.audio.listening, isNull);
    expect(find.text('Lights follow the music'), findsOneWidget);
  });

  e2e('the sources say what they need, and one the phone lacks cannot be picked', (tester, world) async {
    world.audio.statuses[AudioSource.capture] = const SourceStatus(
      SourceState.unsupported,
      reason: 'Needs Android 10 or later',
    );
    world.audio.statuses[AudioSource.phoneSound] = SourceStatus.needsPermission;
    await world.launch(tester);
    await openMusicSync(tester);

    expect(find.text('Needs Android 10 or later'), findsOneWidget);
    expect(find.text('Needs the microphone permission'), findsOneWidget);
    await tapInList(tester, find.byKey(const ValueKey('music-source-capture')));
    expect(world.music.settings.source, AudioSource.microphone, reason: 'capture is unsupported');

    await tapInList(tester, find.byKey(const ValueKey('music-source-phoneSound')));
    expect(world.music.settings.source, AudioSource.phoneSound);
    expect((await world.musicStore.load())!.source, AudioSource.phoneSound, reason: 'saved');
  });

  e2e('starting asks for the microphone permission, and a refusal points to Android settings', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    world.audio
      ..statuses[AudioSource.microphone] = SourceStatus.needsPermission
      ..grant = false;
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await openMusicSync(tester);

    await tester.tapAndSettle(find.byKey(const ValueKey('music-start')));
    expect(world.audio.permissionRequests, 1);
    await tester.pumpUntilFound(find.textContaining('needs the microphone permission'));

    world.audio.statuses[AudioSource.microphone] = SourceStatus.denied;
    await tester.tapAndSettle(find.byKey(const ValueKey('music-start')));
    await tester.pumpUntilFound(find.byKey(const ValueKey('music-open-settings')));
    await tester.tapAndSettle(find.byKey(const ValueKey('music-open-settings')));
    expect(world.audio.settingsOpened, 1);
  });

  e2e('styles, room and timing are set on the screen and kept', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.home.createRoom('Den', [world.home.lights.single.id]);
    await openMusicSync(tester);

    await tapInList(tester, find.byKey(ValueKey('music-room-${world.home.rooms.single.id}')));
    await tapInList(tester, find.byKey(const ValueKey('music-style-glow')));
    expect(find.textContaining('Brightness follows the loudness'), findsOneWidget);
    await tapInList(tester, find.byKey(const ValueKey('music-palette-cool')));
    await tapInList(tester, find.byKey(const ValueKey('music-timing')));
    final timing = find.descendant(
      of: find.byKey(const ValueKey('music-timing-slider')),
      matching: find.byType(Slider),
    );
    await tester.pumpUntilFound(timing);
    final slider = tester.widget<Slider>(timing);
    slider.onChanged!(-120);
    slider.onChangeEnd!(-120);
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('120 ms earlier'), findsOneWidget);

    final saved = (await world.musicStore.load())!;
    expect(saved.roomId, world.home.rooms.single.id);
    expect(saved.style, MusicStyle.glow);
    expect(saved.palette, MusicPalette.cool);
    expect(saved.timing, const Duration(milliseconds: -120));
  });

  e2e('Settings opens music sync too, which waits for a light before it can start', (tester, world) async {
    await world.launch(tester);
    await tester.tapAndSettle(find.text('Settings'));
    await tapInList(tester, find.byKey(const ValueKey('settings-music-sync')));
    await tester.pumpUntilFound(find.text('Listen to'));
    expect(find.text('Add a light first.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('music-start'))).onPressed, isNull);
  });

  e2e('when the music stops the lights hold the beat, then breathe, and the screen says so', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await openMusicSync(tester);
    expect(find.byKey(const ValueKey('music-trace')), findsOneWidget);
    await tester.tapAndSettle(find.byKey(const ValueKey('music-start')));
    await tester.pumpUntilFound(find.text('120 BPM'), timeout: const Duration(seconds: 15));
    expect(find.byKey(const ValueKey('music-lock-bars')), findsOneWidget);

    world.audio.muted = true;
    await tester.pumpUntilFound(find.text('Holding the beat.'), timeout: const Duration(seconds: 15));
    await tester.pumpUntilFound(find.text('Breathing until the beat comes back.'), timeout: const Duration(seconds: 10));

    await tester.tapAndSettle(find.byKey(const ValueKey('music-stop')));
  });

  e2e('the follow mode and the beat finding sliders are saved', (tester, world) async {
    await world.launch(tester);
    await openMusicSync(tester);
    expect(world.music.settings.follow, FollowMode.auto);
    await tapInList(tester, find.byKey(const ValueKey('music-follow-hits')));
    expect(world.music.settings.follow, FollowMode.hits);
    expect(find.textContaining('as it is heard'), findsOneWidget);

    final sensitivity = find.byKey(const ValueKey('music-sensitivity'));
    await tester.scrollUntilVisible(sensitivity, 200, scrollable: find.byType(Scrollable).last);
    await tester.drag(sensitivity, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(world.music.settings.sensitivity, 1.0);
    final steadiness = find.byKey(const ValueKey('music-steadiness'));
    await tester.scrollUntilVisible(steadiness, 200, scrollable: find.byType(Scrollable).last);
    await tester.drag(steadiness, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(world.music.settings.steadiness, 0.0);

    final saved = (await world.musicStore.load())!;
    expect((saved.follow, saved.sensitivity, saved.steadiness), (FollowMode.hits, 1.0, 0.0));
  });

  e2e('lights: all of them or one room, with how many will move', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    world.bulb('b2', name: 'Bedside');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.addBulbThroughUi(tester, 'Bedside');
    await world.home.createRoom('Den', [world.home.lights.first.id]);
    await openMusicSync(tester);
    await tester.scrollUntilVisible(find.textContaining('will move'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('2 lights will move.'), findsOneWidget);
    await tapInList(tester, find.byKey(ValueKey('music-room-${world.home.rooms.single.id}')));
    expect(find.text('1 light will move.'), findsOneWidget);
    await tapInList(tester, find.byKey(const ValueKey('music-room-all')));
    expect(world.music.settings.roomId, isNull);
    expect(find.text('2 lights will move.'), findsOneWidget);
  });

  e2e('single lights can be picked, any mix of them, and All lights takes them back', (tester, world) async {
    world.bulb('b1', name: 'Desk lamp');
    world.bulb('b2', name: 'Bedside');
    await world.launch(tester);
    await world.addBulbThroughUi(tester, 'Desk lamp');
    await world.addBulbThroughUi(tester, 'Bedside');
    await openMusicSync(tester);
    final desk = world.home.lights.firstWhere((l) => l.name == 'Desk lamp').id;
    final bedside = world.home.lights.firstWhere((l) => l.name == 'Bedside').id;

    await tapInList(tester, find.byKey(ValueKey('music-light-$desk')));
    expect(world.music.settings.lightIds, [desk]);
    expect(find.text('1 light will move.'), findsOneWidget);
    await tapInList(tester, find.byKey(ValueKey('music-light-$bedside')));
    expect(world.music.settings.lightIds, unorderedEquals([desk, bedside]));
    await tapInList(tester, find.byKey(ValueKey('music-light-$desk')));
    expect(world.music.settings.lightIds, [bedside]);

    await tapInList(tester, find.byKey(const ValueKey('music-room-all')));
    expect(world.music.settings.lightIds, isEmpty);
    expect((await world.musicStore.load())!.lightIds, isEmpty);
  });

  e2e('strength and a later timing are saved', (tester, world) async {
    await world.launch(tester);
    await openMusicSync(tester);
    final strength = find.descendant(of: find.byKey(const ValueKey('music-strength')), matching: find.byType(Slider));
    await tester.scrollUntilVisible(strength, 200, scrollable: find.byType(Scrollable).last);
    final slider = tester.widget<Slider>(strength);
    slider.onChanged!(0.3);
    slider.onChangeEnd!(0.3);
    await tester.settle(const Duration(milliseconds: 300));
    expect(world.music.settings.strength, 0.3);

    await tapInList(tester, find.byKey(const ValueKey('music-timing')));
    final timing = find.descendant(of: find.byKey(const ValueKey('music-timing-slider')), matching: find.byType(Slider));
    await tester.pumpUntilFound(timing);
    tester.widget<Slider>(timing)
      ..onChanged!(150)
      ..onChangeEnd!(150);
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('150 ms later'), findsOneWidget);
  });

  e2e('switching music sync off while its screen is open leaves an empty screen', (tester, world) async {
    await world.launch(tester);
    await openMusicSync(tester);
    await world.plugins.setEnabled('music-sync', false);
    await tester.settle(const Duration(milliseconds: 300));
    expect(find.text('Listen to'), findsNothing);
    expect(find.text('Music sync'), findsOneWidget);
  });

  e2e('the info button on the trace explains its marks', (tester, world) async {
    await world.launch(tester);
    await openMusicSync(tester);
    await tester.tapAndSettle(find.byKey(const ValueKey('music-trace-help')));
    expect(find.text('Reading the trace'), findsOneWidget);
    expect(find.text('Hit: sent as soon as it was heard'), findsOneWidget);
  });

  e2e('each slider has a reset that is on only while it is off its default', (tester, world) async {
    await world.launch(tester);
    world.music.update(world.music.settings.copyWith(strength: 0.2, sensitivity: 0.9, steadiness: 0.1));
    await tester.settle(const Duration(milliseconds: 100));
    await openMusicSync(tester);
    for (final (key, check) in <(String, bool Function())>[
      ('music-strength-reset', () => world.music.settings.strength == const MusicSettings().strength),
      ('music-sensitivity-reset', () => world.music.settings.sensitivity == 0.5),
      ('music-steadiness-reset', () => world.music.settings.steadiness == 0.5),
    ]) {
      final reset = find.byKey(ValueKey(key));
      await tester.scrollUntilVisible(reset, 200, scrollable: find.byType(Scrollable).last);
      expect(tester.widget<IconButton>(reset).onPressed, isNotNull, reason: key);
      await tester.tapAndSettle(reset);
      expect(check(), isTrue, reason: key);
      expect(tester.widget<IconButton>(reset).onPressed, isNull, reason: '$key is off at the default');
    }
  });

  e2e('the tracking log switch is saved', (tester, world) async {
    await world.launch(tester);
    await openMusicSync(tester);
    await tapInList(tester, find.byKey(const ValueKey('music-tracking-log')));
    expect(world.music.settings.trackingLog, isTrue);
    expect((await world.musicStore.load())!.trackingLog, isTrue);
  });
}
