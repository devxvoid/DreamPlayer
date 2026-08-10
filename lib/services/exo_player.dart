import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const String exoPlayerViewType = 'dreamplayer/exo_player';

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
    this.audioCodecs,
    this.audioMime,
    this.audioChannels = 0,
    this.audioTracks = const [],
    this.selectedAudioTrack = -1,
    this.subtitleLabel,
    this.subtitleOn = false,
    this.error,
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
  final String? audioCodecs;
  final String? audioMime;
  final int audioChannels;
  final List<ExoAudioTrack> audioTracks;
  final int selectedAudioTrack;

  /// Auto-paired sideloaded subtitle, e.g. `Show.S01E01.eng` (null when the
  /// video has no paired subtitle file).
  final String? subtitleLabel;
  final bool subtitleOn;
  final String? error;

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
      audioCodecs: m['audioCodecs'] as String?,
      audioMime: m['audioMime'] as String?,
      audioChannels: asInt(m['audioChannels']),
      audioTracks: (m['audioTracks'] as List? ?? const [])
          .map((e) => ExoAudioTrack.fromMap(e as Map<dynamic, dynamic>))
          .toList(),
      selectedAudioTrack: asInt(m['selectedAudioTrack'], -1),
      subtitleLabel: m['subtitleLabel'] as String?,
      subtitleOn: m['subtitleOn'] == true,
      error: m['error'] as String?,
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
  }) =>
      _send('open', {
        if (uri != null && uri.isNotEmpty) 'uri': uri else 'path': path,
        if (subtitleUri != null && subtitleUri.isNotEmpty)
          'subtitleUri': subtitleUri,
      });

  Future<void> play() => _send('play');

  Future<void> pause() => _send('pause');

  Future<void> seekTo(Duration position) =>
      _send('seekTo', {'positionMs': position.inMilliseconds});

  Future<void> setVolume(double volume) => _send('setVolume', {'volume': volume});

  Future<void> setMuted(bool muted) => _send('setMuted', {'muted': muted});

  Future<void> selectAudioTrack(int index) =>
      _send('setAudioTrack', {'index': index});

  Future<void> setSubtitles(bool on) => _send('setSubtitles', {'on': on});

  Future<void> disposeNative() => _send('dispose');

  Future<void> _send(String method, [Map<String, dynamic>? args]) {
    final channel = _method;
    if (channel != null) {
      try {
        return channel.invokeMethod(method, args);
      } catch (_) {
        // Channel may be torn down during dispose; ignore.
      }
      return Future<void>.value();
    }
    _pending.add((method, args));
    return Future<void>.value();
  }

  Future<void> dispose() async {
    await disposeNative();
    await _events.close();
  }
}

/// Embeds the native ExoPlayer [SurfaceView] platform view.
///
/// Rendered through Flutter's hybrid composition fallback so the video keeps
/// its own SurfaceFlinger layer — required for real HDR / Dolby Vision output.
class ExoPlayerView extends StatelessWidget {
  const ExoPlayerView({super.key, required this.controller});

  final ExoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: exoPlayerViewType,
      onPlatformViewCreated: controller._attach,
    );
  }
}
