import '../utils/codec_info.dart';
import 'hdr_format.dart';

/// Where a video came from, derived from the source-specific [VideoItem]
/// identifiers so the UI can show where playback is served from.
enum PlaybackSource {
  webdav('WebDAV'),
  cxSmb('CX SMB'),
  filesSmb('Files / SMB'),
  smb('SMB'),
  files('Files'),
  network('Network');

  const PlaybackSource(this.label);

  final String label;
}

class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    this.path,
    this.uri,
    this.resumeKey,
    required this.duration,
    this.sizeBytes,
    this.resolution,
    this.videoCodec,
    this.hdrHint,
    this.audioCodec,
    this.audioProfile,
    this.audioChannels,
    this.subtitleUri,
    this.httpHeaders = const {},
    this.allowSelfSigned = false,
  });

  final String id;
  final String title;

  /// Absolute file path, or `null` when only a URI is available.
  final String? path;

  /// e.g. a `content://` URI handed over from an "Open with" intent.
  final String? uri;

  /// HTTP request headers to send when loading [uri] (e.g. WebDAV Basic auth).
  /// Only applied for HTTP(S) sources.
  final Map<String, String> httpHeaders;

  /// Trusts any certificate for this source (self-signed WebDAV servers).
  final bool allowSelfSigned;

  /// Stable identifier for the resume feature, for sources whose [path]/[uri]
  /// rotate between sessions (e.g. iPad SMB per-file token URLs). Falls back to
  /// [path] then [uri] when null.
  final String? resumeKey;

  /// Sideloaded subtitle source: a URI of a paired `.srt`/`.ass` file sitting
  /// next to the video in the same folder.
  final String? subtitleUri;
  final Duration duration;
  final int? sizeBytes;
  final String? resolution;
  final String? videoCodec;
  final String? hdrHint;
  final String? audioCodec;
  final String? audioProfile;
  final String? audioChannels;

  HdrFormat get hdrFormat => detectHdrFormat(hdrHint);

  String get hdrLabel => hdrFormat.label;

  /// Best-effort origin of this video, derived from the source-specific
  /// [resumeKey]/[uri]/[path] identifiers:
  /// - `webdav_…` → WebDAV server
  /// - `cx:…` → CX Explorer SMB handoff (Android "Open with")
  /// - `folderbookmark:…` → iOS picked folder (Files app / NAS share)
  /// - `smb:…` → legacy in-app SMB
  /// - `content://` → Android "Open with"/bookmarked-tree URI
  /// - `file://` / plain path → on-device file
  /// - other http(s) URL → generic network source
  PlaybackSource? get playbackSource {
    final key = resumeKey;
    if (key != null) {
      if (key.startsWith('webdav_')) return PlaybackSource.webdav;
      if (key.startsWith('cx:')) return PlaybackSource.cxSmb;
      if (key.startsWith('folderbookmark:')) return PlaybackSource.filesSmb;
      if (key.startsWith('smb:')) return PlaybackSource.smb;
    }
    final u = uri;
    if (u != null) {
      final lower = u.toLowerCase();
      if (lower.startsWith('content://')) return PlaybackSource.files;
      if (lower.startsWith('file://')) return PlaybackSource.files;
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        return PlaybackSource.network;
      }
    }
    if (path != null && path!.isNotEmpty) return PlaybackSource.files;
    return null;
  }

  /// Returns a copy with [duration] replaced. The duration often isn't known
  /// until playback starts (e.g. WebDAV URLs), but the Continue watching card
  /// needs it to draw a progress bar.
  VideoItem withPlaybackInfo({required Duration duration}) {
    return VideoItem(
      id: id,
      title: title,
      path: path,
      uri: uri,
      resumeKey: resumeKey,
      duration: duration,
      sizeBytes: sizeBytes,
      resolution: resolution,
      videoCodec: videoCodec,
      hdrHint: hdrHint,
      audioCodec: audioCodec,
      audioProfile: audioProfile,
      audioChannels: audioChannels,
      subtitleUri: subtitleUri,
      httpHeaders: httpHeaders,
      allowSelfSigned: allowSelfSigned,
    );
  }

  String? get videoCodecLabel {
    final label = formatVideoCodec(videoCodec);
    return label == 'Unknown' ? null : label;
  }

  String? get audioCodecLabel {
    if (audioCodec == null) return null;
    final parts = <String>[formatAudioCodec(audioCodec)];
    if (audioProfile != null && audioProfile!.isNotEmpty) {
      parts.add(audioProfile!);
    }
    if (audioChannels != null && audioChannels!.isNotEmpty) {
      parts.add(audioChannels!);
    }
    return parts.join(' ');
  }

  String get durationLabel {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'uri': uri,
        'resumeKey': resumeKey,
        'durationMs': duration.inMilliseconds,
        'sizeBytes': sizeBytes,
      };

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    return VideoItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      path: json['path'] as String?,
      uri: json['uri'] as String?,
      resumeKey: json['resumeKey'] as String?,
      duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
    );
  }
}
