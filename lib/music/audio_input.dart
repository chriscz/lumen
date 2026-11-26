// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'audio_chunk.dart';
import 'music_settings.dart';

export 'music_settings.dart' show AudioSource;

/// Whether an audio source can be used now.
enum SourceState {
  /// It can start.
  ready,

  /// It needs the microphone permission, which can be asked for.
  needsPermission,

  /// The permission was refused for good: only Android's app settings can
  /// give it now.
  denied,

  /// The phone does not have it.
  unsupported,
}

class SourceStatus {
  const SourceStatus(this.state, {this.reason});

  static const ready = SourceStatus(SourceState.ready);
  static const needsPermission = SourceStatus(SourceState.needsPermission);
  static const denied = SourceStatus(SourceState.denied);

  final SourceState state;

  /// Why it is unsupported, such as `Needs Android 10 or later`.
  final String? reason;

  @override
  bool operator ==(Object other) => other is SourceStatus && other.state == state && other.reason == reason;

  @override
  int get hashCode => Object.hash(state, reason);

  @override
  String toString() => 'SourceStatus(${state.name}${reason == null ? '' : ', $reason'})';
}

/// Why a source stopped: [code] is `cancelled` when the user said no to a
/// capture, `unavailable` when the phone could not open the source, and
/// `failed` otherwise. [message] is for the user.
class AudioInputError implements Exception {
  const AudioInputError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AudioInputError($code: $message)';
}

/// The sound the phone can hear: the microphone, the Visualizer on the
/// phone's own output, and audio capture.
abstract interface class AudioInput {
  Future<SourceStatus> status(AudioSource source);

  /// Asks for the microphone permission, which every source needs, and
  /// returns the new status of [source].
  Future<SourceStatus> requestPermission(AudioSource source);

  /// Opens Android's settings for the app, to give a refused permission.
  Future<void> openSettings();

  /// Starts [source] when listened to and stops it when cancelled. The
  /// stream fails with an [AudioInputError] when the source cannot start or
  /// breaks, and ends when the phone stops it.
  Stream<AudioChunk> listen(AudioSource source);
}

/// No audio at all: platforms other than Android.
class NoAudioInput implements AudioInput {
  const NoAudioInput();

  static const _unsupported = SourceStatus(SourceState.unsupported, reason: 'Needs an Android phone');

  @override
  Future<SourceStatus> status(AudioSource source) async => _unsupported;

  @override
  Future<SourceStatus> requestPermission(AudioSource source) async => _unsupported;

  @override
  Future<void> openSettings() async {}

  @override
  Stream<AudioChunk> listen(AudioSource source) =>
      Stream.error(const AudioInputError('unavailable', 'Music sync needs an Android phone.'));
}
