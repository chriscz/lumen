// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_chunk.dart';
import 'audio_input.dart';
import 'spectrum.dart';

/// The sources of packages/lumen_audio_capture, through its channels. Off
/// Android, or in a build without the plugin, every source is unsupported.
class PlatformAudioInput implements AudioInput {
  /// [onAndroid] says whether the app runs on Android; tests replace it.
  const PlatformAudioInput({this.onAndroid = _isAndroid});

  final bool Function() onAndroid;

  /// status, requestPermission, openSettings.
  static const methods = 'lumen/audio';

  /// One stream per listen, started with the source's name.
  static const chunks = 'lumen/audio/chunks';

  static const _methods = MethodChannel(methods);
  static const _chunks = EventChannel(chunks);

  static bool _isAndroid() => !kIsWeb && Platform.isAndroid;

  static const _unsupported = SourceStatus(SourceState.unsupported, reason: 'Needs an Android phone');

  Future<SourceStatus> _call(String method, AudioSource source) async {
    if (!onAndroid()) return _unsupported;
    try {
      final answer = await _methods.invokeMapMethod<String, Object?>(method, {'source': source.name});
      return _status(answer);
    } on MissingPluginException {
      return _unsupported;
    } on PlatformException catch (e) {
      return SourceStatus(SourceState.unsupported, reason: e.message ?? e.code);
    }
  }

  static SourceStatus _status(Map<String, Object?>? answer) {
    final state = SourceState.values.where((s) => s.name == answer?['state']).firstOrNull;
    return SourceStatus(state ?? SourceState.unsupported, reason: answer?['reason'] as String?);
  }

  @override
  Future<SourceStatus> status(AudioSource source) => _call('status', source);

  @override
  Future<SourceStatus> requestPermission(AudioSource source) => _call('requestPermission', source);

  @override
  Future<void> openSettings() async {
    if (!onAndroid()) return;
    try {
      await _methods.invokeMethod<void>('openSettings');
    } on MissingPluginException {
      // Nothing to open in a build without the plugin.
    } on PlatformException catch (e) {
      debugPrint('Opening app settings failed: $e');
    }
  }

  @override
  Stream<AudioChunk> listen(AudioSource source) {
    if (!onAndroid()) return Stream.error(const AudioInputError('unavailable', 'Music sync needs an Android phone.'));
    return _chunks
        .receiveBroadcastStream({'source': source.name})
        .map(_chunk)
        .handleError(
          (Object e) => throw switch (e) {
            PlatformException(:final code, :final message) => AudioInputError(code, message ?? code),
            _ => AudioInputError('failed', '$e'),
          },
        );
  }

  static AudioChunk _chunk(Object? event) {
    final map = (event as Map).cast<String, Object?>();
    final rate = map['rate'] as int;
    final data = map['data'] as Uint8List;
    return switch (map['type']) {
      'fft' => FftChunk(
        Spectrum.fromVisualizer(data),
        sampleRate: rate,
        at: Duration(microseconds: map['atUs'] as int),
      ),
      _ => PcmChunk.fromInt16(data, sampleRate: rate),
    };
  }
}
