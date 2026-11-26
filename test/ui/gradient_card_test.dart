// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/capabilities.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/ui/widgets/gradient_card.dart';

void main() {
  testWidgets('a gradient with one colour is shown with a second stop filled in', (tester) async {
    final sent = <LightGradient>[];
    const red = XyColor(0.675, 0.322);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GradientCard(
              gradient: const LightGradient([red], mode: GradientMode.segmented),
              // The light does not offer the mode it reported, so the first it offers is shown.
              modes: const [GradientMode.interpolated, GradientMode.mirrored],
              onChanged: sent.add,
            ),
          ),
        ),
      ),
    );

    expect(find.text('2 colours'), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-stop-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-stop-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('gradient-stop-2')), findsNothing);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('gradient-mode-interpolated'))).selected, isTrue);
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('gradient-remove'))).onPressed,
      isNull,
      reason: 'two colours is the fewest',
    );

    await tester.tap(find.byKey(const ValueKey('gradient-add')));
    await tester.pump();
    final g = sent.single;
    expect(g.colors, [red, const XyColor(0.5614, 0.4156), const XyColor(0.2485, 0.0917)]);
    expect(g.mode, GradientMode.interpolated);
  });
}
