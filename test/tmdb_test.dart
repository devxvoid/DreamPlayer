import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/tmdb_client.dart';

void main() {
  group('ParsedFileName', () {
    test('parses a movie title and year from a scene filename', () {
      final parsed = ParsedFileName.parse(
        'The.Great.Movie.2015.1080p.BluRay.x265-GROUP.mkv',
      );
      expect(parsed.title, 'The Great Movie');
      expect(parsed.year, 2015);
      expect(parsed.isEpisode, isFalse);
      expect(parsed.seriesName, isNull);
    });

    test('strips release group, quality, and codec noise', () {
      final parsed = ParsedFileName.parse(
        'Inception.2010.2160p.UHD.HDR10.DV.WEB-DL.DDP5.1.Atmos.HEVC.mkv',
      );
      expect(parsed.title, 'Inception');
      expect(parsed.year, 2010);
    });

    test('detects a TV episode and keeps the series name', () {
      final parsed = ParsedFileName.parse('Breaking.Bad.S01E03.720p.WEB-DL.mkv');
      expect(parsed.isEpisode, isTrue);
      expect(parsed.seriesName, 'Breaking Bad');
      expect(parsed.title, 'Breaking Bad');
    });

    test('detects season-episode with underscores and brackets', () {
      final parsed = ParsedFileName.parse('Stranger_Things_[S02E04]_1080p.mp4');
      expect(parsed.isEpisode, isTrue);
      expect(parsed.seriesName, 'Stranger Things');
    });

    test('year is null when the filename has no year', () {
      final parsed = ParsedFileName.parse('Some.Movie.1080p.WEBRip.mp4');
      expect(parsed.year, isNull);
      expect(parsed.title, 'Some Movie');
    });

    test('falls back to the raw name for a single-word file', () {
      final parsed = ParsedFileName.parse('Trailer.mp4');
      expect(parsed.title, 'Trailer');
    });
  });

  group('TmdStore', () {
    test('round-trips TmdMeta through SharedPreferences JSON', () async {
      SharedPreferences.setMockInitialValues({});
      final meta = TmdMeta(
        movie: const TmdMovie(
          id: 603,
          title: 'The Matrix',
          year: 1999,
          posterPath: '/poster.jpg',
          backdropPath: '/backdrop.jpg',
          overview: 'A computer hacker learns the truth.',
          voteAverage: 8.2,
        ),
        details: const TmdDetails(
          title: 'The Matrix',
          overview: 'A computer hacker learns the truth.',
          voteAverage: 8.2,
          voteCount: 23000,
          year: 1999,
          runtimeMinutes: 136,
          genres: ['Action', 'Sci-Fi'],
          cast: [
            TmdCastMember(name: 'Keanu Reeves', character: 'Neo'),
          ],
        ),
      );
      await TmdStore.save('the-matrix-1999', meta);

      final loaded = await TmdStore.loadAll();
      final restored = loaded['the-matrix-1999'];
      expect(restored, isNotNull);
      expect(restored!.movie.id, 603);
      expect(restored.movie.title, 'The Matrix');
      expect(restored.movie.year, 1999);
      expect(restored.movie.posterUrl(), isNotNull);
      expect(restored.details, isNotNull);
      expect(restored.details!.runtimeMinutes, 136);
      expect(restored.details!.cast.single.name, 'Keanu Reeves');
      expect(restored.details!.cast.single.character, 'Neo');
    });

    test('image URLs are absolute and default to w342 for posters', () {
      const movie = TmdMovie(
        id: 1,
        title: 'X',
        posterPath: '/p.jpg',
        backdropPath: '/b.jpg',
      );
      expect(movie.posterUrl(), 'https://image.tmdb.org/t/p/w342/p.jpg');
      expect(movie.posterUrl(width: 780), 'https://image.tmdb.org/t/p/w780/p.jpg');
      expect(
        movie.backdropUrl(),
        'https://image.tmdb.org/t/p/w780/b.jpg',
      );
    });
  });

  group('TmdApi effective key', () {
    test('returns the key stored in prefs when the default is empty', () async {
      SharedPreferences.setMockInitialValues({});
      final api = TmdApi();
      expect(await api.effectiveApiKey(), isEmpty);
      SharedPreferences.setMockInitialValues({TmdApi.prefsKey: 'abc123'});
      expect(await api.effectiveApiKey(), 'abc123');
    });
  });

  group('TmdMeta JSON', () {
    test('serializes and deserializes nested details', () {
      final meta = TmdMeta(
        movie: const TmdMovie(
          id: 11,
          title: 'Dune: Part Two',
          year: 2024,
          voteAverage: 8.1,
        ),
        details: const TmdDetails(
          title: 'Dune: Part Two',
          year: 2024,
          runtimeMinutes: 166,
          genres: ['Sci-Fi'],
        ),
      );
      final roundTripped = TmdMeta.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      expect(roundTripped.movie.id, 11);
      expect(roundTripped.details!.runtimeMinutes, 166);
    });
  });
}
