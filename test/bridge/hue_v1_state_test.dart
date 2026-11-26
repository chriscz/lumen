// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/domain/light.dart';
import 'package:lumen/transport/bridge/hue_v1_state.dart';

void main() {
  group('encoding', () {
    test('a command keeps only the fields it sets, clamped and rounded, in v1 key order', () {
      final body = HueV1State.fromCommand(
        const LightCommand(
          on: true,
          brightness: 300,
          color: XyColor(0.123456, 0.654321),
          transition: Duration(milliseconds: 449),
        ),
      );
      expect(jsonEncode(body), '{"on":true,"bri":254,"xy":[0.1235,0.6543],"transitiontime":4}');
      expect(HueV1State.fromCommand(const LightCommand()), isEmpty);
      expect(HueV1State.fromCommand(const LightCommand(color: WhiteColor(600))), {'ct': 500});
    });

    test('ct is left as given when the caller does not clamp it', () {
      expect(HueV1State.encode(color: const WhiteColor(600), clampCt: false), {'ct': 600});
    });

    test('colour keys can be exact and carry the colour mode', () {
      expect(HueV1State.colorJson(const XyColor(0.123456, 0.5), round: false, colormode: true), {
        'xy': [0.123456, 0.5],
        'colormode': 'xy',
      });
      expect(HueV1State.colorJson(const WhiteColor(100), clampCt: false, colormode: true), {
        'ct': 100,
        'colormode': 'ct',
      });
      expect(HueV1State.colorJson(null), isEmpty);
    });

    test('rounds to four decimals and converts deciseconds both ways', () {
      expect(HueV1State.round4(0.123449), 0.1234);
      expect(HueV1State.xyJson(const XyColor(0.33335, 0.1)), [0.3334, 0.1]);
      expect(HueV1State.toDeciseconds(const Duration(milliseconds: 250)), 3);
      expect(HueV1State.fromDeciseconds(4.4), const Duration(milliseconds: 400));
    });
  });

  group('decoding', () {
    test('reads on, bri and the colour its colour mode names', () {
      expect(
        HueV1State.stateOf({
          'on': true,
          'bri': 12.0,
          'colormode': 'ct',
          'ct': 300,
          'xy': [0.1, 0.2],
        }),
        const LightState(on: true, brightness: 12, color: WhiteColor(300)),
      );
      expect(
        HueV1State.colorOf({
          'colormode': 'xy',
          'ct': 300,
          'xy': [0.1, 0.2],
        }),
        const XyColor(0.1, 0.2),
      );
      expect(HueV1State.colorOf({'ct': 300}), const WhiteColor(300));
      expect(
        HueV1State.colorOf({
          'colormode': 'ct',
          'xy': [0.1, 0.2],
        }),
        isNull,
      );
      expect(HueV1State.stateOf(const {}), const LightState());
    });

    test('can ignore the colour mode and refuse xy or ct', () {
      final body = {
        'colormode': 'ct',
        'ct': 300,
        'xy': [0.1, 0.2],
      };
      expect(HueV1State.colorOf(body, honourColormode: false), const XyColor(0.1, 0.2));
      expect(HueV1State.colorOf(body, honourColormode: false, acceptXy: false), const WhiteColor(300));
      expect(HueV1State.colorOf(body, honourColormode: false, acceptXy: false, acceptCt: false), isNull);
    });

    test('an xy value is a pair of numbers', () {
      expect(HueV1State.xyOf([0, 1]), const XyColor(0, 1));
      expect(HueV1State.xyOf([0.1]), isNull);
      expect(HueV1State.xyOf('0.1,0.2'), isNull);
    });
  });
}
