// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/light.dart';
import '../log/logger.dart';
import 'home_scope.dart';
import 'widgets/prompts.dart';

/// The app's log and a short system summary, to share when something fails.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  LogLevel _minimum = LogLevel.debug;
  Future<Map<String, String>>? _status;

  /// The entries at [_minimum] and above, kept until the log or the level
  /// changes, so a rebuild for anything else does not filter them again.
  List<LogEntry> _filtered = const [];
  (LogLevel, int)? _filteredFor;

  List<LogEntry> _shown(Logger log) {
    final key = (_minimum, log.revision);
    if (key != _filteredFor) {
      _filteredFor = key;
      _filtered = log.entries.where((e) => e.level.index >= _minimum.index).toList();
    }
    return _filtered;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _status ??= HomeScope.read(context).bluetoothStatus();
  }

  static String size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  Future<void> _copy(Logger log) async {
    final messenger = ScaffoldMessenger.of(context);
    log.flush();
    final text = log.directory == null ? log.tail(log.entries.length) : log.readAll();
    await Clipboard.setData(ClipboardData(text: text.isEmpty ? log.tail(log.entries.length) : text));
    messenger.show('Log copied');
  }

  /// Shares the whole log as one file; the share sheet also offers Files or
  /// Drive, which is how Save a copy reaches Downloads.
  Future<void> _share(Logger log, {required bool save}) async {
    log.info(LogTag.ui, save ? 'save a copy of the log' : 'share the log');
    final dir = log.directory;
    try {
      if (dir == null) {
        await SharePlus.instance.share(ShareParams(text: log.tail(log.entries.length), subject: 'Lumen log'));
        return;
      }
      final file = log.export(Directory('${dir.path}/exports'));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          subject: 'Lumen log',
          text: save ? null : 'Lumen diagnostics log',
        ),
      );
    } catch (e) {
      log.warning(LogTag.ui, 'sharing the log failed: $e');
      if (mounted) ScaffoldMessenger.of(context).show('Could not share the log: $e');
    }
  }

  Future<void> _clear(Logger log) async {
    final ok = await confirm(
      context,
      title: 'Clear the log?',
      body: 'Every saved log entry is deleted, from this run and earlier ones.',
      action: 'Clear',
    );
    if (ok) log.clear();
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScope.of(context);
    final log = home.log;
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 11.5, height: 1.3);
    final bulbs = home.lights.where((l) => l.transport == Transport.ble).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            key: const ValueKey('copy-log'),
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: () => _copy(log),
          ),
          IconButton(
            key: const ValueKey('share-log'),
            tooltip: 'Share',
            icon: const Icon(Icons.share_rounded),
            onPressed: () => _share(log, save: false),
          ),
          IconButton(
            key: const ValueKey('save-log'),
            tooltip: 'Save a copy',
            icon: const Icon(Icons.download_rounded),
            onPressed: () => _share(log, save: true),
          ),
          if (home.debugLogging)
            IconButton(
              key: const ValueKey('clear-log'),
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: () => _clear(log),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final entries = _shown(log);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FutureBuilder(
                future: _status,
                builder: (context, snapshot) {
                  final status = snapshot.data ?? const {};
                  Widget row(String key, String label, String value) => Padding(
                    key: ValueKey('summary-$key'),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(width: 140, child: Text(label, style: theme.textTheme.bodySmall)),
                        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
                      ],
                    ),
                  );
                  return Card(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          row('bluetooth', 'Bluetooth', status['Bluetooth'] ?? '...'),
                          row('permissions', 'Permissions', status['Permissions'] ?? '...'),
                          row('lights', 'Lights', '${home.lights.length}'),
                          row('connected', 'Connected bulbs', '${home.connectedBulbCount} of $bulbs'),
                          row('debug', 'Debug logging', home.debugLogging ? 'on' : 'off'),
                          row('log-size', 'Log size', size(log.totalBytes)),
                        ],
                      ),
                    ),
                  );
                },
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  spacing: 8,
                  children: [
                    for (final (level, label) in const [
                      (LogLevel.debug, 'All'),
                      (LogLevel.info, 'Info'),
                      (LogLevel.warning, 'Warnings'),
                      (LogLevel.error, 'Errors'),
                    ])
                      ChoiceChip(
                        key: ValueKey('level-${level.name}'),
                        label: Text(label),
                        selected: _minimum == level,
                        onSelected: (_) => setState(() => _minimum = level),
                      ),
                  ],
                ),
              ),
              const Divider(height: 16),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('No log entries'))
                    : ListView.builder(
                        // Newest at the bottom, and the view starts there.
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[entries.length - 1 - i];
                          final color = switch (e.level) {
                            LogLevel.error => theme.colorScheme.error,
                            LogLevel.warning => theme.colorScheme.tertiary,
                            LogLevel.debug => theme.colorScheme.onSurfaceVariant,
                            LogLevel.info => theme.colorScheme.onSurface,
                          };
                          return SelectableText(e.format(), style: mono?.copyWith(color: color));
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
