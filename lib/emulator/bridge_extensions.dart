// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

/// A request to one version of a plugin's API on the emulated bridge, at
/// `/__plugins__/<plugin>/v<version>/<path>`.
class ExtensionRequest {
  const ExtensionRequest({
    required this.method,
    required this.path,
    required this.appKey,
    required this.base,
    this.body,
  });

  final String method;

  /// The path after the version, such as `['settings']`; empty for the root.
  final List<String> path;

  /// The paired app's key, from the `hue-application-key` header.
  final String appKey;

  /// Where this version lives, such as `/__plugins__/music-sync/v1.0.0`.
  final String base;

  /// The decoded JSON body, or null.
  final Object? body;

  /// The link to [path] within this version; the root ends in a slash.
  String href([String path = '']) => '$base/$path';
}

/// Answers an [ExtensionRequest] with an HTTP status and a JSON value. Like
/// the Hue API it answers at once: work that takes time is started and its
/// progress read back with later requests.
typedef ExtensionHandler = (int, Object) Function(ExtensionRequest request);

/// Lumen's own APIs on the emulated Hue Bridge, kept apart from the Hue API
/// under [prefix]. Each plugin registers a kebab-case name and one or more
/// semantic versions, and clients discover them by following links:
///
/// - `GET /__plugins__` lists the plugins, each with a `self` link.
/// - `GET /__plugins__/<plugin>` gives its versions, oldest first, each with
///   its link, and a `latest` link.
/// - `/__plugins__/<plugin>/v<major.minor.patch>/...` is that version's API.
///   It needs the key of a paired app in the `hue-application-key` header,
///   as the Hue v2 API does; discovery needs none.
///
/// Answers use HTTP status codes; errors are `{"error": {"type": ...,
/// "description": ...}, "links": ...}`, linking to where to look instead.
/// Links are `{"rel": {"href": ..., "method": ...}}`, the method only where
/// it is not GET.
class BridgeExtensions {
  static const prefix = '__plugins__';
  static const keyHeader = 'hue-application-key';

  static final _name = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');
  static final _semver = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');

  final Map<String, _Plugin> _plugins = {};

  /// The registered plugins' names, sorted.
  List<String> get plugins => _plugins.keys.toList()..sort();

  static String _index() => '/$prefix';
  static String _details(String plugin) => '/$prefix/$plugin';
  static String _root(String plugin, String version) => '/$prefix/$plugin/v$version/';

  /// Serves [handler] as [version] (`major.minor.patch`) of [plugin]. [title]
  /// is for people; [experimental] says the API may still change.
  void register({
    required String plugin,
    required String version,
    required String title,
    required ExtensionHandler handler,
    bool experimental = false,
  }) {
    if (!_name.hasMatch(plugin)) throw ArgumentError.value(plugin, 'plugin', 'not kebab-case');
    if (!_semver.hasMatch(version)) throw ArgumentError.value(version, 'version', 'not major.minor.patch');
    final entry = _plugins.putIfAbsent(plugin, () => _Plugin(title, experimental));
    if (entry.versions.containsKey(version)) throw StateError('$plugin v$version is already registered');
    entry.versions[version] = handler;
  }

  /// Stops serving every version of [plugin].
  void unregister(String plugin) => _plugins.remove(plugin);

  /// Answers a request for [path], the segments after [prefix]. [appKey] is
  /// the `hue-application-key` header and [paired] whether it is a paired
  /// app's key.
  (int, Object) handle(String method, List<String> path, {String? appKey, bool paired = false, Object? body}) {
    switch (path) {
      case []:
        if (method != 'GET') return _notAllowed(method, _index());
        return (200, {
          'plugins': [for (final p in plugins) _summary(p)],
          'links': _links({'self': _index()}),
        });
      default:
        final plugin = path.first;
        final rest = path.sublist(1);
        final entry = _plugins[plugin];
        if (entry == null) {
          return error(404, 'not-found', 'There is no plugin called $plugin', links: {'plugins': _index()});
        }
        if (rest.isEmpty) return method == 'GET' ? (200, _describe(plugin)) : _notAllowed(method, _details(plugin));
        final segment = rest.first;
        final version = segment.startsWith('v') ? segment.substring(1) : null;
        final handler = entry.versions[version];
        if (version == null || handler == null) {
          return error(
            404,
            'not-found',
            '$plugin has no version ${version ?? segment}; it has ${entry.sorted.join(', ')}',
            links: {'plugin': _details(plugin)},
          );
        }
        if (!paired || appKey == null) {
          return error(
            401,
            'unauthorized',
            'Send the key of a paired app in the $keyHeader header',
            links: {'plugin': _details(plugin)},
          );
        }
        return handler(
          ExtensionRequest(
            method: method,
            path: rest.sublist(1),
            appKey: appKey,
            base: '/$prefix/$plugin/v$version',
            body: body,
          ),
        );
    }
  }

  Map<String, Object> _summary(String plugin) {
    final entry = _plugins[plugin]!;
    return {
      'name': plugin,
      'title': entry.title,
      'experimental': entry.experimental,
      'links': _links({'self': _details(plugin)}),
    };
  }

  Map<String, Object> _describe(String plugin) {
    final entry = _plugins[plugin]!;
    final versions = entry.sorted;
    return {
      'name': plugin,
      'title': entry.title,
      'experimental': entry.experimental,
      'versions': [
        for (final v in versions)
          {
            'version': v,
            'links': _links({'self': _root(plugin, v)}),
          },
      ],
      'links': _links({'self': _details(plugin), 'latest': _root(plugin, versions.last), 'plugins': _index()}),
    };
  }

  static Map<String, Object> _links(Map<String, String> hrefs) => {
    for (final MapEntry(:key, :value) in hrefs.entries) key: {'href': value},
  };

  static (int, Object) _notAllowed(String method, String address) =>
      error(405, 'method-not-allowed', '$method is not allowed on $address', links: {'self': address});

  /// An error answer: [type] is kebab-case, [description] is for people, and
  /// [links] point to where to look instead.
  static (int, Object) error(int status, String type, String description, {Map<String, String> links = const {}}) =>
      (status, {
        'error': {'type': type, 'description': description},
        if (links.isNotEmpty) 'links': _links(links),
      });
}

class _Plugin {
  _Plugin(this.title, this.experimental);

  final String title;
  final bool experimental;
  final Map<String, ExtensionHandler> versions = {};

  /// The versions, oldest first.
  List<String> get sorted {
    List<int> parts(String v) => [for (final p in v.split('.')) int.parse(p)];
    int compare(String a, String b) {
      final (x, y) = (parts(a), parts(b));
      for (var i = 0; i < 3; i++) {
        if (x[i] != y[i]) return x[i].compareTo(y[i]);
      }
      return 0;
    }

    return versions.keys.toList()..sort(compare);
  }
}
