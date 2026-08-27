import 'package:flutter/services.dart';

/// A signed-in Google Drive account.
class GDriveAccount {
  const GDriveAccount({
    required this.id,
    required this.email,
    this.displayName = '',
    this.hasRefreshToken = false,
  });

  final String id;
  final String email;
  final String displayName;
  final bool hasRefreshToken;

  String get label => displayName.isNotEmpty ? displayName : email;

  factory GDriveAccount.fromMap(Map<dynamic, dynamic> m) {
    return GDriveAccount(
      id: (m['id'] as String?) ?? '',
      email: (m['email'] as String?) ?? '',
      displayName: (m['displayName'] as String?) ?? '',
      hasRefreshToken: (m['hasRefreshToken'] as bool?) ?? false,
    );
  }
}

/// A file or folder entry from Google Drive.
class GDriveEntry {
  const GDriveEntry({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.isDirectory,
    this.size = 0,
  });

  final String id;
  final String name;
  final String mimeType;
  final bool isDirectory;
  final int size;

  factory GDriveEntry.fromMap(Map<dynamic, dynamic> m) {
    return GDriveEntry(
      id: (m['id'] as String?) ?? '',
      name: (m['name'] as String?) ?? '',
      mimeType: (m['mimeType'] as String?) ?? '',
      isDirectory: (m['isDirectory'] as bool?) ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Wraps the native `dreamplayer/gdrive` channel (see `GDriveClient.kt` /
/// `GDriveClient.swift`).
class GDriveClient {
  GDriveClient._();

  static final GDriveClient instance = GDriveClient._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/gdrive');

  Future<List<GDriveAccount>> listAccounts() async {
    final result = await _channel.invokeListMethod<dynamic>('listAccounts');
    if (result == null) return const [];
    return result
        .map((e) => GDriveAccount.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Launches the native OAuth flow and returns the signed-in account.
  /// [clientId] / [clientSecret] are the Web OAuth credentials (see
  /// `cloud_keys.dart`); when empty the native side uses its bundled value.
  Future<GDriveAccount> signIn({
    String? clientId,
    String? clientSecret,
  }) async {
    final result = await _channel.invokeMethod<dynamic>('signIn', {
      if (clientId != null && clientId.isNotEmpty) 'clientId': clientId,
      if (clientSecret != null && clientSecret.isNotEmpty)
        'clientSecret': clientSecret,
    });
    return GDriveAccount.fromMap((result as Map<dynamic, dynamic>?) ?? const {});
  }

  Future<void> signOut(String id) async {
    await _channel.invokeMethod<void>('signOut', {'id': id});
  }

  /// Lists files in [folderId] (`'root'` for the Drive root).
  Future<List<GDriveEntry>> listDirectory(
    String accountId,
    String folderId,
  ) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'accountId': accountId,
      'folderId': folderId,
    });
    if (result == null) return const [];
    return result
        .map((e) => GDriveEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Ready-made `Authorization: Bearer …` header for [accountId].
  Future<String> authorizationHeader(String accountId) async {
    final result = await _channel.invokeMethod<String>(
      'authorizationHeader',
      {'accountId': accountId},
    );
    if (result == null || result.isEmpty) {
      throw PlatformException(
        code: 'authorizationHeader',
        message: 'No auth header',
      );
    }
    return result;
  }

  /// Fresh access token for [accountId] (refreshes when expired).
  Future<String> getFreshAccessToken(String accountId) async {
    final result = await _channel.invokeMethod<String>(
      'getFreshAccessToken',
      {'accountId': accountId},
    );
    if (result == null || result.isEmpty) {
      throw PlatformException(
        code: 'getFreshAccessToken',
        message: 'No access token',
      );
    }
    return result;
  }
}
