// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum LogLevel {
  debug('D'),
  info('I'),
  warning('W'),
  error('E');

  const LogLevel(this.letter);

  final String letter;
}

enum LogTag { ble, bridge, controller, ui, app, music }

class LogEntry {
  const LogEntry(this.time, this.level, this.tag, this.message);

  final DateTime time;
  final LogLevel level;
  final LogTag tag;

  /// The message, followed by the error and stack trace when there are any.
  final String message;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// The day of [t], as year-month-day.
  static String date(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

  static String stamp(DateTime t) =>
      '${date(t)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
      '.${t.millisecond.toString().padLeft(3, '0')}';

  /// One line, with continuation lines of a multi-line message indented.
  String format() => '${stamp(time)} ${level.letter} ${tag.name.padRight(10)} ${message.replaceAll('\n', '\n  ')}';

  static final _line = RegExp(r'^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3}) ([DIWE]) (\w+)\s+(.*)$');

  /// Parses lines written by [format]. Lines that do not start an entry
  /// continue the one before.
  static List<LogEntry> parse(Iterable<String> lines) {
    final out = <LogEntry>[];
    for (final line in lines) {
      final m = _line.firstMatch(line);
      if (m == null) {
        if (out.isNotEmpty && line.isNotEmpty) {
          final last = out.removeLast();
          out.add(
            LogEntry(
              last.time,
              last.level,
              last.tag,
              '${last.message}\n${line.startsWith('  ') ? line.substring(2) : line}',
            ),
          );
        }
        continue;
      }
      int g(int i) => int.parse(m.group(i)!);
      out.add(
        LogEntry(
          DateTime(g(1), g(2), g(3), g(4), g(5), g(6), g(7)),
          LogLevel.values.firstWhere((l) => l.letter == m.group(8)),
          LogTag.values.asNameMap()[m.group(9)] ?? LogTag.app,
          m.group(10)!,
        ),
      );
    }
    return out;
  }
}

/// The app's log. Entries go to an in-memory ring for the Diagnostics screen
/// and, when a [directory] is given, to log files there in batches. Without
/// [persist] the files hold only the last [keptLines] entries. With it they
/// are kept between runs, split into segments of about [segmentBytes], and
/// only [clear] removes them.
class Logger extends ChangeNotifier {
  Logger({
    this.directory,
    bool? persist,
    this.keptLines = 100,
    this.segmentBytes = 1024 * 1024,
    this.flushInterval = const Duration(seconds: 1),
    this.capacity = 5000,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _persist = persist ?? _marker?.existsSync() ?? false;
    if (persist != null) _writeMarker();
    _restore();
    if (!_persist) _trim();
  }

  /// A logger that keeps entries in memory only, for tests and previews.
  Logger.memory({DateTime Function()? clock}) : this(clock: clock);

  final Directory? directory;

  /// The entries the files keep without [persist].
  int keptLines;

  final int segmentBytes;
  final Duration flushInterval;
  final int capacity;
  final DateTime Function() _clock;

  /// When on, debug entries are kept; otherwise info and above.
  bool debugEnabled = false;

  /// Whether the log is kept between runs. The choice is saved as a marker
  /// file in [directory], so it holds before the rest of the app loads.
  bool get persist => _persist;
  late bool _persist;

  set persist(bool on) {
    if (on == _persist) return;
    _persist = on;
    _writeMarker();
    if (!on) {
      flush();
      _trim();
    }
    notifyListeners();
  }

  File? get _marker => directory == null ? null : File('${directory!.path}/persist');

  void _writeMarker() {
    final marker = _marker;
    if (marker == null) return;
    try {
      if (_persist) {
        marker.parent.createSync(recursive: true);
        marker.writeAsStringSync('');
      } else if (marker.existsSync()) {
        marker.deleteSync();
      }
    } on FileSystemException catch (e) {
      debugPrint('log persist marker failed: $e');
    }
  }

  final ListQueue<LogEntry> _entries = ListQueue();
  final StringBuffer _pending = StringBuffer();

  /// UTF-8 bytes in [_pending], and in the log files.
  int _pendingBytes = 0;
  int _fileBytes = 0;

  /// The file [flush] appends to, its number and its size, found on the
  /// first flush and kept from then on.
  File? _segment;
  int _segmentIndex = 0;
  int _segmentSize = 0;
  final Set<String> _secrets = {};
  Timer? _timer;
  bool _notifyScheduled = false;
  bool _disposed = false;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Goes up with every entry kept and every [clear], so a reader can tell
  /// whether [entries] changed since it last looked.
  int get revision => _revision;
  int _revision = 0;

  static const _prefix = 'lumen-';
  static const _suffix = '.log';

  /// The log files, oldest first.
  List<File> get files {
    final dir = directory;
    if (dir == null || !dir.existsSync()) return const [];
    final found = dir.listSync().whereType<File>().where((f) {
      final name = f.uri.pathSegments.last;
      return name.startsWith(_prefix) && name.endsWith(_suffix);
    }).toList();
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  /// Bytes on disk plus what is waiting to be written.
  int get totalBytes => _fileBytes + _pendingBytes;

  static int _sizeOf(Iterable<File> files) => files.fold<int>(0, (sum, f) => sum + f.lengthSync());

  /// Shortens a secret such as a bridge app key to its first four characters.
  static String redact(String secret) => '${secret.length <= 4 ? secret : secret.substring(0, 4)}...';

  /// Every later message has [secret] replaced by its redacted form.
  void addSecret(String secret) {
    if (secret.length > 4) _secrets.add(secret);
  }

  void debug(LogTag tag, String Function() message) {
    if (debugEnabled) _add(LogLevel.debug, tag, message());
  }

  void info(LogTag tag, String message) => _add(LogLevel.info, tag, message);

  void warning(LogTag tag, String message, {Object? error, StackTrace? stack}) =>
      _add(LogLevel.warning, tag, _withError(message, error, stack));

  void error(LogTag tag, String message, {Object? error, StackTrace? stack}) =>
      _add(LogLevel.error, tag, _withError(message, error, stack));

  void log(LogLevel level, LogTag tag, String message) {
    if (level == LogLevel.debug && !debugEnabled) return;
    _add(level, tag, message);
  }

  static String _withError(String message, Object? error, StackTrace? stack) {
    final b = StringBuffer(message);
    if (error != null) b.write('\n$error');
    final s = stack?.toString().trimRight();
    if (s != null && s.isNotEmpty) b.write('\n$s');
    return b.toString();
  }

  void _add(LogLevel level, LogTag tag, String message) {
    var text = message;
    for (final s in _secrets) {
      text = text.replaceAll(s, redact(s));
    }
    final entry = LogEntry(_clock(), level, tag, text);
    _entries.add(entry);
    _revision++;
    if (_entries.length > capacity) _entries.removeFirst();
    if (directory != null) {
      final line = entry.format();
      _pending.writeln(line);
      _pendingBytes += utf8.encode(line).length + 1;
      _timer ??= Timer(flushInterval, flush);
    }
    // Listeners hear once per burst, outside any build in progress.
    if (!_notifyScheduled) {
      _notifyScheduled = true;
      scheduleMicrotask(() {
        _notifyScheduled = false;
        // A logger disposed right after an entry has no listeners left.
        if (!_disposed) notifyListeners();
      });
    }
  }

  /// Writes pending entries. With [persist] they go to the newest file, a
  /// new file starts when it has reached [segmentBytes]; without it the
  /// files are rewritten to the last [keptLines] entries.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final dir = directory;
    if (dir == null || _pending.isEmpty) return;
    final text = _pending.toString();
    final bytes = _pendingBytes;
    _pending.clear();
    _pendingBytes = 0;
    if (!_persist) return _trim();
    try {
      dir.createSync(recursive: true);
      if (_segment == null) _findSegment();
      if (_segment == null || _segmentSize >= segmentBytes) {
        _segmentIndex++;
        _segment = File('${dir.path}/$_prefix${_segmentIndex.toString().padLeft(5, '0')}$_suffix');
        _segmentSize = 0;
      }
      _segment!.writeAsStringSync(text, mode: FileMode.append, flush: true);
      _segmentSize += bytes;
      _fileBytes += bytes;
    } on FileSystemException catch (e) {
      debugPrint('log write failed: $e');
      // Look at the disk afresh next time, and count what did get there.
      _segment = null;
      _fileBytes = _sizeOf(files);
    }
  }

  /// Rewrites the files as one holding the last [keptLines] entries.
  void _trim() {
    final dir = directory;
    if (dir == null) return;
    final text = _entries.isEmpty ? '' : '${tail(keptLines)}\n';
    try {
      for (final f in files) {
        f.deleteSync();
      }
      _segment = null;
      _fileBytes = 0;
      if (text.isEmpty) return;
      dir.createSync(recursive: true);
      final file = File('${dir.path}/${_prefix}00001$_suffix')..writeAsStringSync(text, flush: true);
      _segment = file;
      _segmentIndex = 1;
      _segmentSize = _fileBytes = file.lengthSync();
    } on FileSystemException catch (e) {
      debugPrint('log write failed: $e');
      _segment = null;
      _fileBytes = _sizeOf(files);
    }
  }

  /// Picks up the newest file and its number, as an earlier run left them.
  void _findSegment() {
    final last = files.lastOrNull;
    if (last == null) {
      _segmentIndex = 0;
      return;
    }
    final name = last.uri.pathSegments.last;
    _segment = last;
    _segmentIndex = int.tryParse(name.substring(_prefix.length, name.length - _suffix.length)) ?? 0;
    _segmentSize = last.lengthSync();
  }

  /// Every log file, oldest first, plus entries not yet written.
  String readAll() {
    final b = StringBuffer();
    for (final f in files) {
      b.write(f.readAsStringSync());
    }
    return b.toString();
  }

  /// The last [lines] entries as text.
  String tail(int lines) {
    final from = _entries.length > lines ? _entries.length - lines : 0;
    return _entries.skip(from).map((e) => e.format()).join('\n');
  }

  /// Writes everything into one file for sharing, replacing an earlier export.
  File export(Directory into) {
    flush();
    into.createSync(recursive: true);
    for (final old in into.listSync().whereType<File>().where((f) => f.path.contains('lumen-log-'))) {
      old.deleteSync();
    }
    final t = _clock();
    final name = 'lumen-log-${LogEntry.stamp(t).replaceAll(RegExp('[^0-9]'), '').substring(0, 14)}.txt';
    return File('${into.path}/$name')..writeAsStringSync(readAll());
  }

  /// Removes every entry and log file.
  void clear() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _pendingBytes = 0;
    _entries.clear();
    _revision++;
    for (final f in files) {
      f.deleteSync();
    }
    _segment = null;
    _fileBytes = 0;
    notifyListeners();
  }

  /// Fills the ring with the end of the log from earlier runs.
  void _restore() {
    final all = files;
    _fileBytes = _sizeOf(all);
    if (all.isEmpty) return;
    final lines = <String>[];
    for (final f in all.reversed) {
      try {
        lines.insertAll(0, f.readAsLinesSync());
      } on FileSystemException {
        break;
      }
      if (lines.length >= capacity) break;
    }
    final restored = LogEntry.parse(lines);
    _entries.addAll(restored.length > capacity ? restored.sublist(restored.length - capacity) : restored);
  }

  @override
  void dispose() {
    flush();
    _disposed = true;
    super.dispose();
  }
}
