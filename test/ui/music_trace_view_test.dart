// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/beat_tracker.dart';
import 'package:lumen/music/music_trace.dart';
import 'package:lumen/ui/widgets/music_trace_view.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('draws the trace in a strip across the card', (tester) async {
    final trace = MusicTrace()..addFrame(const MusicFrame(at: Duration(seconds: 1), level: 0.5, bass: 0, onset: true));
    await tester.pumpWidget(wrap(MusicTraceView(trace: trace, active: true)));
    final box = tester.getSize(find.byKey(const ValueKey('music-trace')));
    expect(box.height, 96);
    expect(
      find.descendant(of: find.byKey(const ValueKey('music-trace')), matching: find.byType(CustomPaint)),
      findsWidgets,
    );
  });

  testWidgets('the lock bars show confidence and coverage against their thresholds', (tester) async {
    const report = TrackerReport(
      bpm: 120,
      confidence: 0.4,
      coverage: 0.7,
      onsets: 8,
      sinceOnset: 0.2,
      level: 0.5,
      failures: ['confidence 0.40 < 0.55'],
      candidates: [],
    );
    await tester.pumpWidget(wrap(const LockBars(report: report)));
    expect(find.text('Confidence 0.40 (needs 0.55)'), findsOneWidget);
    expect(find.text('Coverage 0.70 (needs 0.60)'), findsOneWidget);
    await tester.pumpWidget(wrap(const LockBars(report: null)));
    expect(find.byKey(const ValueKey('music-lock-bars')), findsNothing);
  });

  testWidgets('the trace repaints on its own, behind a repaint boundary, as chunks arrive', (tester) async {
    final trace = MusicTrace();
    await tester.pumpWidget(wrap(MusicTraceView(trace: trace, active: true)));
    final strip = find.byKey(const ValueKey('music-trace'));
    expect(find.descendant(of: strip, matching: find.byType(RepaintBoundary)), findsOneWidget);
    trace
      ..addFrame(const MusicFrame(at: Duration(seconds: 1), level: 0.5, bass: 0, flux: 0.3, threshold: 0.2))
      ..publish();
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'a publish asks for a repaint');
  });

  testWidgets('paints every kind of mark: bars, threshold, loudness, onsets, breathing and each beat outcome', (tester) async {
    final trace = MusicTrace();
    for (var i = 0; i <= 50; i++) {
      trace.addFrame(
        MusicFrame(
          at: Duration(milliseconds: i * 100),
          level: (i % 5) / 5,
          bass: 0,
          onset: i % 5 == 0,
          flux: (i % 5).toDouble(),
          threshold: 2,
        ),
      );
    }
    for (final (i, outcome) in BeatOutcome.values.indexed) {
      trace.addBeat(Duration(milliseconds: 1000 + i * 500), outcome);
    }
    trace
      ..setBreathing(const Duration(seconds: 3), true)
      ..setBreathing(const Duration(seconds: 4), false);
    await tester.pumpWidget(wrap(MusicTraceView(trace: trace, active: true)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(wrap(MusicTraceView(trace: trace, active: false)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the guide names every mark the trace draws', (tester) async {
    await tester.pumpWidget(wrap(const SingleChildScrollView(child: TraceGuide())));
    for (final text in [
      'Beat: predicted and sent to the lights',
      'Held beat: kept after the beat was lost',
      'Hit: sent as soon as it was heard',
      'Dropped: the lights were busy, or it came too soon',
      'Onset: a sound that crossed the line',
      'Onset signal: how sharply the sound rose',
      'The line a sound must cross to count',
      'The line an onset must reach to be a hit',
      'Loudness',
      'Breathing: waiting for the beat to come back',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(body: SingleChildScrollView(child: TraceGuide())),
      ),
    );
    expect(tester.takeException(), isNull, reason: 'it draws in the dark theme too');
  });
}
