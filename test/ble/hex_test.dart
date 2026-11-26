// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/util/hex.dart';

void main() {
  test('hex is lower case, two digits a byte, space separated by default', () {
    expect(hex([0x01, 0xab, 0x00]), '01 ab 00');
  });

  test('hex takes a separator and upper case', () {
    expect(hex([0xaa, 0x0b], separator: ':'), 'aa:0b');
    expect(hex([0xaa, 0x0b], separator: '', upper: true), 'AA0B');
  });

  test('hex of no bytes is empty', () {
    expect(hex([]), '');
  });
}
