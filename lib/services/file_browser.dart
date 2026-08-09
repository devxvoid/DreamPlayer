import 'package:flutter/services.dart';

/// A directory/file entry returned by the native file browser.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  factory FileEntry.fromMap(Map<dynamic, dynamic> map) {
    return FileEntry(
      name: (map['name'] as String?) ?? '',
      path: (map['path'] as String?) ?? '',
      isDirectory: (map['isDirectory'] as bool?) ?? false,
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Wraps the native `dreamplayer/files` channel (see `FileBrowser.kt`).
class FileBrowserService {
  FileBrowserService._();

  static final FileBrowserService instance = FileBrowserService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/files');

  /// True when the app can freely read the whole filesystem
  /// (always true below Android 11).
  Future<bool> hasAllFilesAccess() async {
    final result = await _channel.invokeMethod<bool>('hasAllFilesAccess');
    return result ?? false;
  }

  /// Launches the system "All files access" settings page for this app.
  Future<void> openAllFilesAccessSettings() async {
    await _channel.invokeMethod<void>('openAllFilesAccessSettings');
  }

  /// Storage roots (internal storage, SD card) shown at the top level.
  Future<List<FileEntry>> storageRoots() async {
    final result = await _channel.invokeListMethod<dynamic>('getStorageRoots');
    if (result == null) return const [];
    return result
        .map((e) => FileEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Directories (first) and video files inside [path].
  Future<List<FileEntry>> listDirectory(String path) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'path': path,
    });
    if (result == null) return const [];
    return result
        .where((e) => (e as Map<dynamic, dynamic>)['error'] == null)
        .map((e) => FileEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }
}
