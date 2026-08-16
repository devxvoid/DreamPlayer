import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'continue_watching.dart' show StoreChangeNotifier;

/// A folder the user explicitly chose to add to the library (e.g. a TV show
/// folder). Reference-only: videos are never imported — they stay in place and
/// are listed/played through the folder's SAF tree (`tree:<id>`) or absolute
/// path. This is the only thing the library shows: nothing is auto-scanned.
class LibraryFolder {
  const LibraryFolder({
    required this.id,
    required this.name,
    required this.path,
    required this.addedAt,
  });

  /// Bookmark id from the folder picker (`FileEntry.bookmarkId`).
  final String id;

  /// Display name of the folder (also the TMDB search query).
  final String name;

  /// `tree:<id>` for SAF bookmarks, or an absolute path.
  final String path;
  final DateTime addedAt;

  /// Stable identity for TMDB metadata (`folder:<id>` in TmdStore) — the
  /// `folder:` prefix keeps it clear of per-video identity keys.
  String get metadataKey => 'folder:$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'addedAtMs': addedAt.millisecondsSinceEpoch,
      };

  factory LibraryFolder.fromJson(Map<String, dynamic> json) {
    return LibraryFolder(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['addedAtMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// Persists the user's library folders (shared_preferences JSON), most recently
/// added first.
class LibraryFoldersStore {
  LibraryFoldersStore._();

  static const String _prefsKey = 'dreamplayer.libraryFolders';

  /// Fires whenever the folder list changes, so the home screen reloads.
  static final StoreChangeNotifier changes = StoreChangeNotifier();

  static Future<List<LibraryFolder>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <LibraryFolder>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> add(LibraryFolder folder) async {
    final all = await load();
    all.removeWhere((f) => f.id == folder.id);
    all.insert(0, folder);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    changes.notify();
  }

  static Future<void> remove(String id) async {
    final all = await load();
    all.removeWhere((f) => f.id == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((f) => f.toJson()).toList()),
    );
    changes.notify();
  }
}
