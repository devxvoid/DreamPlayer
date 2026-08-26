import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DownloadedSubtitle {
  const DownloadedSubtitle({
    required this.fileName,
    required this.path,
    required this.language,
    this.downloadedAtMs,
  });

  final String fileName;
  final String path; // persistent path in app support
  final String language;
  final int? downloadedAtMs;

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'path': path,
        'language': language,
        if (downloadedAtMs != null) 'downloadedAtMs': downloadedAtMs,
      };

  factory DownloadedSubtitle.fromJson(Map<String, dynamic> j) => DownloadedSubtitle(
        fileName: j['fileName'] as String? ?? '',
        path: j['path'] as String? ?? '',
        language: j['language'] as String? ?? 'en',
        downloadedAtMs: j['downloadedAtMs'] as int?,
      );
}

/// Per-video persisted list keyed by `VideoItem.resumeKey` (or id fallback).
/// Stored under `dreamplayer.downloadedSubs` as JSON map `resumeKey` -> List.
class DownloadedSubtitlesStore {
  static const _prefsKey = 'dreamplayer.downloadedSubs';

  /// Save a downloaded file persistently and record it.
  static Future<DownloadedSubtitle> saveForVideo({
    required String resumeKey,
    required String tempPath,
    required String fileName,
    required String language,
  }) async {
    final src = File(tempPath);
    final support = await getApplicationSupportDirectory();
    final safeKey = resumeKey.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final dir = Directory('${support.path}/opensubs/$safeKey');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safeName = fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final destPath = '${dir.path}/$safeName';
    try {
      if (await src.exists()) {
        await src.copy(destPath);
      }
    } catch (_) {}
    final entry = DownloadedSubtitle(
      fileName: fileName,
      path: destPath,
      language: language,
      downloadedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final map = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final list = (map[resumeKey] as List?) ?? [];
    // Deduplicate by fileName (replace existing)
    final existing = List<Map<String, dynamic>>.from(list.map((e) => Map<String, dynamic>.from(e as Map)));
    existing.removeWhere((e) => e['fileName'] == fileName);
    existing.insert(0, entry.toJson());
    // Keep at most 10 per video
    if (existing.length > 10) existing.removeRange(10, existing.length);
    map[resumeKey] = existing;
    await prefs.setString(_prefsKey, jsonEncode(map));
    return entry;
  }

  static Future<List<DownloadedSubtitle>> loadForVideo(String resumeKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = map[resumeKey] as List?;
      if (list == null) return const [];
      final out = <DownloadedSubtitle>[];
      for (final e in list) {
        final d = DownloadedSubtitle.fromJson(Map<String, dynamic>.from(e as Map));
        // Filter out entries whose file was deleted
        if (await File(d.path).exists()) out.add(d);
      }
      // Prune stale entries
      if (out.length != list.length) {
        map[resumeKey] = out.map((e) => e.toJson()).toList();
        await prefs.setString(_prefsKey, jsonEncode(map));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> removeForVideo(String resumeKey, String path) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = map[resumeKey] as List?;
      if (list == null) return;
      list.removeWhere((e) => (e as Map)['path'] == path);
      if (list.isEmpty) {
        map.remove(resumeKey);
      } else {
        map[resumeKey] = list;
      }
      await prefs.setString(_prefsKey, jsonEncode(map));
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    } catch (_) {}
  }

  /// Delete temp `opensubs` files older than 7 days and any orphaned support files.
  static Future<void> cleanStaleTemp() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}/opensubs');
      if (!await dir.exists()) return;
      final now = DateTime.now();
      await for (final e in dir.list()) {
        try {
          final stat = await e.stat();
          if (now.difference(stat.modified).inDays >= 7) await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
