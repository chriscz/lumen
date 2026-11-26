# Music Sync (Experimental Plugin)

Music sync is an **experimental** Lumen plugin (enabled by default and toggleable under **Settings > Plugins**). When switched off, it stops immediately, restores any lights it modified, and removes its UI controls and bridge API routes.

## How It Works

Music sync captures audio on the phone, analyses its spectrum and rhythmic onsets in real time in pure Dart (`lib/music/`), and sends light commands slightly ahead of predicted beats to compensate for Bluetooth or Wi-Fi latency.

### Audio Sources (Android)

Implemented in `packages/lumen_audio_capture`:

| Source | Signal | Permissions & Notes |
| --- | --- | --- |
| **Microphone** (default) | 16-bit mono PCM at 44.1 kHz (`UNPROCESSED` when supported, else `MIC`) | Requires `RECORD_AUDIO`. Works with any room speaker or app, including Spotify, but also hears ambient noise. |
| **Phone sound** | Android `Visualizer` FFT on audio session 0 (`SCALING_MODE_AS_PLAYED`) | Requires `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`. Works with Spotify on many phones without room noise, though some OEM ROMs or low-latency players bypass session 0. |
| **Audio capture** | Android 10+ `AudioPlaybackCaptureConfiguration` via `MediaProjection` | Requires `RECORD_AUDIO` and Android's per-session capture confirmation dialog. Apps can opt out via `allowAudioPlaybackCapture="false"` (Spotify currently blocks it). |

Background listening runs inside a foreground service (`MusicSyncService`) using `microphone` or `mediaProjection` service type as required by Android 11-14+.

### Signal Processing and Follow Modes

1. **Framing & FFT**: 1024-sample Hann-windowed frames with 50% overlap (86.1 Hz on PCM), converted to magnitude spectra via a radix-2 FFT.
2. **Onset detection**: Normalised log-compressed spectral flux combining full-band and sub-150 Hz bass flux, peak-picked against an adaptive threshold controlled by **Sensitivity**.
3. **Tempo & Beat lock**: Estimates inter-onset tempo and phase coherence, controlled by **Steadiness**.
4. **Follow modes**:
   - **Auto**: Follows the predicted beat grid when locked, and falls back to individual hits otherwise.
   - **Beat**: Fires only on a locked beat grid (holds tempo briefly when the beat drops, then gently breathes before resting on silence).
   - **Hits**: Reacts directly to strong onsets without waiting for a tempo lock.
5. **Styles & safety**:
   - **Pulse**: Flashes to full brightness on beats and fades back; shifts palette colour every 4 beats.
   - **Colours**: Advances each light through the palette on beats.
   - **Glow**: Smoothly maps loudness to brightness and bass energy to colour (at most 4 updates/sec).
   - **Flashing safety**: Beat flashes are rate-limited to at most 3 per second (333 ms minimum interval, WCAG threshold).
6. **Live trace & tracking log**: Displays a 5-second scrolling trace of onset flux, thresholds, lock state, and fired beats, with an optional `music` diagnostics log toggle.
7. **Restore**: Remembers each participating light's original state and smoothly restores it when stopped or when a light is deselected.

## Bridge Plugin API

When both **Act as a Hue Bridge** and the **Music sync** plugin are enabled, paired bridge clients can discover and control Music sync over `/__plugins__/music-sync/v1.0.0/` (using the `hue-application-key` header).

## Known Limitations (Why It Is Experimental)

- Real-world dense music through phone microphones or `Visualizer` can still lose beat lock more easily than clean percussion tracks; a continuous ODF-autocorrelation / comb-filter tracker is planned.
- Some phone manufacturers disable or zero-out `Visualizer` session 0, and apps using low-latency AAudio MMAP paths bypass both `Visualizer` and playback capture.
- Hue Entertainment API high-rate streaming is not yet implemented, so Bluetooth and v1 bridge command rates cap maximum responsiveness.
