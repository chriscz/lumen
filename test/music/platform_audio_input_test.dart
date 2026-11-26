// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/audio_chunk.dart';
import 'package:lumen/music/audio_input.dart';
import 'package:lumen/music/platform_audio_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel(PlatformAudioInput.methods);
  const chunks = EventChannel(PlatformAudioInput.chunks);
  final calls = <MethodCall>[];

  TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Object? Function(MethodCall call) handler) => messenger().setMockMethodCallHandler(methods, (call) async {
    calls.add(call);
    return handler(call);
  });

  setUp(calls.clear);

  tearDown(() {
    messenger().setMockMethodCallHandler(methods, null);
    messenger().setMockStreamHandler(chunks, null);
  });

  const android = PlatformAudioInput(onAndroid: _yes);

  test("reads each source's status from the plugin", () async {
    answer(
      (call) => switch (call.arguments['source']) {
        'microphone' => {'state': 'ready'},
        'phoneSound' => {'state': 'needsPermission'},
        _ => {'state': 'unsupported', 'reason': 'Needs Android 10 or later'},
      },
    );
    expect(await android.status(AudioSource.microphone), SourceStatus.ready);
    expect(await android.status(AudioSource.phoneSound), SourceStatus.needsPermission);
    expect(
      await android.status(AudioSource.capture),
      const SourceStatus(SourceState.unsupported, reason: 'Needs Android 10 or later'),
    );
    expect(calls.first.method, 'status');
  });

  test('asks for the permission and opens app settings through the plugin', () async {
    answer((call) => call.method == 'requestPermission' ? {'state': 'denied'} : null);
    expect(await android.requestPermission(AudioSource.microphone), SourceStatus.denied);
    await android.openSettings();
    expect(calls.map((c) => c.method), ['requestPermission', 'openSettings']);
  });

  test('off Android, or without the plugin, every source is unsupported', () async {
    const elsewhere = PlatformAudioInput(onAndroid: _no);
    expect((await elsewhere.status(AudioSource.microphone)).state, SourceState.unsupported);
    expect(calls, isEmpty);
    expect((await android.status(AudioSource.microphone)).state, SourceState.unsupported);
  });

  test('turns the plugin events into samples and spectra', () async {
    Object? started;
    messenger().setMockStreamHandler(
      chunks,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          started = arguments;
          sink.success({
            'type': 'pcm',
            'rate': 48000,
            'data': Uint8List.fromList([0x00, 0x40, 0x00, 0xC0]),
          });
          sink.success({
            'type': 'fft',
            'rate': 44100,
            'atUs': 1500000,
            'data': Uint8List.fromList([3, 0, 4, 3]),
          });
          sink.endOfStream();
        },
      ),
    );
    final got = await android.listen(AudioSource.phoneSound).toList();
    expect(started, {'source': 'phoneSound'});
    final pcm = got[0] as PcmChunk;
    expect(pcm.sampleRate, 48000);
    expect(pcm.samples, [0.5, -0.5]);
    final fft = got[1] as FftChunk;
    expect(fft.at, const Duration(milliseconds: 1500));
    expect(fft.magnitudes, [3, 5, 0]);
  });

  test('plugin errors arrive as audio input errors', () async {
    messenger().setMockStreamHandler(
      chunks,
      MockStreamHandler.inline(
        onListen: (arguments, sink) => sink.error(code: 'cancelled', message: 'Recording was not allowed.'),
      ),
    );
    await expectLater(
      android.listen(AudioSource.capture),
      emitsError(
        isA<AudioInputError>()
            .having((e) => e.code, 'code', 'cancelled')
            .having((e) => e.message, 'message', 'Recording was not allowed.'),
      ),
    );
  });

  test('a plugin that fails a status call leaves the source unsupported, with its reason', () async {
    answer((call) => throw PlatformException(code: 'boom', message: 'The plugin broke.'));
    final status = await android.status(AudioSource.microphone);
    expect(status, const SourceStatus(SourceState.unsupported, reason: 'The plugin broke.'));
  });

  test('opening settings survives a missing or failing plugin', () async {
    await android.openSettings();
    answer((call) => throw PlatformException(code: 'boom'));
    await android.openSettings();
    expect(calls.single.method, 'openSettings');
  });

  test('a strange event from the plugin ends listening with an error', () async {
    messenger().setMockStreamHandler(
      chunks,
      MockStreamHandler.inline(onListen: (arguments, sink) => sink.success('not a chunk')),
    );
    await expectLater(
      android.listen(AudioSource.microphone),
      emitsError(isA<AudioInputError>().having((e) => e.code, 'code', 'failed')),
    );
  });

  test('by default it asks the platform whether it is Android', () async {
    // Built at run time, not as a constant, so its constructor runs.
    final input = [PlatformAudioInput.new][0]();
    expect((await input.status(AudioSource.microphone)).state, SourceState.unsupported);
  });
}

bool _yes() => true;
bool _no() => false;
