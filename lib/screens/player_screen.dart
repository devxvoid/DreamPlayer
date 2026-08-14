import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/exo_player.dart';
import '../services/resume_store.dart';
import '../utils/codec_info.dart';
import '../widgets/format_chip.dart';

/// Whether the app is running under `flutter test`.
const bool _inTests = bool.fromEnvironment('FLUTTER_TEST');

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.video,
    this.playlist = const [],
    this.playlistIndex = 0,
  });

  final VideoItem video;

  /// Optional ordered list of videos (e.g. the other videos in the same folder)
  /// for auto-advance to the next episode when one ends.
  final List<VideoItem> playlist;
  final int playlistIndex;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  /// Native ExoPlayer (Media3) backend hosted in a platform view.
  ExoPlayerController? _exo;
  StreamSubscription<ExoPlayerEvent>? _exoSub;

  /// The video currently on screen; follows [PlayerScreen.video] on first load
  /// and advances through [PlayerScreen.playlist] on end.
  late VideoItem _current = widget.video;
  late int _playlistIndex = widget.playlistIndex;

  bool _controlsVisible = true;
  bool _fullscreen = false;

  Timer? _hideTimer;
  bool? _lastLandscape;
  static const Duration _autoHideAfter = Duration(seconds: 3);

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  String? _error;

  bool _dragging = false;
  double _dragValue = 0;

  String? _liveVideoCodec;
  String? _liveVideoCodecRaw;
  String? _liveAudioCodec;
  int? _liveAudioChannelCount;
  String? _liveResolution;
  HdrFormat _liveHdr = HdrFormat.sdr;
  List<ExoAudioTrack> _audioTracks = const [];
  int _selectedAudioTrackIndex = -1;

  bool _subtitleOn = false;
  List<ExoSubtitleTrack> _subtitleTracks = const [];
  int _selectedSubtitleTrack = -1;

  VideoFitMode _fitMode = VideoFitMode.fit;

  /// Last time the resume position was persisted (throttled while playing).
  DateTime _lastResumeSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Stable per-video key for the resume store: an explicit [VideoItem.resumeKey]
  /// wins (sources whose path/URI rotate, e.g. iPad SMB proxy URLs), otherwise
  /// path then URI.
  String get _resumeKey =>
      _current.resumeKey ?? _current.path ?? _current.uri ?? '';

  bool get _backendReady => _exo != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the system UI mode constant (immersive) for the whole player
    // screen. Toggling immersive/edgeToEdge during the rotation transition
    // fights the system's own rotation animation and makes the video jitter.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncOrientationFromPlatform();
    });
    if (!_inTests) {
      _init();
    }
  }

  Future<void> _init() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      if (mounted) {
        setState(() {
          _error = 'Playback is not yet supported on this platform.';
        });
      }
      return;
    }
    if (Platform.isAndroid) {
      await Permission.videos.request();
    }
    try {
      final exo = ExoPlayerController();
      _exo = exo;
      _exoSub = exo.events.listen(_onExoEvent);
      try {
        _fitMode = await FitModeStore.load();
      } catch (_) {
        // Persistence unavailable; keep the default fit.
      }
      if (mounted) setState(() {});
      await _openCurrent();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Playback unavailable: $e');
      }
    }
  }

  Future<void> _openCurrent() async {
    final video = _current;
    debugPrint(
      'DREAM_OPEN title="${video.title}" path=${video.path} uri=${video.uri} '
      'headers=${video.httpHeaders.keys.toList()}',
    );
    if (video.path == null && video.uri == null) {
      if (mounted) {
        setState(() => _error = 'No video source provided.');
      }
      return;
    }
    Duration? resume;
    if (!_inTests) {
      resume = await ResumeStore.positionFor(_resumeKey);
      // Skip trivial positions and "basically finished" ones.
      if (resume != null && resume < const Duration(seconds: 10)) resume = null;
      if (resume != null &&
          video.duration > Duration.zero &&
          video.duration - resume < const Duration(seconds: 5)) {
        resume = null;
      }
    }
    try {
      await _exo?.open(
        video.path ?? '',
        uri: video.uri,
        subtitleUri: video.subtitleUri,
        startPositionMs: resume?.inMilliseconds,
        httpHeaders: video.httpHeaders,
        allowSelfSigned: video.allowSelfSigned,
      );
      // Re-apply the user's persisted fit mode to the new session.
      _exo?.setFitMode(_fitMode);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Playback unavailable: $e');
      }
    }
  }

  void _saveResume(Duration position) {
    if (_inTests) return;
    final key = _resumeKey;
    if (key.isEmpty || position <= Duration.zero) return;
    ResumeStore.save(key, position);
    // Keep the home "Continue watching" list in sync (skip trivial positions).
    if (position >= const Duration(seconds: 10)) {
      ContinueWatchingStore.save(_withLiveDuration, position);
    }
  }

  /// The current video, but with a real duration when the player already knows
  /// it (WebDAV/stream URLs start with `Duration.zero`, and the card needs the
  /// duration to draw its progress bar).
  VideoItem get _withLiveDuration =>
      _duration > Duration.zero && _current.duration <= Duration.zero
          ? _current.withPlaybackInfo(duration: _duration)
          : _current;

  Future<void> _clearResume() async {
    if (_inTests) return;
    final key = _resumeKey;
    if (key.isEmpty) return;
    await ResumeStore.clear(key);
    await ContinueWatchingStore.remove(key);
  }

  /// Advances to the next video in the playlist when the current one ends
  /// (play-next-episode in a folder).
  Future<void> _playNext() async {
    final playlist = widget.playlist;
    if (playlist.isEmpty || _playlistIndex >= playlist.length - 1) return;
    final next = playlist[++_playlistIndex];
    setState(() {
      _current = next;
      _position = Duration.zero;
      _duration = Duration.zero;
      _completed = false;
      _error = null;
      _liveVideoCodec = null;
      _liveVideoCodecRaw = null;
      _liveAudioCodec = null;
      _liveAudioChannelCount = null;
      _liveResolution = null;
      _liveHdr = HdrFormat.sdr;
      _subtitleOn = false;
      _subtitleTracks = const [];
      _selectedSubtitleTrack = -1;
    });
    _showControls();
    await _openCurrent();
  }

  /// Maps a native PlaybackException to something a user can act on.
  String _friendlyError(ExoPlayerEvent e) {
    final code = e.error ?? '';
    switch (code) {
      case 'error_code_io_bad_http_status':
        final detail = e.errorMessage?.isNotEmpty == true
            ? '\n${e.errorMessage}'
            : '';
        return 'Server returned an error status for this file$detail. The '
            'source may have expired (e.g. a file handoff from a file '
            'manager) — reopen it from its source and try again.';
      case 'error_code_io_file_not_found':
      case 'error_code_io_no_permission':
        return 'The video file could not be accessed. It may have been '
            'moved, deleted, or its access permission has expired — reopen '
            'it from its source.';
      case 'error_code_io_network_connection_failed':
      case 'error_code_io_network_connection_timeout':
      case 'error_code_timeout':
        return 'Could not reach the server. Check your network connection '
            'and try again.';
      case 'error_code_io_cleartext_not_permitted':
        return 'Plain HTTP is blocked for this source. Use HTTPS if the '
            'server supports it.';
      default:
        final detail = e.errorMessage?.isNotEmpty == true
            ? '\n${e.errorMessage}'
            : '';
        return 'Playback failed ($code).$detail';
    }
  }

  void _onExoEvent(ExoPlayerEvent e) {
    final wasPlaying = _playing;
    final wasBuffering = _buffering;
    _playing = e.playing;
    _position = e.position;
    _duration = e.duration;
    _buffering = e.buffering;
    _completed = e.ended;
    if (e.error != null && e.error!.isNotEmpty) _error = _friendlyError(e);
    _subtitleOn = e.subtitleOn;
    _subtitleTracks = e.subtitleTracks;
    _selectedSubtitleTrack = e.selectedSubtitleTrack;
    if (e.videoCodecs != null && e.videoCodecs!.isNotEmpty) {
      _liveVideoCodecRaw = e.videoCodecs;
      _liveVideoCodec = formatVideoCodec(e.videoCodecs);
    }
    _liveHdr = detectMedia3HdrFormat(
      colorTransfer: e.colorTransfer,
      videoCodecs: _liveVideoCodecRaw,
    );
    if (e.videoWidth > 0 && e.videoHeight > 0) {
      _liveResolution = '${e.videoWidth}x${e.videoHeight}';
    }
    if (e.audioMime != null || e.audioCodecs != null) {
      _liveAudioCodec = formatMedia3Audio(e.audioMime, e.audioCodecs);
      if (e.audioChannels > 0) _liveAudioChannelCount = e.audioChannels;
    }
    _audioTracks = e.audioTracks;
    _selectedAudioTrackIndex = e.selectedAudioTrack;

    // Resume bookmark: persist every ~5s while playing, and immediately when
    // playback pauses/stops. A finished video clears its bookmark (it ended,
    // so there is nothing left to resume).
    if (e.ended) {
      _clearResume();
    } else {
      final now = DateTime.now();
      if (_playing && !_buffering && !_dragging &&
          now.difference(_lastResumeSave) >= const Duration(seconds: 5)) {
        _lastResumeSave = now;
        _saveResume(_position);
      } else if (wasPlaying && !_playing) {
        _saveResume(_position);
      }
    }

    if (wasPlaying != _playing || wasBuffering != _buffering) {
      _syncControlsForPlaybackState();
    }
    if (mounted) setState(() {});
    if (e.ended && widget.playlist.isNotEmpty) {
      _playNext();
    }
  }

  /// Keeps the controls visible while paused or buffering, and starts the
  /// auto-hide countdown only while playing.
  void _syncControlsForPlaybackState() {
    if (_playing && !_buffering) {
      _restartHideTimer();
    } else {
      _hideTimer?.cancel();
      _controlsVisible = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist the position when the app goes to the background or is killed,
    // so "continue where I stopped" works even if playback was mid-way.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveResume(_position);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _saveResume(_position);
    _exoSub?.cancel();
    _exo?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// Reveals the controls (and restarts the auto-hide countdown).
  void _showControls() {
    if (mounted && !_controlsVisible) setState(() => _controlsVisible = true);
    _restartHideTimer();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!_playing || _buffering || _dragging) return;
    _hideTimer = Timer(_autoHideAfter, () {
      if (mounted && _controlsVisible && _playing && !_buffering && !_dragging) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onScreenTap() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _syncOrientationFromPlatform();
  }

  /// Tracks the current orientation from the platform dispatcher's size. The
  /// player screen is always immersive, so this just keeps `_fullscreen` (the
  /// fullscreen-button icon) in sync with the device orientation.
  void _syncOrientationFromPlatform() {
    if (!mounted) return;
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    _applyOrientation(view.physicalSize.width > view.physicalSize.height);
  }

  /// Tracks the current orientation. The player screen is always immersive, so
  /// rotation only re-lays-out (no system UI change) — this is what keeps the
  /// video from jittering mid-rotation.
  void _applyOrientation(bool landscape) {
    if (landscape == _lastLandscape) return;
    _lastLandscape = landscape;
    _fullscreen = landscape;
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    final landscape = !_fullscreen;
    if (landscape) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    _showControls();
  }

  String _audioTrackLabel(ExoAudioTrack t) {
    final label = t.label?.trim();
    final channels = t.channels > 0 ? channelsLabel(t.channels) : null;
    // Prefer the container-provided track name (e.g. "DTS-HD MA 5.1",
    // "English", "Commentary") when the file names its tracks; append the
    // channel count unless the name already carries it.
    if (label != null && label.isNotEmpty) {
      if (channels == null) return label;
      final hasChannels = label.contains(channels) ||
          label.contains(t.channels.toString());
      return hasChannels ? label : '$label · $channels';
    }
    final lang = languageName(t.language);
    final codec = formatMedia3Audio(t.mime, t.codecs);
    return [
      if (lang.isNotEmpty) lang,
      if (codec != 'Unknown') codec,
      ?channels,
    ].join(' · ');
  }

  Future<void> _openAudioTrackSheet() async {
    _showControls();
    final tracks = _audioTracks;
    if (tracks.isEmpty) return;
    final selected = _selectedAudioTrackIndex;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  'Audio tracks',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final t = tracks[i];
                    final isSelected = t.index == selected;
                    return ListTile(
                      leading: Icon(
                        isSelected ? Icons.check_circle : Icons.graphic_eq,
                        color: isSelected ? Colors.white : Colors.white54,
                      ),
                      title: Text(
                        _audioTrackLabel(t),
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: t.bitrate > 0
                          ? Text(
                              '${(t.bitrate / 1000).round()} kbps',
                              style: const TextStyle(color: Colors.white54),
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(t.index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice != null && choice != selected) {
      // Native side switches the track; onTracksChanged re-emits with the new
      // codec/channels, which updates the top-bar audio chip automatically.
      _exo?.selectAudioTrack(choice);
    }
  }

  String _subtitleTrackLabel(ExoSubtitleTrack t) {
    final label = t.label?.trim();
    final format = formatSubtitle(t.mime, t.codecs);
    if (label != null && label.isNotEmpty) {
      // Embedded tracks may share a container label (`English / 4kHdHub.com`);
      // sideloaded siblings share a filename base (`House.S02E04`) across
      // formats. Append the format so every track reads uniquely.
      return '$label · $format';
    }
    final lang = languageName(t.language);
    return lang.isNotEmpty ? '$lang · $format' : format;
  }

  /// Subtitle picker: lists every subtitle track (embedded container tracks
  /// plus auto-paired sidecar files) plus an Off option.
  Future<void> _openSubtitleSheet() async {
    _showControls();
    final tracks = _subtitleTracks;
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No subtitles found in this video')),
      );
      return;
    }
    final selected = _selectedSubtitleTrack;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  'Subtitles',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  selected < 0 ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: selected < 0 ? Colors.white : Colors.white54,
                ),
                title: const Text(
                  'Off',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.of(context).pop(-1),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final t = tracks[i];
                    final isSelected = t.index == selected;
                    return ListTile(
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: isSelected ? Colors.white : Colors.white54,
                      ),
                      title: Text(
                        _subtitleTrackLabel(t),
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => Navigator.of(context).pop(t.index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice != null && choice != selected) {
      _exo?.selectSubtitleTrack(choice);
    }
  }

  /// Aspect / fit-mode picker: Fit, Crop to screen, Stretch to screen, then the
  /// fixed ratios (16:9, 4:3). The list is scrollable and height-capped so the
  /// sheet never overflows in landscape. Choice is applied to the native
  /// surface and persisted for future sessions.
  Future<void> _openFitModeSheet() async {
    _showControls();
    const order = VideoFitMode.values;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  'Aspect ratio',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: order.length,
                  itemBuilder: (context, i) {
                    final mode = order[i];
                    final isSelected = mode == _fitMode;
                    return ListTile(
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: isSelected ? Colors.white : Colors.white54,
                      ),
                      title: Text(
                        mode.label,
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => Navigator.of(context).pop(mode.value),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice != null) {
      final mode = VideoFitMode.fromValue(choice);
      if (mode != _fitMode) {
        setState(() => _fitMode = mode);
        _exo?.setFitMode(mode);
        if (!_inTests) FitModeStore.save(mode);
      }
    }
  }

  void _seekBy(Duration delta) {
    _exo?.seekTo(_position + delta);
    _showControls();
  }

  void _onSeekStart(double value) {
    _dragging = true;
    _dragValue = value;
    _hideTimer?.cancel();
    setState(() {});
  }

  void _onSeekUpdate(double value) {
    _dragValue = value;
    setState(() {});
  }

  void _onSeekEnd(double value) {
    _exo?.seekTo(Duration(milliseconds: value.round()));
    _dragging = false;
    _dragValue = value;
    _showControls();
  }

  void _togglePlayPause() {
    final exo = _exo;
    if (exo == null) return;
    if (_completed) {
      exo.seekTo(Duration.zero);
      exo.play();
    } else if (_playing) {
      exo.pause();
    } else {
      exo.play();
    }
    _showControls();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int v) => v.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// HDR shown on the chip: prefer the metadata hint (authoritative for
  /// Dolby Vision), falling back to live detection when metadata is silent.
  HdrFormat get _effectiveHdr {
    if (_current.hdrFormat != HdrFormat.sdr) return _current.hdrFormat;
    if (_liveHdr != HdrFormat.sdr) return _liveHdr;
    return HdrFormat.sdr;
  }

  Color get _hdrColor {
    switch (_effectiveHdr) {
      case HdrFormat.dolbyVision:
        return const Color(0xFFB388FF);
      case HdrFormat.hdr10plus:
        return const Color(0xFFFFC400);
      case HdrFormat.hdr10:
        return const Color(0xFFFF8A65);
      case HdrFormat.hlg:
        return const Color(0xFFFFB74D);
      case HdrFormat.sdr:
        return const Color(0xFF9E9E9E);
    }
  }

  Color get _videoColor => const Color(0xFF4FC3F7);

  Color get _audioColor => const Color(0xFF81C784);

  Color get _infoColor => const Color(0xFF90A4AE);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final video = _current;

    final total = _duration;
    final maxMs = total.inMilliseconds > 0
        ? total.inMilliseconds.toDouble()
        : video.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final sliderValue = _dragging
        ? _dragValue
        : _position.inMilliseconds.toDouble().clamp(0, maxMs).toDouble();

    final hdrChip = FormatChip(
      label: _effectiveHdr.label,
      color: _hdrColor,
    );
    // For Dolby Vision the HDR chip already says "Dolby Vision" (purple); skip
    // the video codec chip so it isn't shown twice.
    final videoCodecLabel = _liveVideoCodec ?? video.videoCodecLabel;
    final videoChip =
        videoCodecLabel != null &&
            !(_effectiveHdr == HdrFormat.dolbyVision &&
                videoCodecLabel == 'Dolby Vision')
        ? FormatChip(label: videoCodecLabel, color: _videoColor)
        : null;
    final audioChipLabel = _liveAudioCodec != null
        ? formatLiveAudioLabel(
            liveCodec: _liveAudioCodec,
            liveChannels: _liveAudioChannelCount,
            metaCodec: video.audioCodec,
            metaProfile: video.audioProfile,
          )
        : video.audioCodecLabel;
    final audioChip = audioChipLabel != null
        ? FormatChip(label: audioChipLabel, color: _audioColor)
        : null;
    final resolutionChip = (_liveResolution ?? video.resolution) != null
        ? FormatChip(
            label: _liveResolution ?? video.resolution!,
            color: _infoColor,
          )
        : null;
    final chips = [
      hdrChip,
      ?videoChip,
      ?audioChip,
      ?resolutionChip,
    ];

    final videoLayer = _exo != null && _error == null
        ? ExoPlayerView(controller: _exo!)
        : Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [colorScheme.primaryContainer, Colors.black],
              ),
            ),
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    )
                  : const Icon(
                      Icons.movie_filter,
                      size: 96,
                      color: Colors.white24,
                    ),
            ),
          );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: videoLayer),
          // Full-screen tap catcher on top of the (Android platform) video
          // layer. Hybrid-composition platform views can swallow touches, so a
          // plain GestureDetector wrapping the view is unreliable; catching taps
          // one layer up guarantees the controls always appear on touch.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _onScreenTap,
              child: const SizedBox.expand(),
            ),
          ),
          if (_buffering && _backendReady && _error == null)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            offset: _controlsVisible ? Offset.zero : const Offset(0, -1),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.72),
                    Colors.black.withValues(alpha: 0.35),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back),
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              video.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (chips.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final chip in chips)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: chip,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _controlsVisible ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(36),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: !_backendReady
                            ? null
                            : () =>
                                _seekBy(const Duration(seconds: -10)),
                        iconSize: 40,
                        icon: const Icon(Icons.replay_10),
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: !_backendReady ? null : _togglePlayPause,
                        iconSize: 72,
                        icon: Icon(
                          _completed
                              ? Icons.replay
                              : _playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_fill,
                        ),
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: !_backendReady
                            ? null
                            : () =>
                                _seekBy(const Duration(seconds: 10)),
                        iconSize: 40,
                        icon: const Icon(Icons.forward_10),
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            offset: _controlsVisible ? Offset.zero : const Offset(0, 1),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.35),
                      Colors.black.withValues(alpha: 0.72),
                    ],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(_dragging
                                      ? Duration(
                                          milliseconds: _dragValue.round(),
                                        )
                                      : _position),
                                  style: const TextStyle(color: Colors.white),
                                ),
                                Text(
                                  _formatDuration(total),
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                            Slider(
                              value: sliderValue,
                              max: maxMs,
                              onChangeStart: _onSeekStart,
                              onChanged: _onSeekUpdate,
                              onChangeEnd: _onSeekEnd,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                IconButton(
                                  onPressed: _openAudioTrackSheet,
                                  icon: const Icon(Icons.graphic_eq),
                                  color: Colors.white,
                                ),
                                IconButton(
                                  onPressed: _openSubtitleSheet,
                                  icon: Icon(
                                    _subtitleOn
                                        ? Icons.closed_caption
                                        : Icons.closed_caption_off,
                                  ),
                                  color: _subtitleOn ? Colors.white : Colors.white54,
                                ),
                                IconButton(
                                  onPressed: _openFitModeSheet,
                                  icon: const Icon(Icons.tune),
                                  color: Colors.white,
                                ),
                                IconButton(
                                  onPressed: _toggleFullscreen,
                                  icon: Icon(
                                    _fullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                  ),
                                  color: Colors.white,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
