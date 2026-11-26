// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/material.dart';

import '../color/color_math.dart';
import '../domain/light.dart';
import 'home_scope.dart';
import 'widgets/color_wheel.dart';
import 'widgets/light_controls.dart';
import 'widgets/light_picker.dart';

/// Captures chosen lights as they are now.
class SceneEditorScreen extends StatefulWidget {
  const SceneEditorScreen({super.key});

  @override
  State<SceneEditorScreen> createState() => _SceneEditorScreenState();
}

class _SceneEditorScreenState extends State<SceneEditorScreen> {
  final _name = TextEditingController();
  Set<String> _selected = {};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final valid = _name.text.trim().isNotEmpty && _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('New scene')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: TextField(
              key: const ValueKey('profile-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Scene name', hintText: 'Movie night'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text('Lights to capture, as they look right now'),
          ),
          LightPicker(lights: home.lights, selected: _selected, onChanged: (s) => setState(() => _selected = s)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: valid
                ? () async {
                    await home.saveScene(_name.text, _selected);
                    if (context.mounted) Navigator.of(context).pop();
                  }
                : null,
            child: const Text('Save'),
          ),
        ),
      ),
    );
  }
}

/// Builds one look on the colour wheel or the white slider.
class PresetEditorScreen extends StatefulWidget {
  const PresetEditorScreen({super.key});

  @override
  State<PresetEditorScreen> createState() => _PresetEditorScreenState();
}

class _PresetEditorScreenState extends State<PresetEditorScreen> {
  final _name = TextEditingController();
  bool _white = false;
  double _hue = 30;
  double _saturation = 0.8;
  int _mireds = HueRange.defaultMireds;
  int _brightness = 200;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  LightState get _state => LightState(
    on: true,
    brightness: _brightness,
    color: _white ? WhiteColor(_mireds) : ColorMath.clampToGamut(ColorMath.hueSatToXy(_hue, _saturation), Gamut.c),
  );

  @override
  Widget build(BuildContext context) {
    final valid = _name.text.trim().isNotEmpty;
    final preview = ColorMath.displayColor(_state);
    return Scaffold(
      appBar: AppBar(title: const Text('New preset')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
        children: [
          TextField(
            key: const ValueKey('profile-name'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Preset name', hintText: 'Sunset'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: preview,
                  boxShadow: [BoxShadow(color: preview.withValues(alpha: 0.6), blurRadius: 18)],
                ),
              ),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.palette_rounded), label: Text('Colour')),
                  ButtonSegment(value: true, icon: Icon(Icons.wb_sunny_rounded), label: Text('White')),
                ],
                selected: {_white},
                onSelectionChanged: (s) => setState(() => _white = s.first),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (!_white)
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300, maxHeight: 300),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ColorWheel(
                    key: const ValueKey('color-wheel'),
                    hue: _hue,
                    saturation: _saturation,
                    onChanged: (h, s) => setState(() {
                      _hue = h;
                      _saturation = s;
                    }),
                  ),
                ),
              ),
            )
          else
            TemperatureSlider(mireds: _mireds, onChanged: (m) => setState(() => _mireds = m)),
          const SizedBox(height: 16),
          BrightnessSlider(brightness: _brightness, onChanged: (b) => setState(() => _brightness = b)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: valid
                ? () async {
                    await HomeScope.read(context).savePreset(_name.text, _state);
                    if (context.mounted) Navigator.of(context).pop();
                  }
                : null,
            child: const Text('Save'),
          ),
        ),
      ),
    );
  }
}
