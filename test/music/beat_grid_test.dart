// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/music/beat_grid.dart';

void main() {
  const grid = BeatGrid(period: Duration(milliseconds: 500), anchor: Duration(seconds: 10));

  test('the next beat is the first at or after a time, before or after the anchor', () {
    expect(grid.next(const Duration(seconds: 10)), const Duration(seconds: 10));
    expect(grid.next(const Duration(milliseconds: 10001)), const Duration(milliseconds: 10500));
    expect(grid.next(const Duration(milliseconds: 11400)), const Duration(milliseconds: 11500));
    expect(grid.next(const Duration(milliseconds: 9200)), const Duration(milliseconds: 9500));
  });

  test('grids with the same period and anchor are equal', () {
    expect(grid, const BeatGrid(period: Duration(milliseconds: 500), anchor: Duration(seconds: 10)));
  });

  test('equal grids hash alike and say what they are', () {
    expect(grid.hashCode, const BeatGrid(period: Duration(milliseconds: 500), anchor: Duration(seconds: 10)).hashCode);
    expect(grid.toString(), 'BeatGrid(500 ms from 10000 ms)');
  });
}
