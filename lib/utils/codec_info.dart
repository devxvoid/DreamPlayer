import '../models/hdr_format.dart';

HdrFormat detectHdrFormat(String? hint) {
  if (hint == null || hint.isEmpty) return HdrFormat.sdr;
  final raw = hint.toLowerCase().replaceAll(RegExp(r'[\s\-_.]+'), '');
  if (raw.contains('dolby') ||
      raw.contains('dovi') ||
      raw.contains('dv') ||
      raw.contains('profile5') ||
      raw.contains('profile7') ||
      raw.contains('profile8')) {
    return HdrFormat.dolbyVision;
  }
  if (raw.contains('hdr10+') || raw.contains('hdr10plus')) {
    return HdrFormat.hdr10plus;
  }
  if (raw.contains('hdr')) return HdrFormat.hdr10;
  return HdrFormat.sdr;
}

String formatAudioCodec(String? codec) {
  if (codec == null || codec.isEmpty) return 'Unknown';
  final c = codec.toLowerCase();
  const map = {
    'eac3': 'E-AC3',
    'ec3': 'E-AC3',
    'ac3': 'AC-3',
    'dts': 'DTS',
    'dtshd': 'DTS-HD',
    'dts_hd': 'DTS-HD',
    'dtsx': 'DTS:X',
    'dts_x': 'DTS:X',
    'truehd': 'TrueHD',
    'mlp': 'TrueHD',
    'aac': 'AAC',
    'flac': 'FLAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'mp3': 'MP3',
    'libmp3lame': 'MP3',
    'pcm_s16le': 'PCM',
    'pcm_s24le': 'PCM 24-bit',
    'pcm_f32le': 'PCM 32-bit float',
  };
  return map[c] ?? codec.toUpperCase();
}

String formatVideoCodec(String? codec) {
  if (codec == null || codec.isEmpty) return 'Unknown';
  final c = codec.toLowerCase();
  const map = {
    'h264': 'H.264',
    'avc1': 'H.264',
    'hevc': 'HEVC',
    'h265': 'HEVC',
    'hvc1': 'HEVC',
    'av01': 'AV1',
    'av1': 'AV1',
    'vp9': 'VP9',
    'mpeg2video': 'MPEG-2',
    'mpeg4': 'MPEG-4',
    'vc1': 'VC-1',
    'mjpeg': 'MJPEG',
  };
  return map[c] ?? codec.toUpperCase();
}
