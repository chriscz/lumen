# Lumen Architecture

## High-Level Structure

```text
UI (screens, widgets)
  |  reads and calls
HomeController  (ChangeNotifier, single source of truth, persistence)
  |                         |
HueBleDriver               HueBridgeClient (per host)
  |                         |
BleCentral (interface)     http.Client
  |            |            |              |
universal_ble  Simulated    IOClient       MockClient over SimulatedBridge
               BleCentral   (real bridge)  (tests, demo)
```

`AppServices` bundles external dependencies (Bluetooth central, bridge client factory, local bridge discovery, persistence, audio input, and bridge foreground service). `main.dart` builds the real platform bindings; unit tests, end-to-end widget tests, and demo mode build `AppServices.simulated`.

## Directory Layout

- `lib/domain/`: Immutable data models (`Home`, `Light`, `Room`, `Profile`, `LightCapabilities`, `PowerOnBehavior`, errors).
- `lib/color/`: CIE xy, sRGB, colour temperature (mireds), and gamut clamping math.
- `lib/transport/ble/`: `BleCentral` seam, `HueBleCodec` (GATT TLV encoder/decoder), `HueBleDriver` (serialised queue, 7-connection LRU pool), and `UniversalBleCentral`.
- `lib/transport/bridge/`: `HueBridgeClient` (v1 REST API), `HueV1State` codec, and local-only `LanBridgeDiscovery`.
- `lib/emulator/`: Pure-Dart Hue Bridge v1 emulator (`BridgeApi`, `BridgeServer`, `BridgeExtensions`), mDNS/DNS-SD responder (`DnsMessage`, `MdnsResponder`, `NsdBridgeBrowser`), SSDP, and background lifecycle controller.
- `lib/plugins/`: `LumenPlugin` interface, `PluginManager`, and `MusicSyncPlugin` (experimental).
- `lib/music/`: Pure-Dart DSP pipeline (FFT spectrum, spectral flux onset detection, beat tracker, follow modes, colour/pulse effects, and fixed-buffer 5-second trace).
- `lib/state/`: `HomeController`, `AppServices`, JSON persistence stores (`HomeStore`, `EmulatorStore`, `PluginStore`, `MusicStore`).
- `lib/log/`: Ring-buffered logger with secret redaction (bridge keys) and optional file persistence.
- `lib/sim/`: Byte-level Bluetooth bulb simulator, simulated Hue Bridge, simulated audio generator, and demo home fixture.
- `lib/ui/`: Flutter Material 3 screens and widgets.
- `packages/lumen_bonded_devices/`: Android plugin reading OS-bonded Bluetooth devices and opening app permission settings.
- `packages/lumen_bridge_service/`: Android plugin providing the `connectedDevice` foreground service, optional charging wake/Wi-Fi lock, and `NsdManager` mDNS registration/browsing.
- `packages/lumen_audio_capture/`: Android plugin providing Microphone (`AudioRecord`), Phone sound (`Visualizer`), and Android 10+ Audio playback capture (`MediaProjection`) inside a foreground service.
- `test/` & `integration_test/`: Unit tests, protocol codec tests, and full-app end-to-end suites that run both headlessly under fake time (`flutter test`) and on a real device (`integration_test/`).

## Key Design Decisions

| Topic | Decision | Rationale |
| --- | --- | --- |
| BLE abstraction | `universal_ble` behind `BleCentral` | BSD-3-Clause licensed; keeps platform BLE isolated so tests run against a byte-accurate simulator. |
| Combined writes | Single TLV write to `932c32bd-0007` | Applies power, brightness, colour, and transition atomically with no flicker. |
| Connection pool | Max 7 simultaneous BLE links (LRU) | Respects Android's concurrent GATT connection limits while keeping larger setups reachable. |
| Command coalescing | At most one write in flight per light | Slider drags never build a backlog; the final value always lands cleanly. |
| Optimistic UI | Immediate local update with rollback on failure | Keeps controls responsive while accurately reporting unreachable lights. |
| Local-only privacy | No cloud discovery, no analytics, no telemetry | All discovery and control stays on Bluetooth and the local Wi-Fi network. |
| Bridge TLS | Accept bridge certificate for its own host only | Real Hue Bridges use a Signify root CA not present in Android's system trust store. |
| Capabilities first | Capabilities characteristic beats model heuristics | Automatically adapts controls, temperature bounds, effects, and gradients per bulb. |
| Plugins | Opt-in/opt-out `LumenPlugin` boundary | Experimental features like Music sync can be toggled off cleanly with zero leftover UI or bridge routes. |

## Testing and Coverage

- Run static analysis: `flutter analyze`
- Run unit and headless E2E tests: `flutter test`
- Enforce 100% line coverage across `lib/`: `bash tool/coverage.sh`
- Render README screenshots from the simulated home: `SHOTS=1 flutter test test/shots --update-goldens`
