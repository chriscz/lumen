// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/spectrum.dart';

void main() {
  Float64List sine(int n, double cycles, {double amplitude = 1}) =>
      Float64List.fromList([for (var i = 0; i < n; i++) amplitude * sin(2 * pi * cycles * i / n)]);

  int peak(Float64List m) {
    var best = 0;
    for (var k = 1; k < m.length; k++) {
      if (m[k] > m[best]) best = k;
    }
    return best;
  }

  test('a sine has its peak in its own bin, with n / 2 + 1 bins', () {
    final m = Spectrum.magnitudes(sine(1024, 37));
    expect(m.length, 513);
    expect(peak(m), 37);
  });

  test('magnitudes scale with the amplitude', () {
    final loud = Spectrum.magnitudes(sine(512, 20));
    final quiet = Spectrum.magnitudes(sine(512, 20, amplitude: 0.25));
    expect(quiet[20] / loud[20], closeTo(0.25, 1e-9));
  });

  test('silence has no energy', () {
    final m = Spectrum.magnitudes(Float64List(256));
    expect(m.every((v) => v == 0), isTrue);
  });

  test('only powers of two are accepted', () {
    expect(() => Spectrum.magnitudes(Float64List(1000)), throwsArgumentError);
  });

  test("Android Visualizer bytes decode to the same bins as the samples' own spectrum", () {
    // Visualizer.getFft: [Re0, Re(n/2), Re1, Im1, Re2, Im2, ...] as signed bytes.
    const n = 64;
    final bytes = Uint8List(n);
    bytes[0] = 10;
    bytes[1] = 0;
    bytes[2 * 5] = 30;
    bytes[2 * 5 + 1] = (-40) & 0xFF;
    final m = Spectrum.fromVisualizer(bytes);
    expect(m.length, n ~/ 2 + 1);
    expect(m[0], closeTo(10, 1e-9));
    expect(m[5], closeTo(50, 1e-9));
    expect(m[n ~/ 2], 0);
    expect(peak(m), 5);
  });
}
