import 'package:flutter/services.dart';

/// A saved SMB server (see `SMBClient.swift` / `SMBClient.kt`). Passwords
/// never cross to Dart — only `hasPassword` (native sides keep them in
/// Keychain / Keystore).
class SmbServer {
  const SmbServer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.domain,
    required this.anonymous,
    required this.hasPassword,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String domain;
  final bool anonymous;
  final bool hasPassword;

  String get credentialLabel =>
      anonymous || username.isEmpty ? 'Guest' : username;

  String get subtitle {
    final auth = domain.isNotEmpty ? '$domain\\$credentialLabel' : credentialLabel;
    return '$host:$port · $auth';
  }

  factory SmbServer.fromMap(Map<dynamic, dynamic> m) {
    return SmbServer(
      id: (m['id'] as String?) ?? '',
      name: (m['name'] as String?) ?? '',
      host: (m['host'] as String?) ?? '',
      port: (m['port'] as num?)?.toInt() ?? 445,
      username: (m['username'] as String?) ?? '',
      domain: (m['domain'] as String?) ?? '',
      anonymous: (m['anonymous'] as bool?) ?? false,
      hasPassword: (m['hasPassword'] as bool?) ?? false,
    );
  }
}

/// A share or folder/file entry returned by the native SMB browser.
class SmbEntry {
  const SmbEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.subtitlePath,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final int modified;

  /// For video entries: the relative path of an auto-paired subtitle file
  /// (`.srt`/`.ass`/...) sitting next to the video in the same folder.
  final String? subtitlePath;

  factory SmbEntry.fromMap(Map<dynamic, dynamic> m) {
    return SmbEntry(
      name: (m['name'] as String?) ?? '',
      path: (m['path'] as String?) ?? '',
      isDirectory: (m['isDirectory'] as bool?) ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
      modified: (m['modified'] as num?)?.toInt() ?? 0,
      subtitlePath: m['subtitlePath'] as String?,
    );
  }
}

/// A host found on the LAN by the native subnet scan.
class SmbDiscovered {
  const SmbDiscovered({required this.host, required this.hostname});

  final String host;
  final String hostname;

  factory SmbDiscovered.fromMap(Map<dynamic, dynamic> m) {
    return SmbDiscovered(
      host: (m['host'] as String?) ?? '',
      hostname: (m['hostname'] as String?) ?? '',
    );
  }
}

/// Result of a quick connection test.
typedef SmbTestResult = ({bool ok, String? error});

/// Wraps the native `dreamplayer/smb` channel (see `SMBClient.swift` /
/// `SMBClient.kt`).
class SmbClient {
  SmbClient._();

  static final SmbClient instance = SmbClient._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/smb');

  Future<List<SmbServer>> listServers() async {
    final result = await _channel.invokeListMethod<dynamic>('listServers');
    if (result == null) return const [];
    return result
        .map((e) => SmbServer.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Saves a server; pass [id] to update an existing one.
  Future<SmbServer> saveServer({
    String? id,
    required String name,
    required String host,
    int port = 445,
    String username = '',
    String password = '',
    String domain = '',
    bool anonymous = false,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('saveServer', {
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'domain': domain,
      'anonymous': anonymous,
    });
    return SmbServer.fromMap((result as Map<dynamic, dynamic>?) ?? const {});
  }

  Future<void> deleteServer(String id) async {
    await _channel.invokeMethod<void>('deleteServer', {'id': id});
  }

  /// Tests a connection without saving (used by the add/edit dialog).
  Future<SmbTestResult> testConnection({
    required String host,
    int port = 445,
    String username = '',
    String password = '',
    String domain = '',
    bool anonymous = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'testConnection',
      {
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'domain': domain,
        'anonymous': anonymous,
      },
    );
    return (
      ok: result?['ok'] == true,
      error: result?['error'] as String?,
    );
  }

  Future<List<SmbEntry>> listShares(String serverId) async {
    final result = await _channel.invokeListMethod<dynamic>('listShares', {
      'id': serverId,
    });
    if (result == null) return const [];
    return result
        .map((e) => SmbEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Remembers a share name for a server (for shares the server won't
  /// enumerate, so unusual names can be added by hand after the auto-probe).
  Future<bool> addShare(String serverId, String shareName) async {
    final result = await _channel.invokeMethod<bool>('addShare', {
      'id': serverId,
      'share': shareName,
    });
    return result ?? false;
  }

  Future<List<SmbEntry>> listDirectory(
    String serverId,
    String share,
    String path,
  ) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'id': serverId,
      'share': share,
      'path': path,
    });
    if (result == null) return const [];
    return result
        .map((e) => SmbEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Opens a file on the share for streaming and returns a playable local URL.
  /// iOS serves it through the in-app loopback HTTP proxy (AMSMB2 reads, same
  /// shape as the CX Explorer handoff); each call returns its own URL so a
  /// folder playlist can open every video up-front. Call [closeShare] when the
  /// browsing session ends to tear down the streams and disconnect.
  Future<String> openShare(String serverId, String share, String path) async {
    final result = await _channel.invokeMethod<String>('openShare', {
      'id': serverId,
      'share': share,
      'path': path,
    });
    if (result == null || result.isEmpty) {
      throw PlatformException(code: 'openShare', message: 'Could not open share');
    }
    return result;
  }

  Future<void> closeShare(String serverId) async {
    await _channel.invokeMethod<void>('closeShare', {'id': serverId});
  }

  /// LAN scan for reachable SMB hosts (native subnet 445 probe + name
  /// resolution). Returns empty when off-Wi-Fi or nothing responds.
  Future<List<SmbDiscovered>> discoverServers() async {
    final result = await _channel.invokeListMethod<dynamic>('discoverServers');
    if (result == null) return const [];
    return result
        .map((e) => SmbDiscovered.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Quick reachability probe used for the saved-server online/offline dot.
  Future<bool> checkServer(String host, int port) async {
    final result = await _channel.invokeMethod<bool>('checkServer', {
      'host': host,
      'port': port,
    });
    return result ?? false;
  }
}
