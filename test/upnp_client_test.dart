import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/upnp_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpnpEntry', () {
    test('parses transcoded flag from native map', () {
      final e = UpnpEntry.fromMap({
        'name': 'House.S02E04.mkv',
        'id': 'abc',
        'isDirectory': false,
        'url': 'http://192.168.1.16:8096/dlna/videos/f74c/stream.ts?x=1',
        'size': 1549738688,
        'transcoded': true,
      });
      expect(e.transcoded, isTrue);
      expect(e.isVideo, isTrue);
    });

    test('defaults transcoded to false when absent', () {
      final e = UpnpEntry.fromMap({
        'name': 'direct.mkv',
        'id': 'def',
        'isDirectory': false,
        'url': 'http://host/stream.mkv',
      });
      expect(e.transcoded, isFalse);
    });
  });

  group('VideoItem.isTranscoded', () {
    test('round-trips through JSON', () {
      const v = VideoItem(
        duration: Duration.zero,
        id: 'k',
        title: 't',
        uri: 'http://h/master.m3u8',
        isTranscoded: true,
      );
      final back = VideoItem.fromJson(v.toJson());
      expect(back.isTranscoded, isTrue);

      const plain = VideoItem(id: 'k2', title: 't2', duration: Duration.zero);
      expect(plain.isTranscoded, isFalse);
      expect(
        VideoItem.fromJson(plain.toJson()).isTranscoded,
        isFalse,
      );
    });
  });
}
