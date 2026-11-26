// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:math';
import 'dart:typed_data';

/// Magnitude spectra, from samples or from Android's Visualizer.
abstract final class Spectrum {
  static final Map<int, Float64List> _windows = {};

  /// The magnitudes of bins 0 to n / 2 of [samples] (n of them, a power of
  /// two), through a Hann window and scaled so that a full scale sine
  /// peaks near 0.25 whatever n is.
  static Float64List magnitudes(List<double> samples) {
    final n = samples.length;
    if (n < 2 || n & (n - 1) != 0) throw ArgumentError.value(n, 'samples.length', 'not a power of two');
    final window = _windows.putIfAbsent(
      n,
      () => Float64List.fromList([for (var i = 0; i < n; i++) 0.5 - 0.5 * cos(2 * pi * i / n)]),
    );
    final re = Float64List(n);
    final im = Float64List(n);
    for (var i = 0; i < n; i++) {
      re[_reverse(i, n)] = samples[i] * window[i];
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = -2 * pi / size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = cos(step * k);
          final wi = sin(step * k);
          final a = start + k;
          final b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    final out = Float64List(n ~/ 2 + 1);
    for (var k = 0; k < out.length; k++) {
      out[k] = sqrt(re[k] * re[k] + im[k] * im[k]) / n;
    }
    return out;
  }

  static int _reverse(int i, int n) {
    var r = 0;
    for (var bit = n >> 1; bit > 0; bit >>= 1, i >>= 1) {
      r = (r << 1) | (i & 1);
    }
    return r;
  }

  /// The magnitudes in the bytes of Android's `Visualizer.getFft`: the real
  /// parts of bins 0 and n / 2, then the real and imaginary part of each bin
  /// from 1 to n / 2 - 1, as signed bytes.
  static Float64List fromVisualizer(Uint8List fft) {
    final n = fft.length;
    final out = Float64List(n ~/ 2 + 1);
    int signed(int b) => b > 127 ? b - 256 : b;
    out[0] = signed(fft[0]).abs().toDouble();
    out[n ~/ 2] = signed(fft[1]).abs().toDouble();
    for (var k = 1; k < n ~/ 2; k++) {
      final r = signed(fft[2 * k]).toDouble();
      final i = signed(fft[2 * k + 1]).toDouble();
      out[k] = sqrt(r * r + i * i);
    }
    return out;
  }
}
