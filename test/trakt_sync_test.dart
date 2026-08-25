import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:dream_player/services/trakt_client.dart';
import 'package:dream_player/services/trakt_sync.dart';

TmdMeta _meta(int id, TmdKind kind) => TmdMeta(
      movie: TmdMovie(id: id, title: 'T', kind: kind),
    );

void main() {
  test('movies match by exact TMDB id', () {
    final cache = {
      'file:///a.mkv': _meta(100, TmdKind.movie),
      'file:///b.mkv': _meta(200, TmdKind.movie),
      'file:///c.mkv': _meta(0, TmdKind.movie), // unresolved
    };
    final keys = TraktSync.matchKeys(
      cache: cache,
      watched: const TraktWatched(movieIds: {100}),
    );
    expect(keys, {'file:///a.mkv'});
  });

  test('episodes within the watched season count are marked', () {
    final cache = {
      // House S02E04 — Trakt reports season 2 count = 5 → watched.
      'smb_srv/Media/House/House.S02E04.mkv': _meta(500, TmdKind.tv),
      // S02E07 beyond the count → not watched.
      'smb_srv/Media/House/House.S02E07.mkv': _meta(500, TmdKind.tv),
      // Different show id → not marked.
      'smb_srv/Media/Other/Other.S02E04.mkv': _meta(600, TmdKind.tv),
      // Whole-season folder key has no SxxEyy → skipped.
      'folder:abc': _meta(500, TmdKind.tv),
    };
    const watched = TraktWatched(showSeasons: {
      500: {2: 5},
    });
    final keys = TraktSync.matchKeys(cache: cache, watched: watched);
    expect(keys, {'smb_srv/Media/House/House.S02E04.mkv'});
  });

  test('season not present means not watched', () {
    final cache = {
      'x/Show.S03E01.mkv': _meta(700, TmdKind.tv),
    };
    const watched = TraktWatched(showSeasons: {
      700: {1: 10},
    });
    expect(TraktSync.matchKeys(cache: cache, watched: watched), isEmpty);
  });

  test('isEpisodeWatched guards invalid inputs', () {
    const w = TraktWatched(showSeasons: {
      1: {1: 3},
    });
    expect(w.isEpisodeWatched(1, 1, 3), isTrue);
    expect(w.isEpisodeWatched(1, 1, 4), isFalse);
    expect(w.isEpisodeWatched(1, 1, 0), isFalse);
    expect(w.isEpisodeWatched(2, 1, 1), isFalse);
  });

  test('identity keys round-trip through VideoItem for matching', () {
    final video = VideoItem(
      id: '1',
      title: 'House S02E04',
      path: '/media/House.S02E04.mkv',
      duration: const Duration(minutes: 45),
      resumeKey: 'ftp_abc/media/House.S02E04.mkv',
    );
    expect(TmdStore.identityKeyFor(video), 'ftp_abc/media/House.S02E04.mkv');
    expect(
      TmdStore.identityKeyFor(video).split('/').last,
      'House.S02E04.mkv',
    );
  });
}
