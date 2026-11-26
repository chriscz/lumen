// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// Errors the UI explains to the user. [message] is written for people.
sealed class LightError implements Exception {
  const LightError(this.message);

  final String message;

  /// Raw detail for diagnostics, shown when debug logging is on.
  String? get details => null;

  @override
  String toString() => '$runtimeType: $message';
}

class NotInPairingMode extends LightError {
  const NotInPairingMode({bool onBridge = false})
    : super(
        'The bulb refused to pair because it is not discoverable. '
        '${onBridge ? 'It is connected to a Hue Bridge, so make it discoverable from the Hue app first. ' : ''}'
        '1. Close the Hue app, since a bulb connected to it accepts no other phone. '
        '2. In the Hue app open Settings, Voice assistants, Amazon Alexa (or Google Home) '
        'and tap Make discoverable, then add the bulb here within a minute or two. '
        '3. Last resort: factory reset it by switching it off and on five times, about a second apart, '
        'ending on. It blinks, and must then be added in the Hue app again too.',
      );
}

/// The bulb answered the proximity handshake: the time window after it was
/// switched on has passed.
class BondWindowExpired extends LightError {
  const BondWindowExpired()
    : super(
        'The bulb only pairs shortly after it is switched on. '
        'Switch the bulb off and on, then add it within a minute.',
      );
}

/// The whole pairing attempt took longer than it may.
class PairingTimedOut extends LightError {
  const PairingTimedOut()
    : super('Pairing timed out. Keep the phone close to the bulb, close the Hue app, and try again.');
}

/// The bulb did not accept "Make discoverable" from this app.
class DiscoverableRefused extends LightError {
  DiscoverableRefused(this.detail)
    : super(
        'The light refused to become discoverable. Some lights only accept this from the Hue app: '
        'there, open Settings, Voice assistants, Amazon Alexa (or Google Home) and tap Make discoverable.',
      );

  final String detail;

  @override
  String? get details => detail.isEmpty ? null : detail;
}

/// The bulb advertises but does not accept a connection: another phone or
/// the Hue app holds it.
class BulbBusy extends LightError {
  const BulbBusy()
    : super(
        'The bulb did not accept the connection. It is probably connected to the Hue app or another phone. '
        'Close the Hue app (swipe it away from recent apps), then try again.',
      );
}

/// A Bluetooth failure the app has no specific advice for.
class BluetoothError extends LightError {
  BluetoothError(this.code, this.detail)
    : super(
        'Bluetooth error ($code). Try again. If it keeps failing, turn on Debug logging in Settings, '
        'try once more and share the log from Diagnostics.',
      );

  final String code;
  final String detail;

  @override
  String? get details => detail.isEmpty ? null : detail;
}

/// The light is bonded but refuses protected reads and writes: it uses the
/// application-layer security of newer Hue lights, which Lumen does not
/// implement (see docs/protocol.md).
class NeedsAppSecurity extends LightError {
  const NeedsAppSecurity() : super("This light uses Hue's extra security and needs the official app or a Hue Bridge.");
}

/// The light does not offer a characteristic the action needs, even after
/// reconnecting to read its services again.
class CharacteristicMissing extends LightError {
  CharacteristicMissing([this.detail = ''])
    : super(
        'The light does not offer this over Bluetooth. If it should, switch Bluetooth off and on, '
        'then try again.',
      );

  final String detail;

  @override
  String? get details => detail.isEmpty ? null : detail;
}

class LightUnreachable extends LightError {
  const LightUnreachable([super.message = 'The light is out of reach. Move closer or check its power.']);
}

class BluetoothUnavailable extends LightError {
  const BluetoothUnavailable([super.message = 'Bluetooth is off or not available. Turn it on, then try again.']);
}

class BluetoothPermissionDenied extends LightError {
  const BluetoothPermissionDenied({this.permanent = false})
    : super(
        permanent
            ? 'Lumen needs the Nearby devices permission for Bluetooth bulbs. '
                  'Android no longer asks, so allow it in the app settings, under Permissions.'
            : 'Lumen needs the Nearby devices permission to find and control Bluetooth bulbs.',
      );

  /// Android no longer shows the prompt; only the app settings can grant it.
  final bool permanent;
}

class LinkButtonNotPressed extends LightError {
  const LinkButtonNotPressed() : super('Press the round link button on the bridge, then try again.');
}

class BridgeUnauthorized extends LightError {
  const BridgeUnauthorized() : super('The bridge no longer accepts this app. Pair it again.');
}

class BridgeUnreachable extends LightError {
  const BridgeUnreachable([super.message = 'The bridge did not answer. Check that it is on the same network.']);
}

/// The bridge could not be reached at all: no connection, or no answer in
/// time. An answer with an error is a [BridgeUnreachable] but not this.
class BridgeOffline extends BridgeUnreachable {
  const BridgeOffline();
}
