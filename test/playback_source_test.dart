import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/video_item.dart';

VideoItem item({
  String? path,
  String? uri,
  String? resumeKey,
}) =>
    VideoItem(
      id: 'id',
      title: 'movie.mkv',
      path: path,
      uri: uri,
      resumeKey: resumeKey,
      duration: Duration.zero,
    );

void main() {
  group('VideoItem.playbackSource', () {
    test('webdav_ resume key → WebDAV', () {
      expect(
        item(uri: 'https://192.168.1.16:8443/dav/movie.mkv',
            resumeKey: 'webdav_abc/movie.mkv').playbackSource,
        PlaybackSource.webdav,
      );
    });

    test('cx: resume key → CX SMB (Android handoff)', () {
      expect(
        item(uri: 'http://127.0.0.1:1978/SMB/server/share/movie.mkv',
            resumeKey: 'cx:/SMB/server/share/movie.mkv').playbackSource,
        PlaybackSource.cxSmb,
      );
    });

    test('folderbookmark: resume key → Files / SMB (iOS picked folder)', () {
      expect(
        item(resumeKey: 'folderbookmark:ABC-123/Season 1/movie.mkv')
            .playbackSource,
        PlaybackSource.filesSmb,
      );
    });

    test('smb: resume key → legacy in-app SMB', () {
      expect(
        item(uri: 'dreamplayersmb://token.mkv', resumeKey: 'smb:server/share')
            .playbackSource,
        PlaybackSource.smb,
      );
    });

    test('content:// URI → Files (Open with / bookmarked tree)', () {
      expect(
        item(uri: 'content://media/external/video/media/123').playbackSource,
        PlaybackSource.files,
      );
    });

    test('file:// URI → Files', () {
      expect(
        item(uri: 'file:///sdcard/Movies/movie.mkv').playbackSource,
        PlaybackSource.files,
      );
    });

    test('plain device path → Files', () {
      expect(item(path: '/sdcard/Movies/movie.mkv').playbackSource,
          PlaybackSource.files);
    });

    test('other http(s) URL → Network', () {
      expect(
        item(uri: 'http://192.168.1.16:8080/videos/movie.mkv').playbackSource,
        PlaybackSource.network,
      );
    });

    test('nothing identifiable → null', () {
      expect(item().playbackSource, isNull);
    });

    test('survives a Continue watching round-trip (toJson/fromJson)', () {
      final saved = item(
        uri: 'https://192.168.1.16:8443/dav/movie.mkv',
        resumeKey: 'webdav_abc/movie.mkv',
      );
      final restored = VideoItem.fromJson(saved.toJson());
      expect(restored.playbackSource, PlaybackSource.webdav);
    });
  });
}
