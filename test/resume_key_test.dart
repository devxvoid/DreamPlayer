import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/services/file_browser.dart';
import 'package:dream_player/services/open_intent.dart';

void main() {
  group('OpenIntent resume key (CX Explorer SMB proxy)', () {
    test('loopback /SMB/ URL gets a stable key', () {
      final video = const OpenIntent(title: 'movie.mkv', uri: 'http://127.0.0.1:1978/SMB/server/share/movie.mkv').toVideoItem();
      expect(video.resumeKey, 'cx:/SMB/server/share/movie.mkv');
    });

    test('key is stable when the proxy port rotates', () {
      final v1 = const OpenIntent(title: 'movie.mkv', uri: 'http://127.0.0.1:1978/SMB/server/share/movie.mkv').toVideoItem();
      final v2 = const OpenIntent(title: 'movie.mkv', uri: 'http://127.0.0.1:31123/SMB/server/share/movie.mkv').toVideoItem();
      expect(v1.resumeKey, v2.resumeKey);
    });

    test('non-loopback / non-SMB URLs fall back to the raw URI', () {
      final video = const OpenIntent(title: 'movie.mkv', uri: 'http://192.168.1.16:8080/videos/movie.mkv').toVideoItem();
      expect(video.resumeKey, isNull);
      expect(video.uri, 'http://192.168.1.16:8080/videos/movie.mkv');
    });

    test('path-only intents keep a null resume key', () {
      final video = const OpenIntent(title: 'movie.mkv', path: '/sdcard/Movies/movie.mkv').toVideoItem();
      expect(video.resumeKey, isNull);
    });
  });

  group('FileEntry resume key (iOS bookmarked folders)', () {
    test('fromMap surfaces the native resumeKey', () {
      final entry = FileEntry.fromMap({
        'name': 'episode.mkv',
        'path': '/private/var/mobile/Library/MyShare/Season 1/episode.mkv',
        'isDirectory': false,
        'size': 12345,
        'resumeKey': 'folderbookmark:ABC-123/Season 1/episode.mkv',
      });
      expect(entry.resumeKey, 'folderbookmark:ABC-123/Season 1/episode.mkv');
    });

    test('entries without a resume key stay null', () {
      final entry = FileEntry.fromMap({
        'name': 'episode.mkv',
        'path': '/sdcard/Movies/episode.mkv',
        'isDirectory': false,
        'size': 12345,
      });
      expect(entry.resumeKey, isNull);
    });
  });
}
