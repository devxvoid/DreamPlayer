import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/models/hdr_format.dart';
import 'package:dream_player/utils/codec_info.dart';

void main() {
  group('detectHdrFormat', () {
    test('null hint is SDR', () {
      expect(detectHdrFormat(null), HdrFormat.sdr);
      expect(detectHdrFormat(''), HdrFormat.sdr);
    });

    test('detects Dolby Vision variants', () {
      expect(detectHdrFormat('DV P8'), HdrFormat.dolbyVision);
      expect(detectHdrFormat('DV P5'), HdrFormat.dolbyVision);
      expect(detectHdrFormat('Dolby Vision'), HdrFormat.dolbyVision);
      expect(detectHdrFormat('dovi'), HdrFormat.dolbyVision);
    });

    test('detects HDR10+', () {
      expect(detectHdrFormat('HDR10+'), HdrFormat.hdr10plus);
      expect(detectHdrFormat('HDR10 Plus'), HdrFormat.hdr10plus);
    });

    test('detects HDR10', () {
      expect(detectHdrFormat('HDR10'), HdrFormat.hdr10);
      expect(detectHdrFormat('HDR'), HdrFormat.hdr10);
    });

    test('SDR hint stays SDR', () {
      expect(detectHdrFormat('SDR'), HdrFormat.sdr);
    });
  });

  group('formatAudioCodec', () {
    test('maps common codecs to display labels', () {
      expect(formatAudioCodec('eac3'), 'E-AC3');
      expect(formatAudioCodec('ac3'), 'AC-3');
      expect(formatAudioCodec('dts'), 'DTS');
      expect(formatAudioCodec('dts_hd'), 'DTS-HD');
      expect(formatAudioCodec('truehd'), 'TrueHD');
      expect(formatAudioCodec('aac'), 'AAC');
      expect(formatAudioCodec('flac'), 'FLAC');
    });

    test('falls back to uppercase for unknown codecs', () {
      expect(formatAudioCodec('mp4a'), 'MP4A');
      expect(formatAudioCodec(null), 'Unknown');
    });
  });

  group('formatVideoCodec', () {
    test('maps common video codecs', () {
      expect(formatVideoCodec('h264'), 'H.264');
      expect(formatVideoCodec('hevc'), 'HEVC');
      expect(formatVideoCodec('av1'), 'AV1');
      expect(formatVideoCodec('vp9'), 'VP9');
    });
  });
}
