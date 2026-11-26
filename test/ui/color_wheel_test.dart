// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/widgets/color_wheel.dart';

void main() {
  final changes = <(double, double)>[];
  final ends = <(double, double)>[];

  setUp(() {
    changes.clear();
    ends.clear();
  });

  Future<void> pumpWheel(WidgetTester tester, {required double hue, bool enabled = true}) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 300,
            child: ColorWheel(
              key: const ValueKey('wheel'),
              hue: hue,
              saturation: 0.5,
              enabled: enabled,
              onChanged: (h, s) => changes.add((h, s)),
              onChangeEnd: (h, s) => ends.add((h, s)),
            ),
          ),
        ),
      ),
    ),
  );

  SemanticsNode wheelNode(WidgetTester tester) => tester.getSemantics(find.bySemanticsLabel('Colour wheel'));

  void perform(WidgetTester tester, SemanticsAction action) =>
      tester.semantics.performAction(find.semantics.byLabel('Colour wheel'), action);

  testWidgets('screen readers turn the hue up and down in 15 degree steps, wrapping at 0', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpWheel(tester, hue: 350);

    final node = wheelNode(tester);
    expect(node.label, 'Colour wheel');
    expect(node.value, 'hue 350 degrees, saturation 50 percent');
    expect(node.increasedValue, 'hue 5 degrees');
    expect(node.decreasedValue, 'hue 335 degrees');
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);

    perform(tester, SemanticsAction.increase);
    await tester.pump();
    expect(changes.single.$1, closeTo(5, 1e-9), reason: '350 + 15 wraps past 360');
    expect(changes.single.$2, 0.5, reason: 'saturation is kept');
    expect(ends.single, changes.single, reason: 'a nudge is a finished change');
    expect(wheelNode(tester).value, 'hue 5 degrees, saturation 50 percent');

    perform(tester, SemanticsAction.decrease);
    perform(tester, SemanticsAction.decrease);
    await tester.pump();
    expect(changes.map((c) => c.$1.round()), [5, 350, 335]);
    expect(ends, hasLength(3));
    semantics.dispose();
  });

  testWidgets('a disabled wheel offers no actions and ignores touches', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpWheel(tester, hue: 120, enabled: false);

    final data = wheelNode(tester).getSemanticsData();
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    expect(data.hasAction(SemanticsAction.decrease), isFalse);

    final rect = tester.getRect(find.byKey(const ValueKey('wheel')));
    await tester.dragFrom(rect.center, const Offset(80, 0));
    await tester.pump();
    expect(changes, isEmpty);
    expect(ends, isEmpty);
    semantics.dispose();
  });

  testWidgets('dragging follows the finger and reports the end once the finger lifts', (tester) async {
    await pumpWheel(tester, hue: 0);
    final rect = tester.getRect(find.byKey(const ValueKey('wheel')));
    final gesture = await tester.startGesture(rect.center + const Offset(0, 60));
    await gesture.moveTo(rect.center + const Offset(-120, 0));
    await tester.pump();
    expect(changes.last.$1, closeTo(180, 1), reason: 'left of the centre is hue 180');
    expect(changes.last.$2, closeTo(0.8, 0.01));
    expect(ends, isEmpty, reason: 'the finger is still down');

    // A rebuild from the light while dragging leaves the thumb under the finger.
    await pumpWheel(tester, hue: 90);
    await gesture.up();
    await tester.pump();
    expect(ends.single.$1, closeTo(180, 1));
  });
}
