# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Direct Hue Bluetooth (GATT) control:** Scan, proximity-pair, connect on demand (7-connection LRU pool), read capabilities, control power, brightness, colour temperature, CIE xy colour, built-in effects, gradients (2 to 5 stops and blend modes), power-on behaviour, minimum brightness, rename on the bulb, identify (blink), and make discoverable.
- **Local-only Hue Bridge (v1 REST API) control:** Discover bridges strictly on the local network (known bridges, Android `NsdManager` / built-in mDNS, SSDP, and LAN scan), pair with the link button, import lights and rooms, automatically reconnect offline bridges, and keep removed bridge lights excluded with restore controls in Settings.
- **Rooms, linked clusters, profiles, and sleep fade:** Group and cluster controls with touch-to-detach/rejoin, starter and custom profiles/scenes with favourite chips on Home, and on-bulb/bridge sleep fades up to 60 minutes.
- **Act as a Hue Bridge:** Expose Lumen's lights on local Wi-Fi via Hue Bridge v1 HTTP, mDNS, and SSDP with an Android `connectedDevice` foreground service, connected-app last-seen tracking, and optional charging-only wake/Wi-Fi lock.
- **Plugin system and Music sync (Experimental):** Toggleable `LumenPlugin` architecture with versioned `/__plugins__` bridge routes and the experimental Music sync plugin (Microphone, Phone sound Visualizer, and Android 10+ Audio capture; Pulse, Colours, and Glow styles; Auto, Beat, and Hits follow modes; live 5-second onset trace).
- **Release pipeline and F-Droid / Obtainium support:** Isolated GitHub `release` environment APK signing with SLSA build provenance attestations, split-per-ABI + universal APKs, `SHA256SUMS.txt`, Fastlane Android metadata, and draft F-Droid reproducible-build recipe.

[Unreleased]: https://github.com/chriscz/lumen/compare/HEAD...HEAD
