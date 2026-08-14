import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/tmdb_api_key.dart';
import '../models/video_item.dart';

/// What kind of title a matched file represents.
enum TmdKind { movie, tv }

/// A TMDB search hit (movie or series).
class TmdMovie {
  const TmdMovie({
    required this.id,
    required this.title,
    this.year,
    this.posterPath,
    this.backdropPath,
    this.overview = '',
    this.voteAverage = 0,
    this.kind = TmdKind.movie,
  });

  final int id;
  final String title;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final String overview;
  final double voteAverage;
  final TmdKind kind;

  String? posterUrl({int width = 342}) =>
      posterPath == null ? null : 'https://image.tmdb.org/t/p/w$width$posterPath';

  String? backdropUrl({int width = 780}) => backdropPath == null
      ? null
      : 'https://image.tmdb.org/t/p/w$width$backdropPath';

  String get yearLabel => year != null ? '$year' : '';

  factory TmdMovie.fromJson(Map<String, dynamic> json, {TmdKind kind = TmdKind.movie}) {
    final date = json[kind == TmdKind.movie ? 'release_date' : 'first_air_date'] as String?;
    final year = date != null && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
    return TmdMovie(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json[kind == TmdKind.movie ? 'title' : 'name'] as String?) ?? '',
      year: year,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: json['overview'] as String? ?? '',
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0,
      kind: kind,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'year': year,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'overview': overview,
        'voteAverage': voteAverage,
        'kind': kind.name,
      };

  factory TmdMovie.fromMetaJson(Map<String, dynamic> json) => TmdMovie(
        id: (json['id'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        year: json['year'] as int?,
        posterPath: json['posterPath'] as String?,
        backdropPath: json['backdropPath'] as String?,
        overview: json['overview'] as String? ?? '',
        voteAverage: (json['voteAverage'] as num?)?.toDouble() ?? 0,
        kind: json['kind'] == 'tv' ? TmdKind.tv : TmdKind.movie,
      );
}

class TmdCastMember {
  const TmdCastMember({required this.name, this.character, this.profilePath});

  final String name;
  final String? character;
  final String? profilePath;

  String? profileUrl({int width = 185}) =>
      profilePath == null ? null : 'https://image.tmdb.org/t/p/w$width$profilePath';
}

class TmdDetails {
  const TmdDetails({
    required this.title,
    this.tagline,
    this.overview = '',
    this.voteAverage = 0,
    this.voteCount = 0,
    this.year,
    this.runtimeMinutes,
    this.genres = const [],
    this.cast = const [],
    this.posterPath,
    this.backdropPath,
    this.originalTitle,
  });

  final String title;
  final String? tagline;
  final String overview;
  final double voteAverage;
  final int voteCount;
  final int? year;
  final int? runtimeMinutes;
  final List<String> genres;
  final List<TmdCastMember> cast;
  final String? posterPath;
  final String? backdropPath;
  final String? originalTitle;

  String get runtimeLabel =>
      runtimeMinutes == null ? '' : '${runtimeMinutes! ~/ 60}h ${runtimeMinutes! % 60}m';

  factory TmdDetails.fromJson(Map<String, dynamic> json, {TmdKind kind = TmdKind.movie}) {
    final date = json[kind == TmdKind.movie ? 'release_date' : 'first_air_date'] as String?;
    final year = date != null && date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
    final credits = json['credits'] as Map<String, dynamic>?;
    final castList = credits?['cast'] as List? ?? const [];
    return TmdDetails(
      title: (json[kind == TmdKind.movie ? 'title' : 'name'] as String?) ?? '',
      tagline: json['tagline'] as String?,
      overview: json['overview'] as String? ?? '',
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0,
      voteCount: (json['vote_count'] as num?)?.toInt() ?? 0,
      year: year,
      runtimeMinutes: _runtimeFromJson(json, kind),
      genres: (json['genres'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((g) => g['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      cast: castList
          .whereType<Map<String, dynamic>>()
          .take(12)
          .map(
            (c) => TmdCastMember(
              name: c['name'] as String? ?? '',
              character: c['character'] as String?,
              profilePath: c['profile_path'] as String?,
            ),
          )
          .where((c) => c.name.isNotEmpty)
          .toList(),
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      originalTitle: json[kind == TmdKind.movie ? 'original_title' : 'original_name'] as String?,
    );
  }

  static int? _runtimeFromJson(Map<String, dynamic> json, TmdKind kind) {
    if (kind == TmdKind.movie) return (json['runtime'] as num?)?.toInt();
    final runtimes = json['episode_run_time'] as List?;
    if (runtimes == null || runtimes.isEmpty) return null;
    return (runtimes.first as num).toInt();
  }
}

/// Result of matching a cleaned filename against TMDB search results.
class TmdMatch {
  const TmdMatch(this.movie, this.score);

  final TmdMovie movie;
  final double score;
}

/// Cached per-video metadata (what the card shows + optional full details).
class TmdMeta {
  const TmdMeta({required this.movie, this.details});

  final TmdMovie movie;
  final TmdDetails? details;

  TmdMeta withDetails(TmdDetails d) => TmdMeta(movie: movie, details: d);

  Map<String, dynamic> toJson() => {
        'movie': movie.toJson(),
        'details': details == null ? null : _detailsToJson(details!),
      };

  static Map<String, dynamic> _detailsToJson(TmdDetails d) => {
        'title': d.title,
        'tagline': d.tagline,
        'overview': d.overview,
        'voteAverage': d.voteAverage,
        'voteCount': d.voteCount,
        'year': d.year,
        'runtimeMinutes': d.runtimeMinutes,
        'genres': d.genres,
        'cast': d.cast
            .map(
              (c) => {'name': c.name, 'character': c.character, 'profilePath': c.profilePath},
            )
            .toList(),
        'posterPath': d.posterPath,
        'backdropPath': d.backdropPath,
        'originalTitle': d.originalTitle,
      };

  factory TmdMeta.fromJson(Map<String, dynamic> json) {
    final movieJson = json['movie'] as Map<String, dynamic>?;
    if (movieJson == null) {
      throw const FormatException('no movie in meta');
    }
    return TmdMeta(
      movie: TmdMovie.fromMetaJson(movieJson),
      details: _detailsFromJson(json['details'] as Map<String, dynamic>?),
    );
  }

  static TmdDetails? _detailsFromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return TmdDetails(
      title: json['title'] as String? ?? '',
      tagline: json['tagline'] as String?,
      overview: json['overview'] as String? ?? '',
      voteAverage: (json['voteAverage'] as num?)?.toDouble() ?? 0,
      voteCount: (json['voteCount'] as num?)?.toInt() ?? 0,
      year: json['year'] as int?,
      runtimeMinutes: json['runtimeMinutes'] as int?,
      genres: (json['genres'] as List? ?? const []).cast<String>(),
      cast: (json['cast'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (c) => TmdCastMember(
              name: c['name'] as String? ?? '',
              character: c['character'] as String?,
              profilePath: c['profilePath'] as String?,
            ),
          )
          .toList(),
      posterPath: json['posterPath'] as String?,
      backdropPath: json['backdropPath'] as String?,
      originalTitle: json['originalTitle'] as String?,
    );
  }
}

/// Parses a video filename into a searchable title + year.
class ParsedFileName {
  const ParsedFileName({
    required this.title,
    this.year,
    this.isEpisode = false,
    this.seriesName,
  });

  final String title;
  final int? year;
  final bool isEpisode;
  final String? seriesName;

  static final RegExp _yearPattern = RegExp(r'\b(18|19|20)\d{2}\b');
  static final RegExp _episodePattern = RegExp(r'\bS(\d{1,2})E(\d{1,2})\b', caseSensitive: false);
  static final RegExp _episodeShortPattern =
      RegExp(r'\b(\d{1,2})x(\d{1,3})\b', caseSensitive: false);

  static const List<String> _noise = [
    '1080p', '720p', '2160p', '480p', '4k', 'uhd', 'hd',
    'bluray', 'blu-ray', 'bdremux', 'remux', 'web-dl',     'webdl', 'webrip', 'web',
    'hdtv', 'dvdrip', 'h264', 'h265', 'x264', 'x265', 'hevc', 'avc', 'av1', 'vp9',
    'aac', 'ac3', 'eac3', 'dts', 'dts-hd', 'truehd', 'atmos', 'flac', 'opus', 'mp3',
    'ddp', '5.1', '7.1', '2.0', '10bit', '8bit', 'hdr', 'hdr10', 'hdr10plus', 'dolby',
    'vision', 'dv', 'hdr10+', 'multi', 'proper', 'repack', 'internal', 'extended',
    'unrated', 'directors', 'cut', 'imax', 'complete',
  ];

  static ParsedFileName parse(String fileName) {
    var name = fileName.trim();
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      final ext = name.substring(dot + 1).toLowerCase();
      if (ext.length <= 4) name = name.substring(0, dot);
    }

    // Release-group suffix is conventionally attached with a dash
    // (e.g. `...x265-GROUP`). Drop everything from the last dash on.
    final dash = name.lastIndexOf('-');
    if (dash > 0) name = name.substring(0, dash);

    final episodeMatch = _episodePattern.firstMatch(name);
    final shortEpisodeMatch = _episodeShortPattern.firstMatch(name);

    final yearMatch = _yearPattern.firstMatch(name);
    int? year;
    if (yearMatch != null) {
      year = int.parse(yearMatch.group(0)!);
      name = name.replaceAll(yearMatch.group(0)!, ' ');
    }

    var isEpisode = false;
    String? seriesName;
    if (episodeMatch != null) {
      isEpisode = true;
      seriesName = name.substring(0, episodeMatch.start).trim();
      name = name.replaceAll(episodeMatch.group(0)!, ' ');
    } else if (shortEpisodeMatch != null) {
      isEpisode = true;
      seriesName = name.substring(0, shortEpisodeMatch.start).trim();
      name = name.replaceAll(shortEpisodeMatch.group(0)!, ' ');
    }

    final title = _cleanName(name);
    return ParsedFileName(
      title: title.isEmpty ? (seriesName ?? _fallbackTitle(fileName)) : title,
      year: year,
      isEpisode: isEpisode,
      seriesName: seriesName == null ? null : _cleanName(seriesName),
    );
  }

  static String _cleanName(String raw) {
    var cleaned = raw;
    // Codec tags glued to their channel layout (e.g. `DDP5.1`, `AC3.5.1`).
    cleaned = cleaned.replaceAll(
      RegExp(r'\b[a-z]{2,}\d+\.\d+\b', caseSensitive: false),
      ' ',
    );
    for (final n in _noise) {
      cleaned = cleaned.replaceAll(RegExp('\\b${RegExp.escape(n)}\\b', caseSensitive: false), ' ');
    }
    cleaned = cleaned.replaceAll(RegExp(r'[._\-\u2013\u2014\[\](){}]'), ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _fallbackTitle(String fileName) {
    final cleaned = fileName.replaceAll(RegExp(r'[._\-\u2013\u2014\[\](){}]'), ' ');
    final parts = cleaned.split(' ').where((w) => w.isNotEmpty).take(6);
    return parts.join(' ');
  }
}

/// Talks to The Movie Database (TMDB) v3 API over `dart:io` HttpClient.
class TmdApi {
  TmdApi({this._apiKey});

  final String? _apiKey;
  static const String _baseUrl = 'https://api.themoviedb.org/3';

  static const String prefsKey = 'dreamplayer.tmdbApiKey';

  /// One shared, keep-alive client for the whole app lifetime. A fresh
  /// `HttpClient` per request re-arms DNS + TLS each time and churns sockets,
  /// which on a flaky Wi-Fi/mobile link is slow and surfaces as intermittent
  /// `SocketException`s. Pooling the connection avoids that and speeds up
  /// bursts (home screen pre-resolves continue-watching cards in parallel).
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// Effective key: the one entered in Settings wins; otherwise the
  /// compile-time default (`--dart-define=TMDB_API_KEY=...` or the key in
  /// `lib/config/tmdb_api_key.dart`). The build-time default is seeded into
  /// prefs on first use so the app keeps working on later `flutter run`s that
  /// omit the define.
  Future<String> effectiveApiKey() async {
    if (_apiKey != null && _apiKey.isNotEmpty) return _apiKey;
    final prefs = await SharedPreferences.getInstance();
    var saved = prefs.getString(prefsKey);
    if ((saved == null || saved.isEmpty) && tmdbDefaultApiKey.isNotEmpty) {
      await prefs.setString(prefsKey, tmdbDefaultApiKey);
      saved = tmdbDefaultApiKey;
    }
    if (saved != null && saved.isNotEmpty) return saved;
    return '';
  }

  Future<List<TmdMovie>> search(String query, {int? year, TmdKind kind = TmdKind.movie}) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return const [];
    final endpoint = kind == TmdKind.movie ? '/search/movie' : '/search/tv';
    final params = <String, String>{
      'api_key': key,
      'query': query,
      'language': 'en-US',
      'include_adult': 'false',
      if (year != null) 'year': '$year',
    };
    final json = await _get('$endpoint?${_query(params)}');
    final results = json['results'] as List? ?? const [];
    return results
        .whereType<Map<String, dynamic>>()
        .map((r) => TmdMovie.fromJson(r, kind: kind))
        .where((m) => m.id != 0)
        .toList();
  }

  Future<TmdDetails> details(TmdMovie movie) async {
    final key = await effectiveApiKey();
    final endpoint = movie.kind == TmdKind.movie ? '/movie/${movie.id}' : '/tv/${movie.id}';
    final json = await _get('$endpoint?api_key=$key&language=en-US&append_to_response=credits');
    return TmdDetails.fromJson(json, kind: movie.kind);
  }

  Future<TmdMatch?> bestMatch(ParsedFileName parsed) async {
    final key = await effectiveApiKey();
    if (key.isEmpty) return null;
    final kind = parsed.isEpisode ? TmdKind.tv : TmdKind.movie;
    final results = await search(
      parsed.isEpisode ? (parsed.seriesName ?? parsed.title) : parsed.title,
      year: kind == TmdKind.movie ? parsed.year : null,
      kind: kind,
    );
    if (results.isEmpty) return null;
    results.sort((a, b) => _score(b, parsed).compareTo(_score(a, parsed)));
    final best = results.first;
    final score = _score(best, parsed);
    if (score < 0.5) return null;
    return TmdMatch(best, score);
  }

  double _score(TmdMovie movie, ParsedFileName parsed) {
    final query = (parsed.isEpisode ? (parsed.seriesName ?? parsed.title) : parsed.title)
        .toLowerCase();
    final title = movie.title.toLowerCase();
    var score = 0.0;
    if (title == query) {
      score = 1.0;
    } else if (title.startsWith(query) || query.startsWith(title)) {
      score = 0.85;
    } else {
      final common = _commonWords(query, title);
      final ratio = title.isNotEmpty ? common / title.split(' ').length : 0;
      score = 0.6 * ratio.clamp(0.0, 1.0);
    }
    if (parsed.year != null && movie.year == parsed.year && !parsed.isEpisode) {
      score = (score + 0.15).clamp(0.0, 1.0);
    }
    return score;
  }

  static int _commonWords(String a, String b) {
    final words = b.split(' ');
    return words.where((w) => a.contains(w)).length;
  }

  Future<Map<String, dynamic>> _get(String pathAndQuery) async {
    final uri = Uri.parse('$_baseUrl$pathAndQuery');
    // Retry once for transient failures (flaky network, dropped keep-alive
    // socket, per-second rate-limit burst). Hard errors (bad key, bad payload)
    // fail immediately with their specific message.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      try {
        final request =
            await _client.getUrl(uri).timeout(const Duration(seconds: 15));
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response =
            await request.close().timeout(const Duration(seconds: 30));
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode != 200) {
          // 429 is a rate-limit burst — retry once before surfacing it.
          if (response.statusCode == 429 && attempt == 0) continue;
          throw TmdException(_friendlyStatus(response.statusCode));
        }
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          throw const TmdException('Unexpected TMDB response.');
        }
        return decoded;
      } on TmdException {
        rethrow;
      } on SocketException {
        // Fall through to the retry (or the final error below).
      } on TimeoutException {
        // Fall through to the retry (or the final error below).
      }
    }
    throw const TmdException("Can't reach TMDB — check your connection.");
  }

  static String _friendlyStatus(int code) {
    switch (code) {
      case 401:
        return 'TMDB API key is invalid.';
      case 429:
        return 'TMDB rate limit reached — try again shortly.';
      default:
        return 'TMDB returned an error ($code).';
    }
  }

  static String _query(Map<String, String> params) =>
      params.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
}

class TmdException implements Exception {
  const TmdException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Caches [TmdMeta] per video identity (resumeKey ?? path ?? uri) in
/// shared_preferences and mirrors the in-memory map so the UI can rebuild when
/// metadata arrives.
class TmdStore {
  TmdStore._();

  static const String _prefsKey = 'dreamplayer.tmdbMeta';

  static final StoreNotifier changes = StoreNotifier();

  static String identityKeyFor(VideoItem video) =>
      video.resumeKey ?? video.path ?? video.uri ?? '';

  static Future<Map<String, TmdMeta>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final result = <String, TmdMeta>{};
      for (final entry in json.entries) {
        try {
          result[entry.key] =
              TmdMeta.fromJson((entry.value as Map).cast<String, dynamic>());
        } catch (_) {}
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String identityKey, TmdMeta meta) async {
    if (identityKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    all[identityKey] = meta;
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
    );
    changes.notify();
  }

  static Future<void> remove(String identityKey) async {
    if (identityKey.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    if (all.remove(identityKey) != null) {
      await prefs.setString(
        _prefsKey,
        jsonEncode(all.map((k, v) => MapEntry(k, v.toJson()))),
      );
      changes.notify();
    }
  }
}

/// Exposes [ChangeNotifier.notifyListeners] publicly so [TmdStore]'s static
/// methods can announce changes without tripping the `@protected` lint.
class StoreNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// App-wide facade: resolves filenames to TMDB metadata, serves cached results
/// to the UI, and notifies listeners when a resolution lands.
class TmdService extends ChangeNotifier {
  TmdService._();

  static final TmdService instance = TmdService._();

  final TmdApi _api = TmdApi();
  Map<String, TmdMeta> _cache = {};
  final Set<String> _pending = {};
  bool _loaded = false;

  bool get loaded => _loaded;

  TmdMeta? metaFor(String identityKey) => _cache[identityKey];

  bool isResolving(String identityKey) => _pending.contains(identityKey);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _cache = await TmdStore.loadAll();
    _loaded = true;
    notifyListeners();
  }

  /// Returns cached metadata, or resolves it from TMDB (search + match) and
  /// caches it. Returns null when there's no key configured or no match found.
  Future<TmdMeta?> resolve(VideoItem video) async {
    final identityKey = TmdStore.identityKeyFor(video);
    if (identityKey.isEmpty) return null;
    await ensureLoaded();
    final cached = _cache[identityKey];
    if (cached != null) return cached;
    if (_pending.contains(identityKey)) return null;

    final parsed = ParsedFileName.parse(video.title);
    if (parsed.title.isEmpty) return null;

    _pending.add(identityKey);
    try {
      final match = await _api.bestMatch(parsed);
      if (match == null) return null;
      final meta = TmdMeta(movie: match.movie);
      _cache[identityKey] = meta;
      await TmdStore.save(identityKey, meta);
      return meta;
    } finally {
      _pending.remove(identityKey);
      notifyListeners();
    }
  }

  /// Fetches full details (synopsis, cast, runtime) for a matched video.
  Future<TmdDetails?> detailsFor(String identityKey) async {
    final meta = _cache[identityKey];
    if (meta == null) return null;
    if (meta.details != null) return meta.details;
    try {
      final details = await _api.details(meta.movie);
      _cache[identityKey] = meta.withDetails(details);
      await TmdStore.save(identityKey, _cache[identityKey]!);
      notifyListeners();
      return details;
    } catch (_) {
      return null;
    }
  }

  /// Manual fix: pins an explicitly chosen title for the video.
  Future<void> setManual(VideoItem video, TmdMovie movie) async {
    final identityKey = TmdStore.identityKeyFor(video);
    if (identityKey.isEmpty) return;
    _cache[identityKey] = TmdMeta(movie: movie);
    await TmdStore.save(identityKey, _cache[identityKey]!);
    notifyListeners();
  }

  Future<void> clear(String identityKey) async {
    _cache.remove(identityKey);
    await TmdStore.remove(identityKey);
    notifyListeners();
  }
}
