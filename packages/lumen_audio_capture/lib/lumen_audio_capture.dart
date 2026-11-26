// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// The channels this plugin answers. The app's Dart side, with its tests and
/// fakes, is in the app: lib/music/platform_audio_input.dart.
abstract final class LumenAudioCaptureChannels {
  /// status, requestPermission, openSettings.
  static const methods = 'lumen/audio';

  /// A stream of sound per listen, started with the source's name.
  static const chunks = 'lumen/audio/chunks';
}
