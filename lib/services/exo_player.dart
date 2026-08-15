import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String exoPlayerViewType = 'dreamplayer/exo_player';

/// How the video fills the playback view.
///
/// Maps to Media3 `AspectRatioFrameLayout` resize modes on Android and AVPlayer
/// `videoGravity` on iOS.
enum VideoFitMode {
  /// Letterbox: whole frame visible, black bars where the aspect differs.
  fit(0),

  /// Crop to fill: fills the view, keeps aspect, cuts off overflow.
  crop(1),

  /// Stretch: distorts the frame to fill the view exactly.
  stretch(2),

  /// Crop to a fixed 16:9 box (zoomed in from the source aspect).
  ratio16x9(3),

  /// Crop to a fixed 4:3 box.
  ratio4x3(4);

  const VideoFitMode(this.value);

  /// Stable id sent over the method channel.
  final int value;

  String get label => switch (this) {
        fit => 'Fit',
        crop => 'Crop to screen',
        stretch => 'Stretch to screen',
        ratio16x9 => '16:9',
        ratio4x3 => '4:3',
      };

  static VideoFitMode fromValue(int? value) => VideoFitMode.values
      .firstWhere((m) => m.value == value, orElse: () => VideoFitMode.fit);
}

/// Persists the user's chosen [VideoFitMode] across playback sessions.
class FitModeStore {
  FitModeStore._();

  static const String _prefsKey = 'dreamplayer.fitMode';

  static Future<VideoFitMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return VideoFitMode.fromValue(prefs.getInt(_prefsKey));
  }

  static Future<void> save(VideoFitMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, mode.value);
  }
}

/// A single audio track exposed by the native ExoPlayer, for the track picker.
@immutable
class ExoAudioTrack {
  const ExoAudioTrack({
    required this.index,
    this.language,
    this.label,
    this.codecs,
    this.mime,
    this.channels = 0,
    this.bitrate = 0,
    this.selected = false,
  });

  /// Flat index; the value to pass to [ExoPlayerController.selectAudioTrack].
  final int index;

  /// ISO-639 language code (e.g. `eng`).
  final String? language;

  /// Container-provided track name (e.g. `DTS-HD MA 5.1`, `Commentary`).
  /// Empty when the file has no named tracks.
  final String? label;
  final String? codecs;
  final String? mime;
  final int channels;
  final int bitrate;
  final bool selected;

  factory ExoAudioTrack.fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    return ExoAudioTrack(
      index: asInt(m['index']),
      language: m['language'] as String?,
      label: m['label'] as String?,
      codecs: m['codecs'] as String?,
      mime: m['mime'] as String?,
      channels: asInt(m['channels']),
      bitrate: asInt(m['bitrate']),
      selected: m['selected'] == true,
    );
  }
}

/// A single subtitle track exposed by the native ExoPlayer, for the subtitle
/// picker. Covers both embedded container tracks (PGS, SRT-in-MKV, ...) and
/// sideloaded sidecar files.
@immutable
class ExoSubtitleTrack {
  const ExoSubtitleTrack({
    required this.index,
    this.language,
    this.label,
    this.codecs,
    this.mime,
    this.sideloaded = false,
    this.selected = false,
  });

  /// Flat index; the value to pass to [ExoPlayerController.selectSubtitleTrack].
  final int index;

  /// ISO-639 language code (e.g. `eng`).
  final String? language;

  /// Track name: the container-provided label, or the sidecar file's base
  /// name (e.g. `Show.S01E01.eng`). Empty when unnamed.
  final String? label;

  /// Codec string (e.g. `application/x-subrip`, `hdmv.pgs`). For sideloaded
  /// tracks this is the sidecar's original MIME type.
  final String? codecs;
  final String? mime;
  final bool sideloaded;
  final bool selected;

  factory ExoSubtitleTrack.fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    return ExoSubtitleTrack(
      index: asInt(m['index']),
      language: m['language'] as String?,
      label: m['label'] as String?,
      codecs: m['codecs'] as String?,
      mime: m['mime'] as String?,
      sideloaded: m['sideloaded'] == true,
      selected: m['selected'] == true,
    );
  }
}

/// Snapshot of playback state pushed from the native ExoPlayer platform view.
@immutable
class ExoPlayerEvent {
  const ExoPlayerEvent({
    required this.state,
    required this.playing,
    required this.buffering,
    required this.ended,
    required this.positionMs,
    required this.durationMs,
    this.videoCodecs,
    this.videoMime,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.colorTransfer,
    this.isHdr10Plus = false,
    this.audioCodecs,
    this.audioMime,
    this.audioChannels = 0,
    this.audioTracks = const [],
    this.selectedAudioTrack = -1,
    this.subtitleLabel,
    this.subtitleFormat,
    this.subtitleOn = false,
    this.subtitleTracks = const [],
    this.selectedSubtitleTrack = -1,
    this.error,
    this.errorMessage,
    this.errorCause,
  });

  final int state;
  final bool playing;
  final bool buffering;
  final bool ended;
  final int positionMs;
  final int durationMs;
  final String? videoCodecs;
  final String? videoMime;
  final int videoWidth;
  final int videoHeight;
  final int? colorTransfer;

  /// True when the native side found ST 2094-40 (HDR10+) dynamic metadata in
  /// the video bitstream. Media3's format info can't tell HDR10+ from HDR10
  /// (both are PQ transfer), so this is a separate bitstream probe result.
  final bool isHdr10Plus;
  final String? audioCodecs;
  final String? audioMime;
  final int audioChannels;
  final List<ExoAudioTrack> audioTracks;
  final int selectedAudioTrack;

  /// Auto-paired sideloaded subtitle, e.g. `Show.S01E01.eng` (null when the
  /// video has no paired subtitle file).
  final String? subtitleLabel;

  /// Subtitle file format name (e.g. `SRT`, `SSA/ASS`, `SAMI`, `MicroDVD`).
  final String? subtitleFormat;
  final bool subtitleOn;

  /// All subtitle tracks (embedded + sideloaded) exposed by the player.
  final List<ExoSubtitleTrack> subtitleTracks;
  final int selectedSubtitleTrack;
  final String? error;

  /// Native PlaybackException detail (message / cause) for a friendlier error
  /// surface than just the opaque error code name.
  final String? errorMessage;
  final String? errorCause;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);

  static ExoPlayerEvent fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
    return ExoPlayerEvent(
      state: asInt(m['state']),
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      ended: m['ended'] == true,
      positionMs: asInt(m['positionMs']),
      durationMs: asInt(m['durationMs']),
      videoCodecs: m['videoCodecs'] as String?,
      videoMime: m['videoMime'] as String?,
      videoWidth: asInt(m['videoWidth']),
      videoHeight: asInt(m['videoHeight']),
      colorTransfer: m['colorTransfer'] is num
          ? (m['colorTransfer'] as num).toInt()
          : null,
      isHdr10Plus: m['isHdr10Plus'] == true,
      audioCodecs: m['audioCodecs'] as String?,
      audioMime: m['audioMime'] as String?,
      audioChannels: asInt(m['audioChannels']),
      audioTracks: (m['audioTracks'] as List? ?? const [])
          .map((e) => ExoAudioTrack.fromMap(e as Map<dynamic, dynamic>))
          .toList(),
      selectedAudioTrack: asInt(m['selectedAudioTrack'], -1),
      subtitleLabel: m['subtitleLabel'] as String?,
      subtitleFormat: m['subtitleFormat'] as String?,
      subtitleOn: m['subtitleOn'] == true,
      subtitleTracks: (m['subtitleTracks'] as List? ?? const [])
          .map((e) => ExoSubtitleTrack.fromMap(e as Map<dynamic, dynamic>))
          .toList(),
      selectedSubtitleTrack: asInt(m['selectedSubtitleTrack'], -1),
      error: m['error'] as String?,
      errorMessage: m['errorMessage'] as String?,
      errorCause: m['errorCause'] as String?,
    );
  }
}

/// Dart-side handle to the native ExoPlayer platform view.
///
/// Create a [controller] and pass it to an [ExoPlayerView]; after the platform
/// view is created the controller's channels become live. Commands issued
/// before the platform view attaches (e.g. [open] from a screen's `initState`)
/// are queued and flushed once the channel exists. Listen on [events] for
/// playback state, or query [latest] for the most recent snapshot.
class ExoPlayerController {
  final _events = StreamController<ExoPlayerEvent>.broadcast();

  MethodChannel? _method;
  ExoPlayerEvent? _latest;
  final List<(String, Map<String, dynamic>?)> _pending = [];

  ExoPlayerEvent? get latest => _latest;

  /// Stream of playback state snapshots (roughly 250 ms while playing).
  Stream<ExoPlayerEvent> get events => _events.stream;

  void _attach(int viewId) {
    final method = MethodChannel('dreamplayer/exo_$viewId');
    _method = method;
    EventChannel('dreamplayer/exo_events_$viewId')
        .receiveBroadcastStream()
        .listen((raw) {
      if (raw is! Map) return;
      final event = ExoPlayerEvent.fromMap(raw);
      _latest = event;
      if (!_events.isClosed) _events.add(event);
    });
    for (final (name, args) in _pending) {
      method.invokeMethod(name, args);
    }
    _pending.clear();
  }

  Future<void> open(
    String path, {
    String? uri,
    String? subtitleUri,
    int? startPositionMs,
    Map<String, String>? httpHeaders,
    bool allowSelfSigned = false,
  }) =>
      _send('open', {
        if (uri != null && uri.isNotEmpty) 'uri': uri else 'path': path,
        if (path.isNotEmpty) 'path': path,
        if (subtitleUri != null && subtitleUri.isNotEmpty)
          'subtitleUri': subtitleUri,
        if (startPositionMs != null && startPositionMs > 0)
          'startPositionMs': startPositionMs,
        if (httpHeaders != null && httpHeaders.isNotEmpty)
          'headers': httpHeaders,
        if (allowSelfSigned) 'allowSelfSigned': true,
      });

  Future<void> play() => _send('play');

  Future<void> pause() => _send('pause');

  /// Queries the native player's current state directly, instead of relying on
  /// the last pushed event. Returns null when the platform view isn't attached
  /// (e.g. mid background/foreground surface recreation) — callers can retry.
  Future<ExoPlayerEvent?> getState() async {
    final channel = _method;
    if (channel == null) return _latest;
    try {
      final raw = await channel.invokeMethod<Map<dynamic, dynamic>>('getState');
      if (raw is Map) {
        final event = ExoPlayerEvent.fromMap(raw);
        _latest = event;
        return event;
      }
    } catch (_) {
      // Channel torn down while the view is being recreated; not attached yet.
      return null;
    }
    return _latest;
  }

  Future<void> seekTo(Duration position) =>
      _send('seekTo', {'positionMs': position.inMilliseconds});

  Future<void> setVolume(double volume) => _send('setVolume', {'volume': volume});

  Future<void> setMuted(bool muted) => _send('setMuted', {'muted': muted});

  Future<void> selectAudioTrack(int index) =>
      _send('setAudioTrack', {'index': index});

  Future<void> setSubtitles(bool on) => _send('setSubtitles', {'on': on});

  Future<void> selectSubtitleTrack(int index) =>
      _send('setSubtitleTrack', {'index': index});

  /// Sets how the video fills the view (fit/crop/stretch/fixed ratio).
  Future<void> setFitMode(VideoFitMode mode) =>
      _send('setResizeMode', {'mode': mode.value});

  Future<void> disposeNative() => _send('dispose');

  Future<void> _send(String method, [Map<String, dynamic>? args]) {
    final channel = _method;
    if (channel == null) {
      _pending.add((method, args));
      return Future<void>.value();
    }
    try {
      // `MissingPluginException` is thrown on the returned future (not
      // synchronously) when the platform view is torn down during dispose.
      return channel.invokeMethod(method, args).catchError((Object _) {
        // Channel may be torn down during dispose; ignore.
      });
    } catch (_) {
      // Channel may be torn down during dispose; ignore.
      return Future<void>.value();
    }
  }

  Future<void> dispose() async {
    await disposeNative();
    await _events.close();
  }
}

/// Embeds the native playback engine platform view.
///
/// Android: ExoPlayer/Media3 [SurfaceView], rendered through Flutter's hybrid
/// composition fallback so the video keeps its own SurfaceFlinger layer —
/// required for real HDR / Dolby Vision output.
///
/// iOS: AVPlayer-backed `AVPlayerLayer` (see `AvPlayerView.swift`), which also
/// renders on its own Core Animation layer so the display receives the native
/// HDR signal.
class ExoPlayerView extends StatelessWidget {
  const ExoPlayerView({super.key, required this.controller});

  final ExoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return UiKitView(
        viewType: exoPlayerViewType,
        onPlatformViewCreated: controller._attach,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return AndroidView(
      viewType: exoPlayerViewType,
      onPlatformViewCreated: controller._attach,
    );
  }
}
