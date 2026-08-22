import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subtitle_style.dart';

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

  static VideoFitMode fromValue(int? value) => VideoFitMode.values.firstWhere(
    (m) => m.value == value,
    orElse: () => VideoFitMode.fit,
  );
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
    this.bufferedMs = 0,
    this.videoCodecs,
    this.videoMime,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.colorTransfer,
    this.isHdr10Plus = false,
    this.isHdr10 = false,
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
    this.audioPassthrough = false,
  });

  final int state;
  final bool playing;
  final bool buffering;
  final bool ended;
  final int positionMs;
  final int durationMs;
  final int bufferedMs;
  final String? videoCodecs;
  final String? videoMime;
  final int videoWidth;
  final int videoHeight;
  final int? colorTransfer;

  /// True when the native side found ST 2094-40 (HDR10+) dynamic metadata in
  /// the video bitstream. Media3's format info can't tell HDR10+ from HDR10
  /// (both are PQ transfer), so this is a separate bitstream probe result.
  final bool isHdr10Plus;

  /// True when the native side found static HDR10 metadata (SEI payload
  /// types 137 = mastering display colour volume, 144 = content light level)
  /// in the video bitstream. This covers plain HDR10 files that omit the
  /// MKV Colour element — Media3's MatroskaExtractor doesn't populate
  /// `Format.colorInfo`, so this bitstream probe restores the correct
  /// HDR10 label and engages the headroom path.
  final bool isHdr10;
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

  /// True when audio passthrough is active (encoded bitstream routed to
  /// HDMI output via AudioTrack passthrough mode).
  final bool audioPassthrough;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);
  Duration get buffered => Duration(milliseconds: bufferedMs);

  static ExoPlayerEvent fromMap(Map<dynamic, dynamic> m) {
    int asInt(dynamic v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
    return ExoPlayerEvent(
      state: asInt(m['state']),
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      ended: m['ended'] == true,
      positionMs: asInt(m['positionMs']),
      durationMs: asInt(m['durationMs']),
      bufferedMs: asInt(m['bufferedMs']),
      videoCodecs: m['videoCodecs'] as String?,
      videoMime: m['videoMime'] as String?,
      videoWidth: asInt(m['videoWidth']),
      videoHeight: asInt(m['videoHeight']),
      colorTransfer: m['colorTransfer'] is num
          ? (m['colorTransfer'] as num).toInt()
          : null,
      isHdr10Plus: m['isHdr10Plus'] == true,
      isHdr10: m['isHdr10'] == true,
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
      audioPassthrough: m['audioPassthrough'] == true,
    );
  }
}

/// Common playback-control surface implemented by the in-app
/// [ExoPlayerController]. The player screen drives it on every platform
/// (phones, tablets, Android TV / Fire TV).
abstract class PlaybackController {
  Stream<ExoPlayerEvent> get events;

  ExoPlayerEvent? get latest;

  Future<void> open(
    String path, {
    String? uri,
    String? subtitleUri,
    int? startPositionMs,
    Map<String, String>? httpHeaders,
    bool allowSelfSigned = false,
    String? resumeKey,
    String? title,
  });

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);

  Future<void> setVolume(double volume);

  Future<void> setMuted(bool muted);

  Future<void> selectAudioTrack(int index);

  Future<void> selectSubtitleTrack(int index);

  /// Applies the user's subtitle appearance natively (size/color/background/
  /// outline + cue delay).
  Future<void> setSubtitleStyle(SubtitleStyle style);

  Future<void> setSubtitles(bool on);

  Future<void> setFitMode(VideoFitMode mode);

  /// Sets the display brightness (0.0 = dim, 1.0 = max). Per-app; reverts on
  /// player close on both platforms. Pass -1 to restore system default.
  Future<void> setBrightness(double brightness);

  /// Returns the current screen brightness (0.0–1.0).
  Future<double> getBrightness();

  /// Sets the system media volume (0.0–1.0). On Android this is
  /// AudioManager STREAM_MUSIC; on iOS this uses MPVolumeView.
  Future<void> setSystemVolume(double volume);

  /// Returns the current system media volume normalised to 0.0–1.0.
  Future<double> getSystemVolume();

  Future<ExoPlayerEvent?> getState();

  Future<void> dispose();
}

/// Dart-side handle to the native ExoPlayer platform view.
///
/// Create a [controller] and pass it to an [ExoPlayerView]; after the platform
/// view is created the controller's channels become live. Commands issued
/// before the platform view attaches (e.g. [open] from a screen's `initState`)
/// are queued and flushed once the channel exists. Listen on [events] for
/// playback state, or query [latest] for the most recent snapshot.
class ExoPlayerController implements PlaybackController {
  final _events = StreamController<ExoPlayerEvent>.broadcast();

  MethodChannel? _method;
  ExoPlayerEvent? _latest;
  final List<(String, Map<String, dynamic>?)> _pending = [];

  @override
  ExoPlayerEvent? get latest => _latest;

  /// Stream of playback state snapshots (roughly 250 ms while playing).
  @override
  Stream<ExoPlayerEvent> get events => _events.stream;

  void _attach(int viewId) {
    final method = MethodChannel('dreamplayer/exo_$viewId');
    _method = method;
    EventChannel(
      'dreamplayer/exo_events_$viewId',
    ).receiveBroadcastStream().listen((raw) {
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

  @override
  Future<void> open(
    String path, {
    String? uri,
    String? subtitleUri,
    int? startPositionMs,
    Map<String, String>? httpHeaders,
    bool allowSelfSigned = false,
    String? resumeKey,
    String? title,
  }) => _send('open', {
    if (uri != null && uri.isNotEmpty) 'uri': uri else 'path': path,
    if (path.isNotEmpty) 'path': path,
    if (subtitleUri != null && subtitleUri.isNotEmpty)
      'subtitleUri': subtitleUri,
    if (startPositionMs != null && startPositionMs > 0)
      'startPositionMs': startPositionMs,
    if (httpHeaders != null && httpHeaders.isNotEmpty) 'headers': httpHeaders,
    if (allowSelfSigned) 'allowSelfSigned': true,
    if (resumeKey != null && resumeKey.isNotEmpty) 'resumeKey': resumeKey,
    if (title != null && title.isNotEmpty) 'title': title,
  });

  @override
  Future<void> play() => _send('play');

  @override
  Future<void> pause() => _send('pause');

  /// Queries the native player's current state directly, instead of relying on
  /// the last pushed event. Returns null when the platform view isn't attached
  /// (e.g. mid background/foreground surface recreation) — callers can retry.
  @override
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

  @override
  Future<void> seekTo(Duration position) =>
      _send('seekTo', {'positionMs': position.inMilliseconds});

  @override
  Future<void> setVolume(double volume) =>
      _send('setVolume', {'volume': volume});

  @override
  Future<void> setMuted(bool muted) => _send('setMuted', {'muted': muted});

  @override
  Future<void> selectAudioTrack(int index) =>
      _send('setAudioTrack', {'index': index});

  @override
  Future<void> setSubtitles(bool on) => _send('setSubtitles', {'on': on});

  @override
  Future<void> selectSubtitleTrack(int index) =>
      _send('setSubtitleTrack', {'index': index});

  @override
  Future<void> setSubtitleStyle(SubtitleStyle style) =>
      _send('setSubtitleStyle', style.toChannelArgs());

  /// Sets how the video fills the view (fit/crop/stretch/fixed ratio).
  @override
  Future<void> setFitMode(VideoFitMode mode) =>
      _send('setResizeMode', {'mode': mode.value});

  @override
  Future<void> setBrightness(double brightness) =>
      _send('setBrightness', {'brightness': brightness});

  @override
  Future<double> getBrightness() async {
    final channel = _method;
    if (channel == null) return 0.5;
    try {
      final raw = await channel.invokeMethod<double>('getBrightness');
      return (raw ?? 0.5).clamp(0.0, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  @override
  Future<void> setSystemVolume(double volume) =>
      _send('setSystemVolume', {'volume': volume});

  @override
  Future<double> getSystemVolume() async {
    final channel = _method;
    if (channel == null) return 1.0;
    try {
      final raw = await channel.invokeMethod<double>('getSystemVolume');
      return (raw ?? 1.0).clamp(0.0, 1.0);
    } catch (_) {
      return 1.0;
    }
  }

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

  @override
  Future<void> dispose() async {
    await disposeNative();
    await _events.close();
  }
}

/// Embeds the native playback engine platform view.
///
/// Android: the ExoPlayer/Media3 [PlayerView]'s internal `SurfaceView` is
/// rendered through Flutter's **hybrid composition** (`PlatformViewLink` +
/// `PlatformViewsService.initExpensiveAndroidView`) so the video surface keeps
/// its own SurfaceFlinger layer on the physical display — required for real
/// HDR / Dolby Vision output.
///
/// The default `AndroidView` widget uses Flutter's virtual-display + texture
/// composition: the SurfaceView is composited into a non-HDR virtual display
/// (`flutter-vd#1` in SurfaceFlinger), read back as a texture, and that
/// SDR-flattened texture is what reaches the panel. Real HDR is impossible
/// through that path — the PQ/HLG transfer and the BT.2020 dataspace are lost
/// before the display ever sees them, so HDR/DV content renders washed out
/// (verified on-device: the DV P8 `c884f7` SurfaceView composited as CLIENT
/// into `flutter-vd#1` with `HWC Support: dv=false`, while Just Player's same
/// file device-composited onto the HDR panel). Hybrid composition keeps the
/// SurfaceView as a real layer on the physical display, so the decoder's PQ
/// output goes straight to the HWC and the display tone-maps it natively.
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
    // This platform view is the single playback surface on every platform:
    // phones and Android TV / Fire TV alike use the same hybrid-composition
    // SurfaceView so true HDR/DV stays device-composited everywhere.
    return PlatformViewLink(
      viewType: exoPlayerViewType,
      surfaceFactory:
          (BuildContext context, PlatformViewController controller) {
            return AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers:
                  const <Factory<OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            );
          },
      onCreatePlatformView: (PlatformViewCreationParams params) {
        final AndroidViewController nativeController =
            PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: params.viewType,
              layoutDirection: TextDirection.ltr,
            );
        nativeController
          ..addOnPlatformViewCreatedListener(controller._attach)
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return nativeController;
      },
    );
  }
}
