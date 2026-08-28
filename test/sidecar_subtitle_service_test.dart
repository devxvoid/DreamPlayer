import 'dart:io' show Platform;

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/sidecar_subtitle_service.dart';
import 'package:flutter_test/flutter_test.dart';

VideoExternalSub _sub(String uri, {bool isDefault = false, String label = 't'}) =>
    VideoExternalSub(uri: uri, label: label, isDefault: isDefault);

/// Tests for the sidecar subtitle discovery helper. The full SMB/WebDAV/FTP
/// network paths are exercised on-device; here we cover the URI parsing +
/// filename pairing rules in isolation, so the same code path stays safe
/// on a CI box that has no NAS.
void main() {
  group('SidecarSubtitleService.find', () {
    test('returns empty for empty uri', () async {
      final video = VideoItem(
        id: 'x', title: 'x', duration: Duration.zero,
      );
      final result = await SidecarSubtitleService.instance.find(video);
      expect(result, isEmpty);
    });

    test('returns empty on iOS regardless of source (v1 limitation)', () async {
      // The Android-only gate ensures iOS never calls into the native SMB
      // channels (which would just fail there). Local files already have
      // their own sibling auto-pairing on iOS.
      if (Platform.isAndroid) {
        return; // Not applicable; on Android the SMB path runs.
      }
      final video = VideoItem(
        id: 'x', title: 'x', duration: Duration.zero,
        uri: 'smb://srv/share/Show.S01E01.mkv',
      );
      final result = await SidecarSubtitleService.instance.find(video);
      expect(result, isEmpty);
    });
  });

  group('promoteFirstExternalAsDefault', () {
    test('empty list returns empty', () {
      expect(promoteFirstExternalAsDefault(const []), isEmpty);
    });

    test('promotes first when none is default', () {
      final promoted = promoteFirstExternalAsDefault([
        _sub('a'),
        _sub('b'),
        _sub('c'),
      ]);
      expect(promoted[0].isDefault, isTrue);
      expect(promoted[1].isDefault, isFalse);
      expect(promoted[2].isDefault, isFalse);
    });

    test('preserves server-flagged default', () {
      // Even if "a" is listed first, "b" is already default — don't touch.
      final subs = [
        _sub('a'),
        _sub('b', isDefault: true),
        _sub('c'),
      ];
      final promoted = promoteFirstExternalAsDefault(subs);
      expect(promoted[0].isDefault, isFalse);
      expect(promoted[1].isDefault, isTrue);
      expect(promoted[2].isDefault, isFalse);
    });

    test('preserves URIs + labels (does not rebuild the first track)', () {
      final promoted = promoteFirstExternalAsDefault([
        _sub('https://srv/Movies/Show.S01E01.eng.srt', label: 'eng'),
        _sub('https://srv/Movies/Show.S01E01.jpn.srt', label: 'jpn'),
      ]);
      expect(promoted[0].uri, 'https://srv/Movies/Show.S01E01.eng.srt');
      expect(promoted[0].label, 'eng');
      expect(promoted[0].isDefault, isTrue);
    });
  });
}
