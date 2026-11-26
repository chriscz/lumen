// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

// Checks line coverage from an lcov file against every Dart file in lib/.
//
//   dart run tool/check_coverage.dart [coverage/lcov.info] [--min 100] [--file <path>]
//
// A file in lib/ that no test loads counts as fully uncovered. Lines marked
// `// coverage:ignore-line`, or between `// coverage:ignore-start` and
// `// coverage:ignore-end`, or in a file with `// coverage:ignore-file`, are
// already left out of the lcov data by the Flutter test runner. Prints the
// uncovered lines per file and exits 1 below the minimum.
// A command-line tool: printing is its output.
// ignore_for_file: avoid_print

import 'dart:io';

void main(List<String> args) {
  var lcov = 'coverage/lcov.info';
  var min = 100.0;
  String? only;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--min':
        min = double.parse(args[++i]);
      case '--file':
        only = args[++i];
      default:
        lcov = args[i];
    }
  }
  final found = <String, Map<int, int>>{};
  String? current;
  for (final line in File(lcov).readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      current = line.substring(3);
      found.putIfAbsent(current, () => {});
    } else if (line.startsWith('DA:') && current != null) {
      final [n, hits, ...] = line.substring(3).split(',');
      final lines = found[current]!;
      lines[int.parse(n)] = (lines[int.parse(n)] ?? 0) + int.parse(hits);
    }
  }
  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.dart') && !p.endsWith('.g.dart'))
      .toList()
    ..sort();
  var total = 0, hit = 0;
  final report = <String>[];
  for (final path in libFiles) {
    if (only != null && path != only) continue;
    final lines = found[path];
    if (lines == null) {
      final ignored = File(path).readAsStringSync().contains('coverage:ignore-file');
      if (ignored) continue;
      report.add('$path: not loaded by any test');
      total += 1;
      continue;
    }
    final missed = [for (final e in lines.entries) if (e.value == 0) e.key]..sort();
    total += lines.length;
    hit += lines.length - missed.length;
    if (missed.isNotEmpty) report.add('$path: ${missed.length} uncovered: ${_ranges(missed)}');
  }
  final pct = total == 0 ? 100.0 : 100 * hit / total;
  report.forEach(print);
  print('line coverage ${pct.toStringAsFixed(2)}% ($hit of $total), minimum $min%');
  exit(pct + 1e-9 >= min ? 0 : 1);
}

String _ranges(List<int> lines) {
  final parts = <String>[];
  var start = lines.first, prev = lines.first;
  for (final n in lines.skip(1)) {
    if (n == prev + 1) {
      prev = n;
      continue;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    start = prev = n;
  }
  parts.add(start == prev ? '$start' : '$start-$prev');
  return parts.join(', ');
}
