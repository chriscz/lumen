# Lumen Protocol Reference

This document specifies the local wire protocols that Lumen speaks:

1. **Hue Bluetooth Low Energy (GATT)** for direct bulb control with no bridge.
2. **Hue Bridge Local REST API (v1)** for discovering, pairing with, and controlling lights through a Hue Bridge over the LAN.
3. **Bridge Emulation (HTTP, UPnP/SSDP, mDNS/DNS-SD)** for exposing Lumen's lights to other apps on the local Wi-Fi network.

Lumen never contacts external cloud services for discovery or control. Every wire format detail below is exercised by unit tests under `test/`.

---

## 1. Hue Bluetooth GATT Protocol

### Services

| Service | UUID | Notes |
| --- | --- | --- |
| Device configuration | `0000fe0f-0000-1000-8000-00805f9b34fb` (16-bit `FE0F`) | Scan filter and device configuration (`97fe6561-...`). |
| Light control | `932c32bd-0000-47a2-835a-a8d455b859dd` | Per-light state, capabilities, startup, and identify. |
| Device information | `0000180a-0000-1000-8000-00805f9b34fb` | Standard Bluetooth SIG service: model (`2A24`), firmware (`2A28`), manufacturer (`2A29`). |

All `97fe6561-...` characteristics share the suffix `-4f62-86e9-b71ee2da3d22`.
All `932c32bd-...` characteristics share the suffix `-47a2-835a-a8d455b859dd`.

### Device Configuration Characteristics (`FE0F`)

| UUID prefix | Purpose | Format |
| --- | --- | --- |
| `97fe6561-0001` | Zigbee MAC address (EUI-64) | Read; 8 bytes |
| `97fe6561-0003` | Device name | Read/write; UTF-8 capped at 32 bytes |
| `97fe6561-0004` | Factory reset | Write with response; `0x00` |
| `97fe6561-2001` | Proximity pairing trigger and state | Write without response `0x01`, then read 1 flag byte |
| `97fe6561-2004` | Open for bonding ("Make discoverable") | Write with response; `0x01` |
| `97fe6561-2005` | Application-layer security key slot | Read TLV set; non-zero entry indicates application-layer security is provisioned |

### Light Control Characteristics (`932c32bd`)

| UUID prefix | Purpose | Access |
| --- | --- | --- |
| `932c32bd-0001` | Capabilities (TLV) | Read |
| `932c32bd-0002` | Power (legacy single-value fallback) | Read, write, notify (`0x00` off, `0x01` on) |
| `932c32bd-0003` | Brightness (legacy single-value fallback) | Read, write (`1..254`) |
| `932c32bd-0004` | Colour temperature (legacy single-value fallback) | Read, write (uint16 LE mireds; `0xFFFF` in colour mode) |
| `932c32bd-0005` | Colour xy (legacy single-value fallback) | Read, write (two uint16 LE; `0xFFFFFFFF` in white mode) |
| `932c32bd-0006` | Identify (blink) | Write with response (`0x01`) |
| `932c32bd-0007` | Combined control and state (TLV) | Read, write with response, notify |
| `932c32bd-1005` | Power-on (startup) behaviour (TLV) | Read, write |
| `932c32bd-1006` | Minimum dim level | Write (1 byte, brightness scale) |

### Advertisement, Pairing, and Security

- **Scan filter**: Bulbs advertise service UUID `0xFE0F` with service data carrying a flags byte at offset 1 (used as a hint for "Ready to pair").
- **Proximity pairing**: Connect, write `0x01` without response to `97fe6561-2001`, then read back its flag byte:
  - Bit 0 (`0x01`): open for bonding
  - Bit 1 (`0x02`): already bonded to this device
  - Bit 2 (`0x04`): uncommissioned (new or factory reset)
  - Bit 3 (`0x08`): power-on pairing window expired (power-cycle the bulb and retry)
  - Bit 4 (`0x10`): attached to a Hue Bridge
- **Bonding**: Accessing an encrypted control characteristic after a short settle delay and MTU request (247 bytes) triggers Android's BLE bond; `createBond` is used as a fallback. Bonds belong to the phone, so Lumen also reads Android's bonded device list through `packages/lumen_bonded_devices`.
- **Make discoverable**: Writing `0x01` to `97fe6561-2004` opens a pairing window for another phone or smart speaker; Lumen repeats this periodically while the sheet is open.
- **Application-layer security**: Newer Hue bulbs may require an additional application-layer secure session beyond the OS Bluetooth bond (`97fe6561-2005`). Lumen does not implement proprietary application-layer encryption; if a bulb reports a provisioned key or refuses protected access while bonded, Lumen informs the user that the light requires the official app or a Hue Bridge.

### Combined Control TLV (`932c32bd-0007`)

Each TLV record consists of a 1-byte type, 1-byte length, and `length` payload bytes. Multiple records are concatenated in a single write and returned in the same format on reads and notifications.

| Type | Length | Field | Encoding |
| --- | --- | --- | --- |
| `0x01` | 1 | Power | `0x00` off, `0x01` on |
| `0x02` | 1 | Brightness | `round(level * 253) + 1` (`1..254`); `0xFF` means unset |
| `0x03` | 2 | Colour temperature | uint16 LE mireds, clamped `1..65279`; `0x0000` or `0xFFFF` means unset |
| `0x04` | 4 | Colour xy | two uint16 LE (`round(coord * 65536)` clamped `1..65279`) |
| `0x05` | 2 | Transition time | uint16 LE in units of 100 ms |
| `0x06` | 1 | Dynamic effect id | 0 none, 1 candle, 2 fireplace, 3 prism, 9 sunrise, 10 sparkle, 11 opal, 12 glisten, 13 sunset, 14 underwater, 15 cosmos, 16 sunbeam, 17 enchant |
| `0x07` | variable | Gradient palette | 4-byte header (colour count in high nibble of byte 0; mode index doubled in byte 1: 0 interpolated, 2 random, 4 mirrored, 6 segmented; bytes 2-3 zero) followed by 3-byte packed 12-bit xy points scaled against `(0.7347, 0.8431)` |
| `0x08` | 1 | Effect speed | `0..255` |
| `0x09` | 2 | Gradient window | two bytes (`round(fraction * 8)`) |
| `0x0A` | marker | Stream mode | Present when streaming; tolerated on decode |
| `0x0B` | 1 | Rotation / angle | `round(angle_radians * 256 / 2pi) & 0xFF` |

### Capabilities TLV (`932c32bd-0001`)

| Type | Meaning |
| --- | --- |
| `0x00` | Light type: `1` dimmable, `2` white ambiance, `3` full colour (absent = on/off only) |
| `0x01` / `0x02` | Min and max colour temperature (uint16 LE mireds) |
| `0x03` | Feature flags (bit 1 dynamic scenes, bit 2 dynamic effects, bit 3 gradient, bit 4 rotation) |
| `0x04` | Supported dynamic effects bitmask (low byte first, indexed by effect id) |
| `0x05` | Gradient orientation/order configuration flags |
| `0x08` | Supported gradient modes bitmask (bit 0 interpolated, bit 1 random, bit 2 mirrored, bit 3 segmented) |

### Startup / Power-On TLV (`932c32bd-1005`)

Reuses control record types `0x01` (power), `0x02` (brightness), `0x03` (colour temperature), and `0x04` (colour xy). Explicit values select a fixed power-on look; all-`0xFF` bytes (`0xFFFF` for mireds) represent "restore previous state".

---

## 2. Hue Bridge Local REST API (v1)

### Local-Only Discovery

`LanBridgeDiscovery` runs stages sequentially, cheapest first, and never contacts external cloud endpoints. Each stage can be toggled individually under **Settings > Bridge discovery > Advanced**:

1. **Known bridges**: Re-checks previously paired hosts.
2. **mDNS (`_hue._tcp.local`)**: Uses Android's `NsdManager` by default on Android, or a built-in legacy unicast PTR query (RFC 6762 section 6.7) to `224.0.0.251:5353`.
3. **SSDP**: Sends `M-SEARCH` for `ssdp:all` (`MX: 1`) to `239.255.255.250:1900` and `255.255.255.255:1900`, matching `hue-bridgeid` or `IpBridge` in `SERVER`.
4. **LAN scan**: Probes each private Wi-Fi/Ethernet `/24` on port 80 first, then Lumen's emulated bridge ports (`1818`, `1919`, ..., `2727`) on hosts that respond or actively refuse port 80.

Every candidate is verified via `GET /api/config` (HTTPS on 443 for hardware bridges, accepting the bridge's self-signed certificate only for that bridge's host; HTTP on non-443 ports for emulated bridges).

### Pairing and Control

- **Pair**: `POST /api` with `{"devicetype": "lumen#android"}`. Polls once per second for up to 30 seconds until the link button is pressed and returns `username` (the local app key).
- **Read state**: `GET /api/<key>/lights` and `GET /api/<key>/groups`.
- **Control**: `PUT /api/<key>/lights/<id>/state` and `PUT /api/<key>/groups/<id>/action` with `on`, `bri` (`1..254`), `ct` (mireds), `xy`, and `transitiontime` (100 ms units).

---

## 3. Acting as a Hue Bridge (Emulation)

Lumen can expose all lights it controls (Bluetooth and bridge lights alike) on the local Wi-Fi network through a Hue Bridge v1 compatible HTTP server:

- **Ports**: Tries port 80 first (desktop), then the first free port in `1818, 1919, ..., 2727` (`BridgePorts.lan`). Standard Android apps cannot bind ports below 1024; clients that accept `host:port` (such as another Lumen instance, Home Assistant with a manual host, or openHAB) can connect directly.
- **HTTP endpoints**: `/api`, `/api/config`, `/api/<key>/lights`, `/api/<key>/groups`, `/api/<key>/scenes`, `/api/<key>/config`, and `/description.xml` (UPnP device description).
- **Versioned plugin extensions**: Enabled plugins can register APIs under `/__plugins__/<plugin>/v<x.y.z>/`, discoverable from `GET /__plugins__` and authenticated with the `hue-application-key` header of a paired client.
- **Discovery announcements**:
  - **mDNS**: Registers `_hue._tcp` via Android `NsdManager` by default (falling back to Lumen's pure-Dart RFC 6762/6763 responder on port 5353), advertising `bridgeid` and `modelid=BSB002` TXT records plus the actual listening port in SRV.
  - **SSDP**: Responds to `M-SEARCH` on `239.255.255.250:1900` and sends periodic `ssdp:alive` / `ssdp:byebye` notices while holding a `WifiManager.MulticastLock`.
- **Background service**: On Android, `packages/lumen_bridge_service` runs a `connectedDevice` foreground service with an ongoing notification showing the listening address and active client count, plus an optional wake/Wi-Fi lock while charging.

---

## References

- Philips Hue Developer Documentation (Bridge v1 API and local discovery): https://developers.meethue.com/
- Community Hue BLE libraries: `flip-dots/HueBLE` (MIT), `npaun/philble` (BSD-3-Clause), `dw2lam/OpenHue` (MIT)
- RFC 6762 (Multicast DNS), RFC 6763 (DNS-SD), RFC 1035 (Domain Names)
- UPnP Device Architecture 1.1 (SSDP)
