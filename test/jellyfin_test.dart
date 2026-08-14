import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/jellyfin_client.dart';

void main() {
  group('PlaybackSource.jellyfin', () {
    test('resume key with jellyfin prefix maps to jellyfin source', () {
      const video = VideoItem(
        id: 'j1',
        title: 'Movie',
        uri: 'http://192.168.1.16:8096/Videos/abc/stream?api_key=x',
        resumeKey: 'jellyfin:192.168.1.16/abc',
        duration: Duration.zero,
      );
      expect(video.playbackSource, PlaybackSource.jellyfin);
      expect(PlaybackSource.jellyfin.label, 'Jellyfin');
    });

    test('network uri without jellyfin key stays network', () {
      const video = VideoItem(
        id: 'n1',
        title: 'Movie',
        uri: 'http://192.168.1.16:8096/Videos/abc/stream',
        duration: Duration.zero,
      );
      expect(video.playbackSource, PlaybackSource.network);
    });
  });

  group('JellyfinServer', () {
    test('toJson/fromJson round-trips persisted fields', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        username: 'admin',
        token: 'tok123',
        userId: 'u1',
        allowSelfSigned: true,
      );
      final restored = JellyfinServer.fromJson(server.toJson());
      expect(restored.name, 'Home');
      expect(restored.url, 'http://192.168.1.16:8096');
      expect(restored.username, 'admin');
      expect(restored.token, 'tok123');
      expect(restored.userId, 'u1');
      expect(restored.allowSelfSigned, true);
      expect(restored.isAuthenticated, true);
    });

    test('copyWith clears auth when token dropped', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok',
        userId: 'u1',
      );
      final expired = server.copyWith(token: null, userId: null);
      expect(expired.isAuthenticated, false);
    });
  });

  group('JellyfinClient URL helpers', () {
    test('normalizeUrl adds scheme and strips trailing slash', () {
      expect(JellyfinClient.normalizeUrl('192.168.1.16:8096'),
          'http://192.168.1.16:8096');
      expect(JellyfinClient.normalizeUrl('https://host:8920/'),
          'https://host:8920');
    });

    test('streamUrl embeds static + mediaSourceId + api_key', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok123',
        userId: 'u1',
      );
      const item = JellyfinItem(
        id: 'item1',
        name: 'Movie',
        mediaType: 'Video',
        mediaSourceId: 'source1',
      );
      final url = JellyfinClient().streamUrl(server, item);
      expect(url, contains('/Videos/item1/stream'));
      expect(url, contains('static=true'));
      expect(url, contains('mediaSourceId=source1'));
      expect(url, contains('api_key=tok123'));
    });

    test('resumeKey is host/item and stable across tokens', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok123',
        userId: 'u1',
      );
      const item = JellyfinItem(id: 'item1', name: 'Movie');
      expect(JellyfinClient().resumeKey(server, item), 'jellyfin:192.168.1.16/item1');
    });
  });

  group('JellyfinItem parsing', () {
    test('fromJson extracts MediaSources id and fields', () {
      final item = JellyfinItem.fromJson({
        'Id': 'abc',
        'Name': 'Show S01E01',
        'IsFolder': false,
        'Type': 'Episode',
        'MediaType': 'Video',
        'RunTimeTicks': 4200000000,
        'Width': 1920,
        'Height': 1080,
        'MediaSources': [
          {'Id': 'src1'},
        ],
      });
      expect(item.isPlayable, true);
      expect(item.mediaSourceId, 'src1');
      expect(item.duration, const Duration(seconds: 420));
      expect(item.resolution, '1920x1080');
    });

    test('folder items are not playable', () {
      final item = JellyfinItem.fromJson({
        'Id': 'lib',
        'Name': 'Movies',
        'IsFolder': true,
        'Type': 'CollectionFolder',
      });
      expect(item.isFolder, true);
      expect(item.isPlayable, false);
    });
  });
}
