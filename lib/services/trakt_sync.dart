import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb_client.dart';
import 'trakt_client.dart';
import 'watched_store.dart';

/// Phase-1 Trakt sync: pulls watched state from Trakt into [WatchedStore]
/// for every file whose TMDB metadata is already resolved in [TmdStore].
///
/// One-way (mark-only): local marks are never cleared here — un-watching on
/// another device intentionally does not propagate until the full two-way
/// engine lands (roadmap phases 2–4). Failures are silent best-effort.
class TraktSync {
  TraktSync._();

  static const String _lastPullKey = 'dreamplayer.traktLastPullAt';

  /// Don't hit /sync/watched more than once per app-open window; Nova-style
  /// incremental scheduling comes with phase 4.
  static const Duration _minInterval = Duration(hours: 6);

  /// Fire-and-forget startup pull. Returns how many files were newly marked.
  static Future<int> pullWatched({bool force = false}) async {
    try {
      final client = TraktClient();
      if (!client.isConfigured || !await client.isAuthenticated()) return 0;
      if (!force && await _throttled()) return 0;
      final watched = await client.fetchWatched();
      return await applyWatched(watched);
    } catch (_) {
      return 0;
    }
  }

  /// Applies a fetched snapshot to [WatchedStore]. Returns count marked.
  static Future<int> applyWatched(TraktWatched watched) async {
    final cache = await TmdStore.loadAll();
    final keys = matchKeys(cache: cache, watched: watched);
    for (final key in keys) {
      await WatchedStore.set(key, true);
    }
    return keys.length;
  }

  /// Pure matcher (unit-tested): identity keys in [cache] whose TMDB id is
  /// watched on Trakt.
  ///
  /// Movies match exactly. Episodes parse `SxxEyy` from the filename tail of
  /// the identity key and match when the episode falls within the watched
  /// count Trakt reports for that season. Whole-season/folder keys (no S/E)
  /// and unresolved ids (id == 0) never match.
  @visibleForTesting
  static Set<String> matchKeys({
    required Map<String, TmdMeta> cache,
    required TraktWatched watched,
  }) {
    final result = <String>{};
    for (final entry in cache.entries) {
      final meta = entry.value;
      final id = meta.movie.id;
      if (id == 0) continue;
      if (meta.movie.kind == TmdKind.tv) {
        final base = entry.key.split('/').last.split(r'\').last;
        final parsed = ParsedFileName.parse(base);
        if (!parsed.isEpisode) continue;
        if (watched.isEpisodeWatched(id, parsed.season, parsed.episode)) {
          result.add(entry.key);
        }
      } else if (watched.movieIds.contains(id)) {
        result.add(entry.key);
      }
    }
    return result;
  }

  static Future<bool> _throttled() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastPullKey) ?? 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    if (elapsed < _minInterval.inMilliseconds) return true;
    await prefs.setInt(_lastPullKey, DateTime.now().millisecondsSinceEpoch);
    return false;
  }
}
