import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A saved (or discovered) Jellyfin / Emby server.
class JellyfinServer {
  const JellyfinServer({
    required this.name,
    required this.url,
    this.username = '',
    this.token,
    this.userId,
    this.allowSelfSigned = false,
    this.autoDiscovered = false,
  });

  final String name;

  /// Normalized base URL without trailing slash, e.g. `http://192.168.1.16:8096`.
  final String url;

  final String username;
  final String? token;
  final String? userId;

  /// Trusts any certificate when talking to this server (self-signed HTTPS).
  final bool allowSelfSigned;

  /// True when this came from mDNS discovery (not persisted).
  final bool autoDiscovered;

  bool get isAuthenticated => token != null && token!.isNotEmpty && userId != null;

  String get urlHost {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  static const Object _unset = Object();

  JellyfinServer copyWith({
    String? name,
    String? url,
    String? username,
    Object? token = _unset,
    Object? userId = _unset,
    bool? allowSelfSigned,
    bool? autoDiscovered,
  }) {
    return JellyfinServer(
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      token: identical(token, _unset) ? this.token : token as String?,
      userId: identical(userId, _unset) ? this.userId : userId as String?,
      allowSelfSigned: allowSelfSigned ?? this.allowSelfSigned,
      autoDiscovered: autoDiscovered ?? this.autoDiscovered,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'username': username,
        'token': token,
        'userId': userId,
        'allowSelfSigned': allowSelfSigned,
      };

  factory JellyfinServer.fromJson(Map<String, dynamic> json) {
    return JellyfinServer(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      token: json['token'] as String?,
      userId: json['userId'] as String?,
      allowSelfSigned: (json['allowSelfSigned'] as bool?) ?? false,
    );
  }
}

/// A library / folder / playable item as returned by the Jellyfin API.
class JellyfinItem {
  const JellyfinItem({
    required this.id,
    required this.name,
    this.isFolder = false,
    this.mediaType,
    this.type,
    this.runTimeTicks,
    this.width,
    this.height,
    this.mediaSourceId,
    this.container,
  });

  final String id;
  final String name;
  final bool isFolder;

  /// `Video`, `Audio` or null.
  final String? mediaType;

  /// e.g. `Movie`, `Episode`, `Series`, `CollectionFolder`, `Folder`.
  final String? type;
  final int? runTimeTicks;
  final int? width;
  final int? height;

  /// Media source id for the direct stream URL (falls back to [id]).
  final String? mediaSourceId;
  final String? container;

  Duration get duration => Duration(microseconds: (runTimeTicks ?? 0) ~/ 10);

  bool get isPlayable => !isFolder && (mediaType == 'Video' || mediaType == 'Audio');

  String get resolution => width != null && height != null ? '${width!}x${height!}' : '';

  String get durationLabel {
    if (duration <= Duration.zero) return '';
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}h';
    return '${m}m';
  }

  factory JellyfinItem.fromJson(Map<String, dynamic> json) {
    final mediaSources = json['MediaSources'] as List? ?? const [];
    final firstSource = mediaSources.isNotEmpty ? mediaSources.first : null;
    String? mediaSourceId;
    if (firstSource is Map<String, dynamic>) {
      mediaSourceId = firstSource['Id'] as String?;
    }
    final mediaType = json['MediaType'] as String?;
    return JellyfinItem(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      isFolder: (json['IsFolder'] as bool?) ?? false,
      mediaType: mediaType,
      type: json['Type'] as String?,
      runTimeTicks: (json['RunTimeTicks'] as num?)?.toInt(),
      width: (json['Width'] as num?)?.toInt(),
      height: (json['Height'] as num?)?.toInt(),
      mediaSourceId: mediaSourceId ?? json['Id'] as String?,
      container: json['Container'] as String?,
    );
  }
}

/// Result of a connection test.
class JellyfinConnectionInfo {
  const JellyfinConnectionInfo({required this.serverName, required this.version, required this.serverId});
  final String serverName;
  final String version;
  final String serverId;
}

class JellyfinException implements Exception {
  const JellyfinException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// REST + mDNS client for Jellyfin / Emby servers.
///
/// The stream URL carries the token as an `api_key` query parameter (Jellyfin
/// accepts it there or as an `X-Emby-Token` header), so playback works through
/// the existing ExoPlayer/Media3 (Android) and AetherEngine (iOS) HTTP stacks
/// with zero native changes.
class JellyfinClient {
  JellyfinClient([this._prefs]);

  static const _serversKey = 'dreamplayer.jellyfinServers';

  final SharedPreferences? _prefs;
  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> get _sharedPrefs async => _cachedPrefs ??= _prefs ?? await SharedPreferences.getInstance();

  String get _authHeader {
    return 'MediaBrowser Client="DreamPlayer", Device="DreamPlayer", '
        'DeviceId="${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}", Version="1.0.0"';
  }

  /// Normalizes user input into a usable base URL.
  static String normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!u.contains('://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Builds an [HttpClient] honoring [allowSelfSigned].
  HttpClient _httpClient({required bool allowSelfSigned}) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    if (allowSelfSigned) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    required bool allowSelfSigned,
    Map<String, String>? headers,
    int timeoutSeconds = 15,
  }) async {
    final client = _httpClient(allowSelfSigned: allowSelfSigned);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSeconds));
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(Duration(seconds: timeoutSeconds));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw const JellyfinException('Session expired — sign in again.');
      }
      if (res.statusCode >= 400) {
        throw JellyfinException('Server error ${res.statusCode}');
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on HandshakeException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on TimeoutException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on FormatException {
      throw const JellyfinException('Server returned an unexpected response.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required bool allowSelfSigned,
    Map<String, String>? headers,
    Map<String, dynamic>? body,
    int timeoutSeconds = 15,
  }) async {
    final client = _httpClient(allowSelfSigned: allowSelfSigned);
    try {
      final req = await client
          .postUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSeconds));
      headers?.forEach((k, v) => req.headers.set(k, v));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(Duration(seconds: timeoutSeconds));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw const JellyfinException('Login failed — check username and password.');
      }
      if (res.statusCode >= 400) {
        throw JellyfinException('Server error ${res.statusCode}');
      }
      if (text.isEmpty) return const {};
      return jsonDecode(text) as Map<String, dynamic>;
    } on SocketException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on HandshakeException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on TimeoutException catch (e) {
      throw JellyfinException(friendlyError(e));
    } on FormatException {
      throw const JellyfinException('Server returned an unexpected response.');
    } finally {
      client.close(force: true);
    }
  }

  /// GET /System/Info/Public — works without authentication.
  Future<JellyfinConnectionInfo> testConnection(String rawUrl, {bool allowSelfSigned = false}) async {
    final url = normalizeUrl(rawUrl);
    if (url.isEmpty) {
      throw const JellyfinException('Enter a server URL.');
    }
    final json = await _getJson('$url/System/Info/Public', allowSelfSigned: allowSelfSigned);
    final serverName = json['ServerName'] as String? ?? json['LocalAddress'] as String? ?? url;
    return JellyfinConnectionInfo(
      serverName: serverName,
      version: json['Version'] as String? ?? '?',
      serverId: json['Id'] as String? ?? url,
    );
  }

  /// POST /Users/AuthenticateByName — returns a server with token + userId.
  Future<JellyfinServer> authenticate(
    JellyfinServer server, {
    required String username,
    required String password,
  }) async {
    if (password.isEmpty) {
      throw const JellyfinException('Enter a password.');
    }
    final json = await _postJson(
      '${server.url}/Users/AuthenticateByName',
      allowSelfSigned: server.allowSelfSigned,
      headers: {
        'X-Emby-Authorization': _authHeader,
        'X-Emby-Token': server.token ?? '',
      },
      body: {'Username': username, 'Pw': password},
    );
    final user = json['User'] as Map<String, dynamic>? ?? const {};
    final token = json['AccessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw const JellyfinException('Login failed — check username and password.');
    }
    return server.copyWith(
      username: username,
      token: token,
      userId: user['Id'] as String?,
    );
  }

  List<JellyfinItem> _itemsFromJson(Map<String, dynamic> json) {
    final items = json['Items'] as List? ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinItem.fromJson)
        .where((it) => it.id.isNotEmpty)
        .toList();
  }

  /// Top-level media libraries for the signed-in user.
  Future<List<JellyfinItem>> getLibraries(JellyfinServer server) async {
    final userId = server.userId ?? '';
    final json = await _getJson(
      '${server.url}/Users/$userId/Views?api_key=${server.token}',
      allowSelfSigned: server.allowSelfSigned,
    );
    return _itemsFromJson(json);
  }

  /// Children of a folder/library. Empty [parentId] returns top-level items.
  Future<List<JellyfinItem>> getItems(JellyfinServer server, String parentId) async {
    final userId = server.userId ?? '';
    final uri = Uri.parse('${server.url}/Users/$userId/Items').replace(
      queryParameters: {
        'api_key': server.token ?? '',
        'ParentId': parentId,
        'Recursive': 'false',
        'Fields': 'MediaSources,Width,Height',
      },
    );
    final json = await _getJson(uri.toString(), allowSelfSigned: server.allowSelfSigned);
    return _itemsFromJson(json);
  }

  /// Direct-play stream URL (token as `api_key`). Plays via the existing HTTP
  /// data sources on both platforms; [allowSelfSigned] is honored through the
  /// same opt-in permissive path as self-signed WebDAV.
  String streamUrl(JellyfinServer server, JellyfinItem item) {
    final base = item.mediaType == 'Audio'
        ? '${server.url}/Audio/${item.id}/stream'
        : '${server.url}/Videos/${item.id}/stream';
    final uri = Uri.parse(base).replace(queryParameters: {
      'static': 'true',
      'mediaSourceId': item.mediaSourceId ?? item.id,
      'api_key': server.token ?? '',
    });
    return uri.toString();
  }

  /// Stable resume key for a Jellyfin item, surviving session token rotation.
  String resumeKey(JellyfinServer server, JellyfinItem item) =>
      'jellyfin:${server.urlHost}/${item.id}';

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<List<JellyfinServer>> loadServers() async {
    final prefs = await _sharedPrefs;
    final raw = prefs.getString(_serversKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(JellyfinServer.fromJson)
          .where((s) => s.url.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveServers(List<JellyfinServer> servers) async {
    final prefs = await _sharedPrefs;
    await prefs.setString(
      _serversKey,
      jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  // ---------------------------------------------------------------------------
  // mDNS discovery (_jellyfin._tcp / _emby._tcp)
  // ---------------------------------------------------------------------------

  /// Scans the local network for Jellyfin/Emby servers and probes each found
  /// address for its public info. Returns reachable servers (unauth'd).
  Future<List<JellyfinServer>> discoverServers() async {
    final resolver = MDnsClient();
    final found = <String, (String, int)>{};
    try {
      await resolver.start().timeout(const Duration(seconds: 3));
      for (final service in const ['_jellyfin._tcp', '_emby._tcp']) {
        try {
          await for (final ptr
              in resolver.lookup<PtrResourceRecord>(
                    ResourceRecordQuery.serverPointer(service),
                    timeout: const Duration(seconds: 2),
                  )) {
            await _resolveService(resolver, ptr.name, found);
            await _resolveService(resolver, ptr.domainName, found);
          }
        } catch (_) {}
      }
    } catch (_) {
      // Multicast may be unavailable (Android Wi-Fi, no network). Return what
      // was found so far — manual add remains the fallback.
    } finally {
      try {
        resolver.stop();
      } catch (_) {}
    }

    final servers = <JellyfinServer>[];
    final seen = <String>{};
    for (final (address, port) in found.values) {
      final url = 'http://$address:$port';
      try {
        final info = await testConnection(url).timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw const JellyfinException('timeout'),
        );
        if (seen.add('${info.serverName}@$url')) {
          servers.add(JellyfinServer(
            name: info.serverName,
            url: url,
            autoDiscovered: true,
          ));
        }
      } catch (_) {
        // Unreachable/unauth'd probe — skip.
      }
    }
    servers.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return servers;
  }

  /// Resolves the SRV + A records for an mDNS service instance name and records
  /// every reachable `address:port` pair. SRV targets that are bare IPs are
  /// used directly (no A lookup possible for an address literal).
  Future<void> _resolveService(
    MDnsClient resolver,
    String instanceName,
    Map<String, (String, int)> found,
  ) async {
    try {
      await for (final srv
          in resolver.lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(instanceName),
                timeout: const Duration(seconds: 2),
              )) {
        final target = srv.target.replaceAll(RegExp(r'\.$'), '');
        final isIp = InternetAddress.tryParse(target) != null;
        if (isIp) {
          found['$target:${srv.port}'] = (target, srv.port);
          continue;
        }
        try {
          await for (final ip
              in resolver.lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target),
                    timeout: const Duration(seconds: 2),
                  )) {
            found['${ip.address.address}:${srv.port}'] = (
              ip.address.address,
              srv.port,
            );
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Maps low-level IO errors to plain-language messages.
  static String friendlyError(Object e) {
    if (e is HandshakeException) {
      return 'Certificate not trusted — enable "Allow self-signed".';
    }
    if (e is SocketException) {
      return 'Can\'t connect — check the address.';
    }
    if (e is TimeoutException) {
      return 'Timed out — is the server on and the port right?';
    }
    if (e is JellyfinException) return e.message;
    debugPrint('jellyfin: ${e.runtimeType} $e');
    return 'Something went wrong ($e)';
  }
}
