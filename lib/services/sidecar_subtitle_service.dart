import 'dart:async';
import 'dart:io' show Platform;

import '../models/video_item.dart';
import 'ftp_client.dart';
import 'smb_client.dart';
import 'webdav_client.dart';

/// Auto-discovers sidecar subtitle files for a video that lives on a
/// network share. Mirrors the local-filesystem pairing rule used by
/// `SubtitleFormats.findSiblingSubtitles` (Android) / `siblingSubtitles(for:)`
/// (iOS), but for SMB / WebDAV / FTP sources where the player can't just
/// `listFiles()` the parent directory itself.
///
/// **Priority: external sidecar → server external → embedded**.
/// The first sidecar matched is marked `isDefault = true`; the rest are
/// selectable from the player CC sheet. If no sidecar matches, the function
/// returns an empty list and the player falls back to the container's
/// embedded subtitle track (or whatever the server already sent via
/// `externalSubtitles`).
class SidecarSubtitleService {
  SidecarSubtitleService._();
  static final SidecarSubtitleService instance = SidecarSubtitleService._();

  /// Subtitle extensions the engines can decode natively. The list matches
  /// the iOS `subtitleExtensions` set in `AvPlayerView.swift` and the
  /// `SubtitleFormats.SUBTITLE_EXTENSIONS` set in `SubtitleFormats.kt`.
  static const _extensions = {
    'srt', 'ass', 'ssa', 'vtt', 'webvtt', 'ttml', 'dfxp', 'xml',
    'sub', 'smi', 'mpl2',
  };

  /// MIME type per extension. Matches `SubtitleFormats.mimeTypeFor()`.
  static const _mimeTypes = <String, String>{
    'srt': 'application/x-subrip',
    'ass': 'text/x-ssa',
    'ssa': 'text/x-ssa',
    'vtt': 'text/vtt',
    'webvtt': 'text/vtt',
    'ttml': 'application/ttml+xml',
    'dfxp': 'application/ttml+xml',
    'xml': 'application/ttml+xml',
    'sub': 'application/x-microdvd',
    'smi': 'application/x-sami',
    'mpl2': 'application/x-mpl2',
  };

  /// Looks up the sidecar subtitle files for [video], based on its source
  /// URI scheme:
  /// - `smb://<serverId>/<share>/<path>` → SMB list of the parent folder.
  /// - `http(s)://<serverId>@…/<path>` or `https://…` with WebDAV headers
  ///   on the VideoItem → WebDAV PROPFIND of the parent folder.
  /// - `ftp://` or `sftp://` → FTP LIST of the parent folder.
  ///
  /// **Android only for v1**: iOS WebDAV playback uses a custom
  /// `WebDAVByteRangeSource` that doesn't know how to authenticate a sidecar
  /// URL built from the server base alone (it would 401), and iOS SMB was
  /// retired in 2026-08. Local-file sibling discovery on iOS already works
  /// via the `ExternalSubtitleTrack` path in `AvPlayerView.swift`.
  ///
  /// Best-effort: returns `[]` on any failure (network blip, auth error,
  /// listing unsupported by the server, etc.). Never throws.
  Future<List<VideoExternalSub>> find(VideoItem video) async {
    if (!Platform.isAndroid) return const [];
    final uri = video.uri;
    if (uri == null || uri.isEmpty) return const [];
    try {
      if (uri.startsWith('smb://')) {
        return await _findSmb(uri);
      }
      if (uri.startsWith('http://') || uri.startsWith('https://')) {
        return await _findWebDavOrHttp(uri, video);
      }
      if (uri.startsWith('ftp://') || uri.startsWith('sftp://')) {
        return await _findFtp(uri);
      }
    } catch (_) {
      // Sidecar discovery is best-effort: never block playback.
    }
    return const [];
  }

  Future<List<VideoExternalSub>> _findSmb(String uri) async {
    // smb://<serverId>/<share>/<path> → split serverId, share, path.
    final parsed = _parseSmbUri(uri);
    if (parsed == null) return const [];
    final (serverId, share, path) = parsed;
    final dir = _parentDir(path);
    if (dir == null) return const [];
    final entries = await SmbClient.instance.listDirectory(serverId, share, dir);
    return _buildSubs(
      source: entries.map((e) => (e.name, e.path)).toList(),
      videoPath: path,
      buildFullUri: (subPath) => 'smb://$serverId/$share/$subPath',
    );
  }

  Future<List<VideoExternalSub>> _findWebDavOrHttp(
    String uri,
    VideoItem video,
  ) async {
    // WebDAV: the serverId was set by the screen on the VideoItem; for
    // generic http(s) (Jellyfin / direct URLs / random streams) there is
    // no "list this folder" operation, so we can't find sidecars.
    final webdavId = _webdavServerIdFor(video);
    if (webdavId == null) return const [];
    final servers = await WebDavClient.instance.listServers();
    final server = servers.firstWhere(
      (s) => s.id == webdavId,
      orElse: () => const WebDavServer(
        id: '',
        name: '',
        url: '',
        username: '',
        hasPassword: false,
      ),
    );
    if (server.id.isEmpty) return const [];
    final parsed = _parseHttpUri(uri);
    if (parsed == null) return const [];
    final urlPath = parsed.$2;
    final dir = _parentDir(urlPath);
    if (dir == null) return const [];
    final entries = await WebDavClient.instance.listDirectory(webdavId, dir);
    // Subtitle file paths come back relative to the server root (e.g.
    // `Movies/Show.S01E01.eng.srt`); build the full playable URL by
    // joining the WebDAV base URL with the relative path, with each
    // segment re-encoded for the URL.
    final base = server.url.replaceAll(RegExp(r'/+$'), '');
    return _buildSubs(
      source: entries.map((e) => (e.name, e.path)).toList(),
      videoPath: urlPath,
      buildFullUri: (subPath) => '$base/${_joinPath(subPath)}',
    );
  }

  Future<List<VideoExternalSub>> _findFtp(String uri) async {
    final parsed = _parseFtpUri(uri);
    if (parsed == null) return const [];
    final (scheme, serverId, path) = parsed;
    final dir = _parentDir(path);
    if (dir == null) return const [];
    final entries = await FtpClient.instance.listDirectory(serverId, dir);
    // Matches the FTP screen's URI format: `ftp://<serverId><encoded path>`
    // (no separator — the iOS FtpDataSource / Android FtpDataSource expect
    // this exact shape so the host parser can isolate the saved server id).
    return _buildSubs(
      source: entries.map((e) => (e.name, e.path)).toList(),
      videoPath: path,
      buildFullUri: (subPath) => '$scheme://$serverId$subPath',
    );
  }

  /// Filter [source] (name, relative-path) to ones that look like sidecar
  /// subtitles paired with the video at [videoPath]. Best match first; the
  /// first is flagged `isDefault = true`. Each entry's [buildFullUri] is
  /// used to construct the URI the engine will actually open.
  List<VideoExternalSub> _buildSubs({
    required List<(String name, String path)> source,
    required String videoPath,
    required String Function(String subPath) buildFullUri,
  }) {
    final videoBase = _basename(videoPath).toLowerCase();
    final subEntries = source
        .where((e) => _isSubtitle(e.$1))
        .toList(growable: false);
    if (subEntries.isEmpty) return const [];

    // Pass 1: exact base or base-with-extra-tokens match (preferred).
    final preferred = <(String name, String path, int score)>[];
    for (final e in subEntries) {
      final subBase = _basename(e.$1).toLowerCase();
      var score = 0;
      if (subBase == videoBase) {
        score = 200;
      } else if (subBase.startsWith('$videoBase.')) {
        score = 100;
      } else if (videoBase.startsWith('$subBase.')) {
        score = 80; // sub is a less-specific prefix of the video name
      } else {
        continue;
      }
      preferred.add((e.$1, e.$2, score));
    }
    preferred.sort((a, b) {
      final s = b.$3.compareTo(a.$3);
      return s != 0 ? s : a.$1.compareTo(b.$1);
    });

    if (preferred.isEmpty) return const [];

    // Cap to 8 matches — anything beyond is noise (a folder full of dub tracks
    // makes the CC sheet unreadable).
    final chosen = preferred.length > 8 ? preferred.sublist(0, 8) : preferred;

    return [
      for (var i = 0; i < chosen.length; i++)
        VideoExternalSub(
          uri: buildFullUri(chosen[i].$2),
          label: _basename(chosen[i].$1),
          language: _languageFromName(chosen[i].$1),
          mimeType: _mimeTypeFor(chosen[i].$1),
          isDefault: i == 0,
        ),
    ];
  }

  // ---------- URI parsing ----------

  /// smb://{serverId}/{share}/{dir}/{file}
  (String, String, String)? _parseSmbUri(String uri) {
    // Strip scheme.
    var rest = uri.substring('smb://'.length);
    // First segment = serverId, no '/' inside (it's a UUID / nanoid).
    final firstSlash = rest.indexOf('/');
    if (firstSlash < 0) return null;
    final serverId = rest.substring(0, firstSlash);
    rest = rest.substring(firstSlash + 1);
    // Second segment = share, may contain no '/'.
    final secondSlash = rest.indexOf('/');
    final share = secondSlash < 0 ? rest : rest.substring(0, secondSlash);
    final path = secondSlash < 0 ? '' : rest.substring(secondSlash + 1);
    if (serverId.isEmpty || share.isEmpty) return null;
    return (serverId, share, path);
  }

  /// Parses the relative WebDAV path out of `http(s)://<host>[:port]/<path>`.
  /// Returns `(host, path)`. The WebDAV serverId is looked up from the
  /// VideoItem metadata (see [_webdavServerIdFor]).
  (String, String)? _parseHttpUri(String uri) {
    final schemeEnd = uri.indexOf('://');
    if (schemeEnd < 0) return null;
    final rest = uri.substring(schemeEnd + 3);
    final firstSlash = rest.indexOf('/');
    if (firstSlash < 0) return null;
    final host = rest.substring(0, firstSlash);
    final path = rest.substring(firstSlash + 1);
    return (host, path);
  }

  /// Parses `ftp://<serverId><path>` / `sftp://<serverId><path>` (no `@`).
  /// The native FtpDataSource identifies the saved server by the first path
  /// segment after the scheme (everything up to the first `/`).
  (String, String, String)? _parseFtpUri(String uri) {
    final lower = uri.toLowerCase();
    final schemeEnd = lower.indexOf('://');
    if (schemeEnd < 0) return null;
    final scheme = lower.substring(0, schemeEnd); // 'ftp' or 'sftp'
    final rest = uri.substring(schemeEnd + 3);
    final firstSlash = rest.indexOf('/');
    final serverId = firstSlash < 0 ? rest : rest.substring(0, firstSlash);
    final path = firstSlash < 0 ? '' : rest.substring(firstSlash + 1);
    if (serverId.isEmpty) return null;
    return (scheme, serverId, path);
  }

  /// Pulls the WebDAV serverId off the VideoItem. We don't store it on
  /// `VideoItem` directly today, so fall back to a private hook in the
  /// `exo_player.dart` open path. For now, this returns null and the
  /// discovery is skipped on WebDAV — the WebDAV browser screens already
  /// pre-populate `externalSubtitles` from their own listings.
  String? _webdavServerIdFor(VideoItem video) {
    return video.webdavServerId;
  }

  // ---------- path helpers ----------

  /// Parent directory of a posix-style path. Returns null for top-level files.
  String? _parentDir(String path) {
    if (path.isEmpty) return null;
    final idx = path.lastIndexOf('/');
    if (idx < 0) return null; // no parent (e.g. `file.mkv`)
    return path.substring(0, idx);
  }

  /// File name without the last extension. `Show.S01E01.eng.srt` → `Show.S01E01.eng`.
  String _basename(String pathOrName) {
    final name = pathOrName.contains('/')
        ? pathOrName.substring(pathOrName.lastIndexOf('/') + 1)
        : pathOrName;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return name;
    return name.substring(0, dot);
  }

  /// Joins a server-relative path to a URL by percent-encoding each segment
  /// while preserving `/` separators. Names with `+`, spaces, brackets, etc.
  /// survive a WebDAV round trip.
  String _joinPath(String relPath) {
    return relPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
  }

  /// True if the file name has a subtitle extension we understand.
  bool _isSubtitle(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return _extensions.contains(ext);
  }

  /// MIME type for the given file name, falling back to SRT (the most
  /// common format).
  String _mimeTypeFor(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return _mimeTypes[ext] ?? 'application/x-subrip';
  }

  /// 2..6-char language tag between the last two dots: `Show.S01E01.eng.srt`
  /// → `eng`. Mirrors `SubtitleFormats.languageFromFileName`.
  String _languageFromName(String name) {
    final lower = name.toLowerCase();
    final last = lower.lastIndexOf('.');
    if (last <= 0) return '';
    var prev = -1;
    for (var i = last - 1; i >= 0; i--) {
      if (lower[i] == '.') {
        prev = i;
        break;
      }
    }
    if (prev < 0) return '';
    final len = last - prev - 1;
    if (len < 2 || len > 6) return '';
    return lower.substring(prev + 1, last);
  }
}
