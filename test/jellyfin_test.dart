import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/jellyfin_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
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

    test('fromJson extracts IndexNumber/ParentIndexNumber for seasonLabel', () {
      final item = JellyfinItem.fromJson({
        'Id': 'e4',
        'Name': 'Chapter Four',
        'IsFolder': false,
        'Type': 'Episode',
        'MediaType': 'Video',
        'IndexNumber': 4,
        'ParentIndexNumber': 1,
      });
      expect(item.isPlayable, true);
      expect(item.indexNumber, 4);
      expect(item.parentIndexNumber, 1);
      expect(item.seasonLabel, 'S01E04');
    });

    test('seasonLabel is empty when numbers missing', () {
      const item = JellyfinItem(id: 'm1', name: 'Movie', mediaType: 'Video');
      expect(item.seasonLabel, '');
    });

    test('videoItem builds a playable VideoItem from the server + item', () {
      const server = JellyfinServer(
        name: 'Home',
        url: 'http://192.168.1.16:8096',
        token: 'tok123',
        userId: 'u1',
      );
      const item = JellyfinItem(
        id: 'item1',
        name: 'Show S01E01',
        mediaType: 'Video',
        runTimeTicks: 4200000000,
      );
      final video = JellyfinClient().videoItem(server, item);
      expect(video.title, 'Show S01E01');
      expect(video.uri, JellyfinClient().streamUrl(server, item));
      expect(video.resumeKey, 'jellyfin:192.168.1.16/item1');
      expect(video.jellyfinServerId, '192.168.1.16');
      expect(video.jellyfinItemId, 'item1');
      expect(video.duration, const Duration(seconds: 420));
      expect(video.playbackSource, PlaybackSource.jellyfin);
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

  group('JellyfinItemInfo', () {
    test('fromApi builds info with server image URLs', () {
      final info = JellyfinItemInfo.fromApi({
        'Id': 'ser1',
        'Name': 'Succession',
        'Type': 'Series',
        'Overview': 'A family drama.',
        'ProductionYear': 2018,
        'Genres': ['Drama'],
        'CommunityRating': 8.3,
        'RunTimeTicks': 36000000000,
        'ImageTags': {'Primary': 'p1'},
        'BackdropImageTags': ['b1'],
      }, serverUrl: 'http://192.168.1.16:8096', token: 'tok');
      expect(info.id, 'ser1');
      expect(info.name, 'Succession');
      expect(info.isTv, true);
      expect(info.kindLabel, 'TV Series');
      expect(info.year, 2018);
      expect(info.genres, ['Drama']);
      expect(info.communityRating, 8.3);
      expect(info.duration, const Duration(hours: 1));
      expect(info.durationLabel, '1:00h');
      expect(
        info.imageUrl,
        contains('/Items/ser1/Images/Primary?tag=p1&api_key=tok'),
      );
      expect(
        info.backdropUrl,
        contains('/Items/ser1/Images/Backdrop?tag=b1&api_key=tok'),
      );
    });

    test('fromApi handles missing artwork and movie type', () {
      final info = JellyfinItemInfo.fromApi({
        'Id': 'm1',
        'Name': 'Dune',
        'Type': 'Movie',
      }, serverUrl: 'http://x', token: 't');
      expect(info.imageUrl, isNull);
      expect(info.backdropUrl, isNull);
      expect(info.isMovie, true);
      expect(info.isTv, false);
      expect(info.kindLabel, 'Movie');
      expect(info.durationLabel, '');
    });

    test('toJson/fromJson round-trips cache fields', () {
      final info = JellyfinItemInfo.fromApi({
        'Id': 'ser1',
        'Name': 'Succession',
        'Type': 'Series',
        'Overview': 'A family drama.',
        'ProductionYear': 2018,
        'Genres': ['Drama'],
        'CommunityRating': 8.3,
        'RunTimeTicks': 36000000000,
        'ImageTags': {'Primary': 'p1'},
        'BackdropImageTags': ['b1'],
      }, serverUrl: 'http://192.168.1.16:8096', token: 'tok');
      final restored = JellyfinItemInfo.fromJson(info.toJson());
      expect(restored.id, info.id);
      expect(restored.name, info.name);
      expect(restored.type, info.type);
      expect(restored.overview, info.overview);
      expect(restored.year, info.year);
      expect(restored.genres, info.genres);
      expect(restored.communityRating, info.communityRating);
      expect(restored.runTimeTicks, info.runTimeTicks);
      expect(restored.imageUrl, info.imageUrl);
      expect(restored.backdropUrl, info.backdropUrl);
    });
  });

  group('Jellyfin folder-meta cache', () {
    const folderId = 'jellyfin_folder_192.168.1.16_ser1';
    final info = JellyfinItemInfo(
      id: 'ser1',
      name: 'Succession',
      type: 'Series',
      year: 2018,
      genres: const ['Drama'],
    );

    test('saveFolderMeta + loadAllFolderMeta round-trip', () async {
      final client = JellyfinClient();
      await client.saveFolderMeta(folderId, info);
      final all = await client.loadAllFolderMeta();
      expect(all.length, 1);
      expect(all[folderId]!.name, 'Succession');
      expect(all[folderId]!.year, 2018);
    });

    test('removeFolderMeta deletes the entry', () async {
      final client = JellyfinClient();
      await client.saveFolderMeta(folderId, info);
      await client.saveFolderMeta('other', info);
      await client.removeFolderMeta(folderId);
      final all = await client.loadAllFolderMeta();
      expect(all.keys, ['other']);
    });

    test('loadAllFolderMeta returns empty for corrupt json', () async {
      SharedPreferences.setMockInitialValues(
        {'dreamplayer.jellyfinFolderMeta': 'not json'},
      );
      expect(await JellyfinClient().loadAllFolderMeta(), isEmpty);
    });
  });
}
