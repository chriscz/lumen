// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/audio_input.dart';

void main() {
  test('a source status is a value, and says what it is', () {
    const a = SourceStatus(SourceState.unsupported, reason: 'No');
    expect(a, const SourceStatus(SourceState.unsupported, reason: 'No'));
    expect(a.hashCode, const SourceStatus(SourceState.unsupported, reason: 'No').hashCode);
    expect(a.toString(), 'SourceStatus(unsupported, No)');
    expect(SourceStatus.ready.toString(), 'SourceStatus(ready)');
    expect(const AudioInputError('denied', 'Not allowed').toString(), 'AudioInputError(denied: Not allowed)');
  });

  test('without Android there is no audio, and nothing to ask for', () async {
    const input = NoAudioInput();
    expect((await input.status(AudioSource.microphone)).state, SourceState.unsupported);
    expect((await input.requestPermission(AudioSource.microphone)).state, SourceState.unsupported);
    await input.openSettings();
    await expectLater(input.listen(AudioSource.microphone), emitsError(isA<AudioInputError>()));
  });
}
