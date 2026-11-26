// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../color/color_math.dart';
import '../domain/light.dart';
import 'home_scope.dart';
import 'light_detail_screen.dart';
import 'room_editor_screen.dart';
import 'widgets/detail_frame.dart';
import 'widgets/light_controls.dart';

/// Controls every light of a group at once: power, colour, white and
/// brightness. Bulbs that cannot show a colour get the closest they can.
class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({super.key, required this.roomId});

  final String roomId;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  bool? _white;
  (double, double) _wheel = (30, 0.8);

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final room = home.room(widget.roomId);
    if (room == null) return const Scaffold();
    final lights = home.lightsIn(room.id);
    final on = lights.any((l) => l.isOn);
    final anyColor = lights.any((l) => l.kind.hasColor);
    final anyWhite = lights.any((l) => l.kind.hasTemperature);
    final white = _white ?? !anyColor;
    final lit = lights.where((l) => l.isOn).toList();
    final brightness = lit.isEmpty
        ? 254
        : (lit.map((l) => l.state.brightness ?? 254).reduce((a, b) => a + b) / lit.length).round();
    final mireds = lit.map((l) => l.state.color).whereType<WhiteColor>().firstOrNull?.mireds ?? HueRange.defaultMireds;
    final glow = lit.isEmpty ? const Color(0xFF2A2A30) : ColorMath.displayColor(lit.first.state);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(room.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (room.linked)
            IconButton(
              key: const ValueKey('unlink-cluster'),
              tooltip: 'Unlink: control these lights one by one',
              icon: const Icon(Icons.link_off_rounded),
              onPressed: () async {
                final navigator = Navigator.of(context);
                await home.setLinked(room.id, false);
                navigator.pop();
              },
            ),
          IconButton(
            tooltip: 'Edit group',
            icon: const Icon(Icons.edit_rounded),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => RoomEditorScreen(room: room))),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: DetailFrame(
        key: const ValueKey('group-detail'),
        glow: glow,
        on: on,
        children: [
          PowerRow(
            on: on,
            status: '${lights.length} ${lights.length == 1 ? 'light' : 'lights'}${room.linked ? ', linked' : ''}',
            onChanged: (v) => home.setRoomPower(room.id, v),
          ),
          const SizedBox(height: 12),
          WheelCard(
            white: white,
            onWhite: (w) => setState(() => _white = w),
            showToggle: anyColor && anyWhite,
            showWheel: anyColor && !white,
            hue: _wheel.$1,
            saturation: _wheel.$2,
            onColor: (h, s, color) {
              setState(() => _wheel = (h, s));
              home.setRoomColor(room.id, color);
            },
          ),
          if (anyWhite && (white || !anyColor))
            TemperatureSlider(mireds: mireds, onChanged: (m) => home.setRoomColor(room.id, WhiteColor(m))),
          const SizedBox(height: 16),
          BrightnessSlider(brightness: brightness, onChanged: (b) => home.setRoomBrightness(room.id, b)),
          const SizedBox(height: 16),
          if (anyWhite)
            Swatches(
              colors: anyColor ? Swatches.all : Swatches.whites,
              onPick: (c) {
                setState(() {
                  _white = c is WhiteColor;
                  if (c is XyColor) _wheel = ColorMath.xyToHueSat(c);
                });
                home.setRoomColor(room.id, c);
              },
            ),
          const SizedBox(height: 16),
          ControlCard(
            icon: Icons.lightbulb_outline_rounded,
            title: 'Lights in this group',
            child: Column(
              children: [
                for (final l in lights)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 14, backgroundColor: ColorMath.displayColor(l.state)),
                    title: Text(l.name),
                    subtitle: Text(
                      [
                        l.reachable ? (l.isOn ? 'On' : 'Off') : 'Unreachable',
                        if (home.isDetached(l.id)) 'detached',
                      ].join(', '),
                    ),
                    trailing: home.isDetached(l.id)
                        ? TextButton(onPressed: () => home.rejoin(room.id, l.id), child: const Text('Rejoin'))
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => LightDetailScreen(lightId: l.id))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
