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

/// Live HDR detection from the active video track codec (`dvhe`/`dvh1`/`dvav`)
/// and the transfer function / color space reported by the player.
///
/// Dolby Vision is best signaled by the codec (`dvhe`/`dvh1`/`dvav`);
/// otherwise the transfer function decides HDR10 vs HLG.
HdrFormat detectLiveHdrFormat({String? videoCodec, String? gamma}) {
  final codec = (videoCodec ?? '').toLowerCase();
  if (codec.startsWith('dv')) return HdrFormat.dolbyVision;
  final transfer = (gamma ?? '').toLowerCase();
  if (transfer.contains('smpte2084') || transfer.contains('pq')) {
    return HdrFormat.hdr10;
  }
  if (transfer.contains('arib-std-b67') || transfer.contains('hlg')) {
    return HdrFormat.hlg;
  }
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
  // Codec strings from Media3/containers carry a profile suffix
  // (e.g. `dvhe.08.06`, `hvc1.2.4.L153.B0`); match on the leading token.
  final primary = c.split(RegExp(r'[.\s/]')).first;
  const map = {
    'h264': 'H.264',
    'avc1': 'H.264',
    'hevc': 'HEVC',
    'h265': 'HEVC',
    'hvc1': 'HEVC',
    'hev1': 'HEVC',
    'dvhe': 'Dolby Vision',
    'dvh1': 'Dolby Vision',
    'dvav': 'Dolby Vision',
    'av01': 'AV1',
    'av1': 'AV1',
    'vp9': 'VP9',
    'vp09': 'VP9',
    'mpeg2video': 'MPEG-2',
    'mpeg4': 'MPEG-4',
    'mp4v': 'MPEG-4',
    'vc1': 'VC-1',
    'mjpeg': 'MJPEG',
  };
  return map[primary] ?? c.toUpperCase();
}

/// Maps a Media3 audio MIME type + codecs string pair to a display label.
///
/// Media3 reports lossless/HD formats via MIME (`audio/vnd.dts.hd`,
/// `audio/vnd.dolby.truehd`, ...) while the codecs string is often generic
/// (`dts`, `mlp`); the MIME is authoritative when present.
String formatMedia3Audio(String? mime, String? codecs) {
  final m = (mime ?? '').toLowerCase();
  final c = (codecs ?? '').toLowerCase();
  const mimeMap = {
    'audio/vnd.dts': 'DTS',
    'audio/vnd.dts.hd': 'DTS-HD',
    'audio/eac3': 'E-AC3',
    'audio/eac3-joc': 'E-AC3',
    'audio/ac3': 'AC-3',
    'audio/vnd.dolby.truehd': 'TrueHD',
    'audio/mp4a-latm': 'AAC',
    'audio/aac': 'AAC',
    'audio/flac': 'FLAC',
    'audio/opus': 'Opus',
    'audio/vorbis': 'Vorbis',
    'audio/mpeg': 'MP3',
    'audio/raw': 'PCM',
    'audio/alac': 'ALAC',
  };
  final fromMime = mimeMap[m];
  if (fromMime != null) return fromMime;

  final primary = c.split(RegExp(r'[.\s/]')).first;
  const codecMap = {
    'dts': 'DTS',
    'dts-hd': 'DTS-HD',
    'dtsx': 'DTS:X',
    'mlp': 'TrueHD',
    'truehd': 'TrueHD',
    'ac-3': 'AC-3',
    'ec-3': 'E-AC3',
    'aac': 'AAC',
    'mp4a': 'AAC',
    'flac': 'FLAC',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'mp3': 'MP3',
  };
  final fromCodecs = codecMap[primary];
  if (fromCodecs != null) return fromCodecs;

  if (m.isNotEmpty) return m.toUpperCase();
  if (c.isNotEmpty) return c.toUpperCase();
  return 'Unknown';
}

/// Live HDR detection from Media3 track info.
///
/// Dolby Vision is signaled by the codec prefix (`dvhe`/`dvh1`); otherwise the
/// color transfer function decides HDR10 (ST2084/PQ) vs HLG. Media3's
/// `Format.colorInfo.colorTransfer` uses the Android `MediaFormat` constants
/// (ST2084 = 6, HLG = 7).
HdrFormat detectMedia3HdrFormat({int? colorTransfer, String? videoCodecs}) {
  final codec = (videoCodecs ?? '').toLowerCase();
  if (codec.startsWith('dv')) return HdrFormat.dolbyVision;
  switch (colorTransfer) {
    case 6:
      return HdrFormat.hdr10;
    case 7:
      return HdrFormat.hlg;
    default:
      return HdrFormat.sdr;
  }
}

/// Formats an audio codec + decoder pair from the playback engine.
///
/// The engine may report DTS-HD tracks as codec `dts`; the HD variant shows
/// up in the decoder description (e.g. `dts (dts_hd)`). Same trick is needed
/// to distinguish lossless formats reported generically.
String formatLiveAudioCodec(String? codec, String? decoder) {
  if (codec == null || codec.isEmpty) return 'Unknown';
  final c = codec.toLowerCase();
  final dec = (decoder ?? '').toLowerCase();
  if (c == 'dts' &&
      (dec.contains('dts_hd') ||
          dec.contains('dts-hd') ||
          dec.contains('dts_mast') ||
          dec.contains('truehd'))) {
    return 'DTS-HD';
  }
  if (c == 'truehd' && dec.contains('mlp')) return 'TrueHD';
  return formatAudioCodec(codec);
}

/// Converts a channel count to a display label (e.g. `6` -> `5.1`).
String channelsLabel(int? channels) {
  if (channels == null || channels <= 0) return '?';
  switch (channels) {
    case 1:
      return 'Mono';
    case 2:
      return '2.0';
    case 6:
      return '5.1';
    case 8:
      return '7.1';
    default:
      return '$channels.0';
  }
}

/// Builds the audio chip label combining the live codec (from the playback
/// engine) with any richer profile from the library metadata.
///
/// The engine reports DTS-HD / TrueHD Atmos generically (e.g. `dts`,
/// `truehd`); the HD / Atmos distinction only lives in the metadata probe.
/// When the codec families match, prefer the metadata profile, then append
/// the live channel count.
String formatLiveAudioLabel({
  required String? liveCodec,
  String? liveDecoder,
  required int? liveChannels,
  String? metaCodec,
  String? metaProfile,
}) {
  final base = formatLiveAudioCodec(liveCodec, liveDecoder);
  if (base == 'Unknown') return 'Unknown';
  var label = base;
  if (metaProfile != null && metaProfile.isNotEmpty) {
    final metaBase = formatAudioCodec(metaCodec)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final liveBase = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (metaBase.isNotEmpty &&
        liveBase.isNotEmpty &&
        (metaBase.contains(liveBase) || liveBase.contains(metaBase))) {
      label = '${formatAudioCodec(metaCodec)} $metaProfile';
    }
  }
  if (liveChannels != null && liveChannels > 0) {
    label = '$label ${channelsLabel(liveChannels)}';
  }
  return label;
}
