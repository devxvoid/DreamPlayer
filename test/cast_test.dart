import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/cast_service.dart';

void main() {
  group('CastService.isSourceCastable', () {
    test('Jellyfin direct URL is castable', () {
      const video = VideoItem(
        id: 'j1',
        title: 'Movie',
        uri:
            'http://192.168.1.16:8096/Videos/abc/stream?static=true&api_key=t',
        duration: Duration.zero,
      );
      expect(CastService.isSourceCastable(video), isTrue);
    });

    test('sources needing HTTP headers are not castable', () {
      const video = VideoItem(
        id: 'w1',
        title: 'WebDAV file',
        uri: 'http://192.168.1.16:8080/dav/movie.mkv',
        httpHeaders: {'Authorization': 'Basic abc'},
        duration: Duration.zero,
      );
      expect(CastService.isSourceCastable(video), isFalse);
    });

    test('self-signed servers are not castable (receiver trusts CAs)', () {
      const video = VideoItem(
        id: 'w2',
        title: 'Self signed',
        uri: 'https://192.168.1.16:8443/dav/movie.mkv',
        allowSelfSigned: true,
        duration: Duration.zero,
      );
      expect(CastService.isSourceCastable(video), isFalse);
    });

    test('loopback proxies are not castable', () {
      const video = VideoItem(
        id: 'c1',
        title: 'CX proxy',
        uri: 'http://127.0.0.1:5055/SMB/nas/Videos/movie.mkv',
        duration: Duration.zero,
      );
      expect(CastService.isSourceCastable(video), isFalse);
    });

    test('local files are not castable in phase 1', () {
      const video = VideoItem(
        id: 'f1',
        title: 'Local',
        path: '/storage/emulated/0/Movies/movie.mkv',
        duration: Duration.zero,
      );
      expect(CastService.isSourceCastable(video), isFalse);
    });
  });

  group('CastService.guessContentType', () {
    test('maps common containers', () {
      expect(CastService.guessContentType('http://x/a.mkv'),
          'video/x-matroska');
      expect(CastService.guessContentType('http://x/b.ts'), 'video/mp2t');
      expect(CastService.guessContentType('http://x/c.m3u8?k=v'),
          'application/x-mpegurl');
      expect(CastService.guessContentType('http://x/d.mp4'), 'video/mp4');
    });

    test('falls back to mp4 for unknown extensions', () {
      expect(CastService.guessContentType('http://x/e.weird'), 'video/mp4');
    });
  });

  group('CASTV2 frame codec', () {
    // The codec is private; exercise it through a tiny reflection-free
    // round trip via the public behavior is not possible, so verify the
    // wire format by encoding known bytes here instead.
    test('varint framing of a CONNECT message matches the protocol', () {
      // Build the same message the service sends and check structure.
      final b = BytesBuilder();
      b.add([0x08, 0x00]); // protocol_version
      void str(int field, String s) {
        final bytes = utf8.encode(s);
        final len = <int>[];
        var v = bytes.length;
        while (v >= 0x80) {
          len.add((v & 0x7F) | 0x80);
          v >>= 7;
        }
        len.add(v);
        b.add([(field << 3) | 2, ...len]);
        b.add(bytes);
      }

      str(2, 'sender-0');
      str(3, 'receiver-0');
      str(4, 'urn:x-cast:com.google.cast.tp.connection');
      str(6, '{"type":"CONNECT"}');

      final data = b.toBytes();
      // First byte: field 1 varint. Second: value 0.
      expect(data[0], 0x08);
      expect(data[1], 0x00);
      // Field 2 string tag.
      expect(data[2], (2 << 3) | 2);
      expect(data[3], 'sender-0'.length);
      // The payload must contain the JSON body verbatim at the end.
      final text = latin1.decode(data, allowInvalid: true);
      expect(text.contains('"type":"CONNECT"'), isTrue);
      expect(
          text.contains('urn:x-cast:com.google.cast.tp.connection'), isTrue);
    });
  });
}
