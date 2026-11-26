// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/state/plugin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('keeps plugin choices in shared preferences, and shrugs off nothing or garbage', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsPluginStore();
    expect(await store.load(), isEmpty);
    await store.save({'music-sync': false});
    expect(await store.load(), {'music-sync': false});
    SharedPreferences.setMockInitialValues({'plugins.v1': '[1, 2'});
    expect(await SharedPrefsPluginStore().load(), isEmpty);
  });
}
