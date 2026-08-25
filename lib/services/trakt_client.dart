import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/trakt_keys.dart';

/// A single item to mark watched / add to history on Trakt.
class TraktWatchItem {
  const TraktWatchItem({
    required this.tmdbId,
    required this.isTv,
    this.season,
    this.episode,
    this.watchedAt,
  });

  final int tmdbId;
  final bool isTv;

  /// Season/episode for TV items (null for movies).
  final int? season;
  final int? episode;

  /// When the item was watched; defaults to now.
  final DateTime? watchedAt;

  Map<String, dynamic> toJson() {
    final at = (watchedAt ?? DateTime.now()).toUtc().toIso8601String();
    if (isTv) {
      return {
        'ids': {'tmdb': tmdbId},
        'seasons': [
          {
            'number': season ?? 0,
            'episodes': [
              {'number': episode ?? 0, 'watched_at': at},
            ],
          },
        ],
      };
    }
    return {
      'ids': {'tmdb': tmdbId},
      'watched_at': at,
    };
  }
}

/// A device-code response from Trakt's OAuth device flow, shown to the user so
/// they can authorize the app at https://trakt.tv/activate.
class TraktDeviceCode {
  const TraktDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;
}

class TraktException implements Exception {
  const TraktException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Trakt.tv sync client (OAuth device flow + watched/history sync).
///
/// Pure Dart over `dart:io` HttpClient, mirroring the Jellyfin client pattern.
/// The access token is a session credential (like Jellyfin's) and is stored in
/// shared_preferences under `dreamplayer.trakt`; it is refreshed automatically
/// on 401.
/// Watched state pulled from Trakt. Movies are a flat id set; TV shows
/// report per-season watched episode *counts* (Trakt semantics: the first N
/// episodes of a season are watched), not per-episode flags.
class TraktWatched {
  const TraktWatched({
    this.movieIds = const {},
    this.showSeasons = const {},
  });

  final Set<int> movieIds;

  /// tmdbShowId -> (seasonNumber -> watched episode count)
  final Map<int, Map<int, int>> showSeasons;

  bool isEpisodeWatched(int showId, int season, int episode) {
    final seasons = showSeasons[showId];
    if (seasons == null) return false;
    final count = seasons[season];
    return count != null && episode > 0 && episode <= count;
  }
}

class TraktClient {
  TraktClient([this._prefs]);

  static const String _prefsKey = 'dreamplayer.trakt';
  static const String _baseUrl = 'https://api.trakt.tv';

  final SharedPreferences? _prefs;
  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> get _sharedPrefs async =>
      _cachedPrefs ??= _prefs ?? await SharedPreferences.getInstance();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  bool get isConfigured => traktClientId.isNotEmpty && traktClientSecret.isNotEmpty;

  // MARK: - Persistence

  Future<Map<String, dynamic>> _load() async {
    final prefs = await _sharedPrefs;
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, dynamic> data) async {
    final prefs = await _sharedPrefs;
    await prefs.setString(_prefsKey, jsonEncode(data));
  }

  Future<String?> _accessToken() async {
    final data = await _load();
    return data['accessToken'] as String?;
  }

  Future<bool> isAuthenticated() async {
    if (!isConfigured) return false;
    final data = await _load();
    final token = data['accessToken'] as String?;
    if (token == null || token.isEmpty) return false;
    final expiresAt = (data['expiresAt'] as num?)?.toInt() ?? 0;
    if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch > expiresAt) {
      // Expired — try a refresh; if that fails, treat as signed out.
      return await _refreshToken() != null;
    }
    return true;
  }

  Future<DateTime?> lastSyncAt() async {
    final data = await _load();
    final ms = (data['lastSyncAt'] as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> signOut() async {
    final prefs = await _sharedPrefs;
    await prefs.remove(_prefsKey);
  }

  // MARK: - OAuth device flow

  /// Starts the device flow: returns the user code + verification URL for the
  /// UI to display, then polls in the background until the user authorizes.
  /// Resolves `true` on success (token persisted), `false` if the user never
  /// authorized before expiry, and throws [TraktException] on error.
  Future<TraktDeviceCode> requestDeviceCode() async {
    if (!isConfigured) {
      throw const TraktException('Trakt is not configured (missing client id).');
    }
    final body = await _post(
      '/oauth/device/code',
      body: {'client_id': traktClientId},
      auth: false,
    );
    return TraktDeviceCode(
      deviceCode: body['device_code'] as String? ?? '',
      userCode: body['user_code'] as String? ?? '',
      verificationUrl: body['verification_url'] as String? ?? 'https://trakt.tv/activate',
      expiresIn: (body['expires_in'] as num?)?.toInt() ?? 600,
      interval: (body['interval'] as num?)?.toInt() ?? 5,
    );
  }

  /// Polls the token endpoint until the user authorizes (or the code expires).
  /// Returns true once authenticated.
  Future<bool> pollForToken(TraktDeviceCode code) async {
    final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: code.interval));
      try {
        final body = await _post(
          '/oauth/device/token',
          body: {
            'code': code.deviceCode,
            'client_id': traktClientId,
            'client_secret': traktClientSecret,
          },
          auth: false,
        );
        await _persistToken(body);
        return true;
      } on TraktException catch (e) {
        // 400 = still pending; 429 = slow down; anything else is fatal.
        if (e.message == 'pending') continue;
        if (e.message == 'slow_down') continue;
        rethrow;
      }
    }
    return false;
  }

  Future<void> _persistToken(Map<String, dynamic> body) async {
    final accessToken = body['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const TraktException('No access token returned.');
    }
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 0;
    final data = await _load();
    data['accessToken'] = accessToken;
    data['refreshToken'] = body['refresh_token'] as String?;
    data['expiresAt'] = expiresIn > 0
        ? DateTime.now().millisecondsSinceEpoch + expiresIn * 1000
        : 0;
    await _save(data);
  }

  Future<String?> _refreshToken() async {
    final data = await _load();
    final refresh = data['refreshToken'] as String?;
    if (refresh == null || refresh.isEmpty) return null;
    try {
      final body = await _post(
        '/oauth/token',
        body: {
          'refresh_token': refresh,
          'client_id': traktClientId,
          'client_secret': traktClientSecret,
          'grant_type': 'refresh_token',
        },
        auth: false,
      );
      await _persistToken(body);
      return body['access_token'] as String?;
    } catch (_) {
      return null;
    }
  }

  // MARK: - Sync

  /// Marks [items] watched on Trakt (`/sync/watched`).
  Future<void> syncWatched(List<TraktWatchItem> items) async {
    if (items.isEmpty) return;
    final movies = <Map<String, dynamic>>[];
    final shows = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item.isTv) {
        shows.add({
          'ids': {'tmdb': item.tmdbId},
          'seasons': [
            {
              'number': item.season ?? 0,
              'episodes': [
                {
                  'number': item.episode ?? 0,
                  'watched_at':
                      (item.watchedAt ?? DateTime.now()).toUtc().toIso8601String(),
                },
              ],
            },
          ],
        });
      } else {
        movies.add({
          'ids': {'tmdb': item.tmdbId},
          'watched_at': (item.watchedAt ?? DateTime.now()).toUtc().toIso8601String(),
        });
      }
    }
    final body = <String, dynamic>{
      if (movies.isNotEmpty) 'movies': movies,
      if (shows.isNotEmpty) 'shows': shows,
    };
    await _post('/sync/watched', body: body, auth: true);
    await _markSynced();
  }

  /// Adds [items] to Trakt history (`/sync/history`).
  Future<void> addToHistory(List<TraktWatchItem> items) async {
    if (items.isEmpty) return;
    final movies = <Map<String, dynamic>>[];
    final shows = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item.isTv) {
        shows.add({
          'ids': {'tmdb': item.tmdbId},
          'seasons': [
            {
              'number': item.season ?? 0,
              'episodes': [
                {
                  'number': item.episode ?? 0,
                  'watched_at':
                      (item.watchedAt ?? DateTime.now()).toUtc().toIso8601String(),
                },
              ],
            },
          ],
        });
      } else {
        movies.add({
          'ids': {'tmdb': item.tmdbId},
          'watched_at': (item.watchedAt ?? DateTime.now()).toUtc().toIso8601String(),
        });
      }
    }
    final body = <String, dynamic>{
      if (movies.isNotEmpty) 'movies': movies,
      if (shows.isNotEmpty) 'shows': shows,
    };
    await _post('/sync/history', body: body, auth: true);
  }

  /// Convenience for a single item (used by the player's watched hook).
  Future<void> addToHistoryOne(TraktWatchItem item) =>
      addToHistory([item]);

  /// Returns the TMDB ids the user has watched on Trakt (movies + shows).
  Future<Set<int>> getWatchedTmdbIds() async {
    final result = <int>{};
    final movies = await _get('/sync/watched/movies', auth: true);
    for (final m in (movies as List? ?? const [])) {
      final movie = m as Map<String, dynamic>;
      final ids = movie['movie']?['ids'] as Map<String, dynamic>?;
      final tmdb = (ids?['tmdb'] as num?)?.toInt();
      if (tmdb != null) result.add(tmdb);
    }
    final shows = await _get('/sync/watched/shows', auth: true);
    for (final s in (shows as List? ?? const [])) {
      final show = s as Map<String, dynamic>;
      final ids = show['show']?['ids'] as Map<String, dynamic>?;
      final tmdb = (ids?['tmdb'] as num?)?.toInt();
      if (tmdb != null) result.add(tmdb);
    }
    return result;
  }

  /// Full watched snapshot with TV season granularity (see [TraktWatched]).
  Future<TraktWatched> fetchWatched() async {
    final movieIds = <int>{};
    final movies = await _get('/sync/watched/movies', auth: true);
    for (final m in (movies as List? ?? const [])) {
      final ids = (m as Map<String, dynamic>)['movie']?['ids'] as Map<String, dynamic>?;
      final tmdb = (ids?['tmdb'] as num?)?.toInt();
      if (tmdb != null) movieIds.add(tmdb);
    }
    final showSeasons = <int, Map<int, int>>{};
    final shows = await _get('/sync/watched/shows', auth: true);
    for (final s in (shows as List? ?? const [])) {
      final show = s as Map<String, dynamic>;
      final ids = show['show']?['ids'] as Map<String, dynamic>?;
      final tmdb = (ids?['tmdb'] as num?)?.toInt();
      if (tmdb == null) continue;
      final seasons = <int, int>{};
      for (final sn in (show['seasons'] as List? ?? const [])) {
        final data = sn as Map<String, dynamic>;
        final number = (data['number'] as num?)?.toInt();
        final episodes = (data['episodes'] as num?)?.toInt() ?? 0;
        if (number != null) seasons[number] = episodes;
      }
      showSeasons[tmdb] = seasons;
    }
    return TraktWatched(movieIds: movieIds, showSeasons: showSeasons);
  }

  Future<void> _markSynced() async {
    final data = await _load();
    data['lastSyncAt'] = DateTime.now().millisecondsSinceEpoch;
    await _save(data);
  }

  // MARK: - HTTP

  Future<dynamic> _get(String path, {required bool auth}) async {
    final token = auth ? await _accessToken() : null;
    if (auth && (token == null || token.isEmpty)) {
      throw const TraktException('Not signed in to Trakt.');
    }
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('trakt-api-version', '2');
      req.headers.set('trakt-api-key', traktClientId);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 && auth) {
        // Try a refresh once, then retry.
        final newToken = await _refreshToken();
        if (newToken != null) {
          return await _get(path, auth: true);
        }
        throw const TraktException('Trakt session expired — sign in again.');
      }
      if (res.statusCode >= 400) {
        throw TraktException(_friendlyStatus(res.statusCode));
      }
      if (body.isEmpty) return const [];
      return jsonDecode(body);
    } on TraktException {
      rethrow;
    } on SocketException {
      throw const TraktException("Can't reach Trakt — check your connection.");
    } on TimeoutException {
      throw const TraktException('Trakt request timed out.');
    } on FormatException {
      throw const TraktException('Trakt returned an unexpected response.');
    }
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    required Map<String, dynamic> body,
    required bool auth,
  }) async {
    final token = auth ? await _accessToken() : null;
    if (auth && (token == null || token.isEmpty)) {
      throw const TraktException('Not signed in to Trakt.');
    }
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final req = await _client.postUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.contentType = ContentType.json;
      req.headers.set('trakt-api-version', '2');
      req.headers.set('trakt-api-key', traktClientId);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 && auth) {
        final newToken = await _refreshToken();
        if (newToken != null) {
          return await _post(path, body: body, auth: true);
        }
        throw const TraktException('Trakt session expired — sign in again.');
      }
      if (res.statusCode == 400 && !auth) {
        // Device flow: 400 means the user hasn't authorized yet.
        throw const TraktException('pending');
      }
      if (res.statusCode == 429) {
        throw const TraktException('slow_down');
      }
      if (res.statusCode >= 400) {
        throw TraktException(_friendlyStatus(res.statusCode));
      }
      if (text.isEmpty) return const {};
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    } on TraktException {
      rethrow;
    } on SocketException {
      throw const TraktException("Can't reach Trakt — check your connection.");
    } on TimeoutException {
      throw const TraktException('Trakt request timed out.');
    } on FormatException {
      throw const TraktException('Trakt returned an unexpected response.');
    }
  }

  static String _friendlyStatus(int code) {
    switch (code) {
      case 401:
        return 'Trakt authorization failed.';
      case 403:
        return 'Trakt access denied.';
      case 404:
        return 'Trakt resource not found.';
      case 429:
        return 'Trakt rate limit reached — try again shortly.';
      default:
        return 'Trakt returned an error ($code).';
    }
  }
}
