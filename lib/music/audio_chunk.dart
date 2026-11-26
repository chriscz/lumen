// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:typed_data';

/// A piece of sound from an audio source.
sealed class AudioChunk {
  const AudioChunk({required this.sampleRate});

  final int sampleRate;
}

/// The next mono samples, from -1 to 1, following on from the last chunk:
/// what the microphone and audio capture give.
final class PcmChunk extends AudioChunk {
  const PcmChunk(this.samples, {required super.sampleRate});

  final Float64List samples;

  /// 16 bit little endian samples, as Android's AudioRecord reads them.
  factory PcmChunk.fromInt16(Uint8List bytes, {required int sampleRate}) {
    final data = ByteData.sublistView(bytes);
    final samples = Float64List(bytes.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    return PcmChunk(samples, sampleRate: sampleRate);
  }
}

/// A snapshot of the spectrum taken at [at]: bins 0 to n / 2 of the last n
/// samples played, which is what Android's Visualizer gives. Snapshots do
/// not join up, so each carries its own time.
final class FftChunk extends AudioChunk {
  const FftChunk(this.magnitudes, {required super.sampleRate, required this.at});

  final Float64List magnitudes;
  final Duration at;
}
