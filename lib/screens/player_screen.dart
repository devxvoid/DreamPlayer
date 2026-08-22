import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/exo_player.dart';
import '../services/jellyfin_client.dart';
import '../services/resume_store.dart';
import '../services/subtitle_style.dart';
import '../utils/codec_info.dart';
import '../utils/tv_helper.dart';
import '../widgets/format_chip.dart';

/// Whether the app is running under `flutter test`.
const bool _inTests = bool.fromEnvironment('FLUTTER_TEST');

enum _SwipeType { brightness, volume }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.video});

  final VideoItem video;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  /// Native playback backend: the in-app ExoPlayer platform view (the same
  /// hybrid-composition SurfaceView on phones and Android TV / Fire TV).
  PlaybackController? _exo;
  StreamSubscription<ExoPlayerEvent>? _exoSub;

  /// The video currently on screen; follows [PlayerScreen.video] on first
  /// load, and is replaced by the server-transcoded variant when the Jellyfin
  /// transcode fallback fires.
  late VideoItem _current = widget.video;

  bool _controlsVisible = true;
  bool _fullscreen = false;

  /// Focus node for the screen-level [Focus] wrapper. On TV the wrapper owns
  /// focus by default (autofocus); the key handler compares
  /// `FocusManager.instance.primaryFocus` against this node to tell whether a
  /// control button is focused (then `select` should activate it) or nothing
  /// is (then `select` toggles play/pause).
  final FocusScopeNode _playerFocusScopeNode = FocusScopeNode();
  final FocusNode _playPauseFocusNode = FocusNode();

  Timer? _hideTimer;
  bool? _lastLandscape;
  static const Duration _autoHideAfter = Duration(milliseconds: 3500);

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;

  /// True once a media has loaded on this screen (video size/codecs/duration
  /// seen). Survives a native state reset (IDLE event after the platform view
  /// is recreated on unlock) so [didChangeAppLifecycleState] can detect that
  /// the media was lost and reopen it.
  bool _hadMedia = false;

  /// True when the current source is a network stream (WebDAV) whose
  /// underlying TCP connection is killed when iOS backgrounds the app.
  /// On resume, the engine still reports paused (not IDLE) but the reader is
  /// dead — we must force-reload instead of just calling play().
  bool _isNetworkSource = false;
  String? _error;

  bool _dragging = false;
  double _dragValue = 0;

  /// Auto-retry on transient IO errors (network blip).
  int _ioRetries = 0;
  static const int _maxIoRetries = 3;
  bool _retrying = false;

  /// Jellyfin transcode fallback: tried at most once per video, and only
  /// while the current URI is still a direct stream.
  bool _transcodeRetried = false;
  bool _transcodeActive = false;
  String? _transcodeServerUrl;

  String? _liveVideoCodec;
  String? _liveVideoCodecRaw;
  String? _liveAudioCodec;
  int? _liveAudioChannelCount;
  bool _liveAudioPassthrough = false;
  String? _liveResolution;
  HdrFormat _liveHdr = HdrFormat.sdr;
  List<ExoAudioTrack> _audioTracks = const [];
  int _selectedAudioTrackIndex = -1;

  bool _subtitleOn = false;
  List<ExoSubtitleTrack> _subtitleTracks = const [];
  int _selectedSubtitleTrack = -1;

  VideoFitMode _fitMode = VideoFitMode.fit;

  /// Whether the app is running on a TV (set once on first build).
  bool _isTv = false;

  /// Swipe gesture state (brightness / volume).
  bool _swipeEnabled = true;
  /// Swipe-gesture type (null = no gesture in progress).
  _SwipeType? _swipeType;
  /// True between drag-start and drag-end. [_swipeType] deliberately stays
  /// set during the 800ms pill fade-out (so the icon doesn't flip to the
  /// other type mid-fade); this flag gates actual gesture work instead.
  bool _swipeGestureActive = false;
  double _swipeCurrentValue = 0;
  /// The LIVE platform value fetched when the gesture started. Deltas apply
  /// on top of this, so a swipe always begins where the system actually is.
  double _swipeBase = 0;
  /// Accumulated finger movement for the current gesture. Buffered until the
  /// base value arrives so an early drag never applies a wrong absolute value.
  double _swipeDragDelta = 0;
  double _iosOriginalBrightness = -1;
  Timer? _swipeOverlayTimer;

  /// Horizontal-swipe seek preview state.
  bool _seekPreviewActive = false;
  int _seekBaseMs = 0;
  double _seekDragPx = 0;
  int _seekTargetMs = 0;

  /// Seconds covered by a full-screen-width horizontal drag.
  static const double _seekDragSpanSeconds = 90;

  /// Last time the resume position was persisted (throttled while playing).
  DateTime _lastResumeSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Stable per-video key for the resume store: an explicit [VideoItem.resumeKey]
  /// wins (sources whose path/URI rotate), otherwise
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
    // Resolve the backend before any awaits: the in-app ExoPlayer platform
    // view is used on every platform (phones, tablets, Android TV / Fire TV).
    if (Platform.isAndroid) {
      await Permission.videos.request();
    }
    try {
      final exo = ExoPlayerController();
      _exo = exo;
      _exoSub = exo.events.listen(_onExoEvent);
      try {
        _fitMode = await FitModeStore.load();
        _swipeEnabled = await areSwipeGesturesEnabled();
      } catch (_) {
        // Persistence unavailable; keep the default fit.
      }
      // Push the saved subtitle appearance (size/color/background/outline +
      // cue delay) so native rendering matches Settings from frame one.
      try {
        await exo.setSubtitleStyle(await SubtitleStyle.load());
      } catch (_) {}
      if (mounted) setState(() {});
      await _openCurrent();
      // Save the original screen brightness so we can restore it on dispose.
      // On Android this is automatic (Window brightness reverts when the
      // activity closes); on iOS UIScreen.main.brightness persists within
      // the app so we must reset it.
      if (Platform.isIOS) {
        try {
          _iosOriginalBrightness = await exo.getBrightness();
        } catch (_) {}
      }
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
    // Track network sources (WebDAV / authenticated HTTP) so
    // resume-after-background force-reloads instead of just calling play()
    // on a dead reader.
    final uri = video.uri;
    _isNetworkSource =
        uri != null &&
        ((uri.startsWith('http://') || uri.startsWith('https://')) &&
            (video.httpHeaders.isNotEmpty || video.allowSelfSigned));
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
        resumeKey: _resumeKey,
        title: video.title,
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

  /// Transient IO errors worth retrying (network blips).
  static bool _isRetryableIoError(String code) =>
      code == 'error_code_io_unspecified' ||
      code == 'error_code_io_network_connection_failed' ||
      code == 'error_code_io_network_connection_timeout' ||
      code == 'error_code_timeout';

  /// Reopen the current video at [pos], resetting the retry counter on
  /// success so a later error starts fresh.
  Future<void> _reopenAt(Duration pos, Duration dur) async {
    final video = _current;
    try {
      await _exo?.open(
        video.path ?? '',
        uri: video.uri,
        subtitleUri: video.subtitleUri,
        startPositionMs: pos.inMilliseconds,
        httpHeaders: video.httpHeaders,
        allowSelfSigned: video.allowSelfSigned,
        resumeKey: _resumeKey,
        title: video.title,
      );
      _exo?.setFitMode(_fitMode);
      _ioRetries = 0;
    } catch (_) {
      // Reopen itself failed — the error surface will show it.
    }
  }

  Future<void> _clearResume() async {
    if (_inTests) return;
    final key = _resumeKey;
    if (key.isEmpty) return;
    await ResumeStore.clear(key);
    await ContinueWatchingStore.remove(key);
  }

  /// Reopens the current Jellyfin video through the server's transcoder
  /// (HLS, H.264/AAC) at the last known position. Runs at most once per
  /// video ([_transcodeRetried] is set before this is called); on any
  /// failure the original direct-play error is surfaced instead.
  /// IMPORTANT: [_error] must stay null while the HLS stream spins up —
  /// the video layer (the platform view) only stays mounted while
  /// `_error == null`, and unmounting it releases the player mid-open.
  Future<void> _tryTranscodeFallback(String directError) async {
    final pos = _position;
    VideoItem? fallback;
    try {
      fallback = await JellyfinClient().transcodeFallbackFor(_current);
    } catch (_) {}
    if (!mounted) return;
    if (fallback?.uri == null || !JellyfinClient.isTranscodeUri(fallback!.uri)) {
      setState(() => _error = directError);
      return;
    }
    final u = Uri.parse(fallback.uri!);
    _transcodeServerUrl = '${u.scheme}://${u.host}:${u.port}';
    setState(() {
      _current = fallback!;
      // Spinner shows while HLS buffers; keep _error null so the platform
      // view (and its player) survives the source swap.
      _buffering = true;
    });
    debugPrint(
        'jellyfin: switching to server transcode at ${pos.inMilliseconds}ms '
        'uri=${fallback.uri}');
    try {
      await _exo?.open(
        '',
        uri: fallback.uri,
        startPositionMs: pos.inMilliseconds,
        allowSelfSigned: fallback.allowSelfSigned,
        resumeKey: _resumeKey,
        title: fallback.title,
      );
      _exo?.setFitMode(_fitMode);
    } catch (_) {
      if (mounted) setState(() => _error = directError);
    }
  }

  /// Stops the server-side transcode job after a transcoded session ends so
  /// the Jellyfin host stops burning CPU on an unwatched stream.
  void _stopTranscodeJob() {
    final url = _transcodeServerUrl;
    if (!_transcodeActive || url == null || _inTests) return;
    _transcodeActive = false;
    // Fire-and-forget; a fresh client instance carries the same persisted
    // device id that tagged the job.
    unawaited(JellyfinClient().stopActiveEncoding(url));
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
      case 'UnsupportedDolbyVisionProfile5':
        return e.errorMessage?.isNotEmpty == true
            ? e.errorMessage!
            : 'This device cannot decode Dolby Vision Profile 5. Play the '
                  'HDR10 or SDR version of the file, or watch it on a Dolby '
                  'Vision-capable device.';
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
    _buffered = e.buffered;
    _buffering = e.buffering;
    _completed = e.ended;
    // Reset retry counter once playback is healthy (playing + no error).
    if (_playing && !_retrying) _ioRetries = 0;
    if (e.error != null && e.error!.isNotEmpty) {
      final code = e.error!;
      // Auto-retry on transient IO errors (network blip).
      if (_isRetryableIoError(code) &&
          _ioRetries < _maxIoRetries &&
          !_retrying) {
        _ioRetries++;
        _retrying = true;
        final pos = _position;
        final dur = _duration;
        debugPrint(
          'DREAM_RETRY IO error $code, attempt $_ioRetries/$_maxIoRetries, '
          'pos=${pos.inMilliseconds}ms',
        );
        // Brief delay then reopen at the saved position.
        Future.delayed(const Duration(seconds: 2), () {
          if (!mounted || _retrying != true) return;
          _retrying = false;
          _error = null;
          setState(() {});
          _reopenAt(pos, dur);
        });
        _error = 'Reconnecting\u2026 ($_ioRetries/$_maxIoRetries)';
        setState(() {});
        return;
      }
      final friendly = _friendlyError(e);
      // Jellyfin direct-play failed (undecodable codec, expired stream, …).
      // Ask the server to transcode once before giving up — the HLS output
      // (H.264/AAC) plays everywhere, including DV P5 on non-DV hardware.
      if (!_transcodeRetried &&
          _current.jellyfinItemId != null &&
          !JellyfinClient.isTranscodeUri(_current.uri)) {
        _transcodeRetried = true;
        _tryTranscodeFallback(friendly);
        return;
      }
      _error = friendly;
    }
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
      isHdr10Plus: e.isHdr10Plus,
      isHdr10: e.isHdr10,
    );
    if (e.videoWidth > 0 && e.videoHeight > 0) {
      _liveResolution = '${e.videoWidth}x${e.videoHeight}';
    }
    if (e.videoWidth > 0 ||
        e.durationMs > 0 ||
        (e.videoCodecs != null && e.videoCodecs!.isNotEmpty)) {
      _hadMedia = true;
    }
    if (e.audioMime != null || e.audioCodecs != null) {
      _liveAudioCodec = formatMedia3Audio(e.audioMime, e.audioCodecs);
      if (e.audioChannels > 0) _liveAudioChannelCount = e.audioChannels;
    }
    _liveAudioPassthrough = e.audioPassthrough;
    _audioTracks = e.audioTracks;
    _selectedAudioTrackIndex = e.selectedAudioTrack;

    // Resume bookmark: persist every ~5s while playing, and immediately when
    // playback pauses/stops. A finished video clears its bookmark (it ended,
    // so there is nothing left to resume).
    if (e.ended) {
      _clearResume();
    } else {
      final now = DateTime.now();
      if (_playing &&
          !_buffering &&
          !_dragging &&
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
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _saveResume(_position);
    }
    // Stop audio while the screen is locked / the app is backgrounded.
    // Android destroys the video surface while locked, so pausing keeps the
    // playhead stable; `_reopenAfterBackground` resumes it on unlock.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _exo?.pause();
    }
    if (state == AppLifecycleState.resumed) {
      _reopenAfterBackground();
    }
  }

  /// Media3 `Player.STATE_IDLE`: the native player lost its media (e.g. the
  /// platform view was recreated while the device was locked).
  static const int _nativeStateIdle = 1;

  /// After the device unlocks, verify the native player still has the media
  /// loaded. Android destroys the video surface while locked, and may recreate
  /// the whole platform view (a fresh ExoPlayer, reset to IDLE). If the media
  /// is gone, reopen from the saved resume position; otherwise just continue
  /// playing from where we paused on background.
  Future<void> _reopenAfterBackground() async {
    final exo = _exo;
    if (exo == null || _inTests) return;
    // Give the surface / platform view a moment to be recreated on resume.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || _exo != exo) return;
    var state = await exo.getState();
    if (!mounted) return;
    if (state == null) {
      // Platform view not attached yet; retry once before giving up.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      state = await exo.getState();
      if (!mounted || state == null) return;
    }
    // Guard on media having been loaded (and not already finished) so a freshly
    // opened screen or an ended movie isn't spuriously reopened.
    if (state.state == _nativeStateIdle && _hadMedia && !_completed) {
      // `open` autoplays and re-applies the saved resume position.
      await _openCurrent();
    } else if (_isNetworkSource && _hadMedia && !_completed) {
      // iOS kills TCP connections when the app is backgrounded. The engine
      // still reports paused (not IDLE) but the underlying reader (WebDAV
      // session) is dead and will buffer forever.
      // Force-reload with a fresh source to re-establish the connection.
      await _openCurrent();
    } else {
      // The media survived; we paused on background, so continue playing.
      await exo.play();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _swipeOverlayTimer?.cancel();
    _saveResume(_position);
    _stopTranscodeJob();
    // Restore system brightness so it doesn't stick after the player closes.
    if (Platform.isIOS && _iosOriginalBrightness >= 0) {
      _exo?.setBrightness(_iosOriginalBrightness);
    } else {
      _exo?.setBrightness(-1);
    }
    _exoSub?.cancel();
    _exo?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _playerFocusScopeNode.dispose();
    _playPauseFocusNode.dispose();
    super.dispose();
  }

  /// Reveals the controls (and restarts the auto-hide countdown).
  void _showControls() {
    if (!mounted) return;
    final wasVisible = _controlsVisible;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _restartHideTimer();
    if (_isTv && !wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsVisible) {
          _playPauseFocusNode.requestFocus();
        }
      });
    }
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    // Auto-hide on every platform (including TV) while playing — any remote
    // button press reveals the controls again.
    if (!_playing || _buffering || _dragging) return;
    _hideTimer = Timer(_autoHideAfter, () {
      if (mounted &&
          _controlsVisible &&
          _playing &&
          !_buffering &&
          !_dragging) {
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

  // ---- Swipe gesture (brightness / volume) ----

  void _onSwipeDragStart(DragStartDetails details) {
    if (!_swipeEnabled || _isTv) return;
    final w = MediaQuery.of(context).size.width;
    final x = details.globalPosition.dx;
    _swipeType = x < w / 2 ? _SwipeType.brightness : _SwipeType.volume;
    _swipeGestureActive = true;
    _swipeBase = 0;
    _swipeDragDelta = 0;
    _swipeCurrentValue = 0;
    _hideTimer?.cancel();
    setState(() => _controlsVisible = false);
    // Seed from the LIVE platform value so the swipe starts exactly where
    // the system is — never from a stale init-time snapshot.
    _syncSwipeBase();
  }

  /// Fetches the current brightness/volume from the platform and makes it the
  /// gesture's base value. Buffered deltas are applied as soon as it arrives.
  Future<void> _syncSwipeBase() async {
    final exo = _exo;
    if (exo == null || _swipeType == null || !_swipeGestureActive) return;
    try {
      final current = _swipeType == _SwipeType.brightness
          ? await exo.getBrightness()
          : await exo.getSystemVolume();
      if (!mounted || !_swipeGestureActive) return;
      setState(() {
        _swipeBase = current.clamp(0.0, 1.0);
        _applySwipeValue();
      });
    } catch (_) {
      // Platform read failed; fall back to applying buffered deltas from 0.
      if (mounted) setState(_applySwipeValue);
    }
  }

  /// Computes base + accumulated delta, updates the overlay, and pushes the
  /// result to the platform.
  void _applySwipeValue() {
    final next = (_swipeBase + _swipeDragDelta).clamp(0.0, 1.0);
    _swipeCurrentValue = next;
    if (_swipeType == _SwipeType.brightness) {
      _exo?.setBrightness(next);
    } else if (_swipeType == _SwipeType.volume) {
      _exo?.setSystemVolume(next);
    }
  }

  void _onSwipeDragUpdate(DragUpdateDetails details) {
    if (_swipeType == null || !_swipeGestureActive) return;
    _swipeDragDelta +=
        -details.primaryDelta! / (MediaQuery.of(context).size.height * 0.7);
    setState(_applySwipeValue);
  }

  // MARK: Horizontal-swipe seek with frame preview

  void _onSeekDragStart(DragStartDetails details) {
    if (!_swipeEnabled || _isTv) return;
    final dur = _duration.inMilliseconds;
    if (dur <= 0) return;
    setState(() {
      _seekPreviewActive = true;
      _seekBaseMs = _position.inMilliseconds.clamp(0, dur);
      _seekDragPx = 0;
      _seekTargetMs = _seekBaseMs;
    });
    _hideTimer?.cancel();
  }

  void _onSeekDragUpdate(DragUpdateDetails details) {
    if (!_seekPreviewActive) return;
    final w = MediaQuery.of(context).size.width;
    final dur = _duration.inMilliseconds;
    if (dur <= 0 || w <= 0) return;
    _seekDragPx += details.primaryDelta!;
    final seconds = (_seekDragPx / w) * _seekDragSpanSeconds;
    setState(() {
      _seekTargetMs =
          (_seekBaseMs + seconds * 1000).round().clamp(0, dur);
    });
  }

  void _onSeekDragEnd(DragEndDetails details) {
    if (!_seekPreviewActive) return;
    final targetMs = _seekTargetMs;
    setState(() => _seekPreviewActive = false);
    if ((targetMs - _position.inMilliseconds).abs() >= 500) {
      _exo?.seekTo(Duration(milliseconds: targetMs));
    }
    _restartHideTimer();
  }

  void _onSwipeDragEnd(DragEndDetails details) {
    if (_swipeType == null) return;
    // Keep [_swipeType] so the fading pill keeps its icon; only the
    // active flag stops further updates/platform pushes.
    _swipeGestureActive = false;
    _swipeOverlayTimer?.cancel();
    _swipeOverlayTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && !_swipeGestureActive) {
        setState(() => _swipeType = null);
      }
    });
    _restartHideTimer();
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
      final hasChannels =
          label.contains(channels) || label.contains(t.channels.toString());
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
                    return _tvListTile(
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
              _tvListTile(
                leading: Icon(
                  selected < 0
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected < 0 ? Colors.white : Colors.white54,
                ),
                title: const Text('Off', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(context).pop(-1),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final t = tracks[i];
                    final isSelected = t.index == selected;
                    return _tvListTile(
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
                    return _tvListTile(
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
    final target = Duration(milliseconds: value.round());
    _exo?.seekTo(target);
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

  /// Horizontal-swipe seek preview: timestamp pill showing where the finger
  /// will land (and by how much it moves).
  Widget _buildSeekPreview() {
    final target = Duration(milliseconds: _seekTargetMs);
    final deltaMs = _seekTargetMs - _seekBaseMs;
    final sign = deltaMs >= 0 ? '+' : '−';
    final delta = Duration(milliseconds: deltaMs.abs());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatDuration(target),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '$sign${_formatDuration(delta)}',
            style: TextStyle(
              color: deltaMs >= 0 ? Colors.lightGreenAccent : Colors.orangeAccent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
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

  Color get _passthroughColor => const Color(0xFFFFB74D);

  Color get _infoColor => const Color(0xFF90A4AE);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final video = _current;
    _isTv = isTvMode(context);

    final total = _duration;
    final maxMs = total.inMilliseconds > 0
        ? total.inMilliseconds.toDouble()
        : video.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final sliderValue = _dragging
        ? _dragValue
        : _position.inMilliseconds.toDouble().clamp(0, maxMs).toDouble();

    final hdrChip = FormatChip(label: _effectiveHdr.label, color: _hdrColor);
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
    final audioChip = audioChipLabel != null || _liveAudioPassthrough
        ? FormatChip(
            label: _liveAudioPassthrough
                ? '${audioChipLabel ?? "Audio"} · Passthrough'
                : audioChipLabel!,
            color: _liveAudioPassthrough ? _passthroughColor : _audioColor,
          )
        : null;
    final resolutionChip = (_liveResolution ?? video.resolution) != null
        ? FormatChip(
            label: _liveResolution ?? video.resolution!,
            color: _infoColor,
          )
        : null;
    final chips = [hdrChip, ?videoChip, ?audioChip, ?resolutionChip];

    // IMPORTANT: keep the widget-tree shape stable across casting state.
    // The platform view must ALWAYS be mounted at the same slot — swapping
    // it for a placeholder (or moving it under a conditional branch)
    // recreates the native view, releases ExoPlayer mid-open and breaks
    // "resume on this device". The casting overlay is an extra sibling
    // stacked ON TOP; adding/removing it doesn't touch the player's slot.
    final videoLayer = Stack(
      fit: StackFit.expand,
      children: [
        _exo != null && _error == null
            ? ExoPlayerView(controller: _exo! as ExoPlayerController)
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
              ),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: FocusScope(
        node: _playerFocusScopeNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          final okKey =
              key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA;
          final mediaPlayKey =
              key == LogicalKeyboardKey.mediaPlay ||
              key == LogicalKeyboardKey.mediaPause ||
              key == LogicalKeyboardKey.mediaPlayPause;

          if (_isTv && _controlsVisible) {
            // Just Player style: when controls are visible on TV, let the
            // normal Android focus system handle arrow keys for button
            // navigation. Only intercept select/play-pause/seek keys.
            if (mediaPlayKey) {
              // The remote's dedicated play/pause button must always toggle
              // playback — media keys do NOT activate the focused button
              // (InkWell only activates on select/enter/DPAD_CENTER), so
              // deferring here would make a second press a dead no-op.
              _togglePlayPause();
              _showControls();
              return KeyEventResult.handled;
            } else if (okKey) {
              if (FocusManager.instance.primaryFocus == _playerFocusScopeNode) {
                _togglePlayPause();
                _showControls();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored; // activate the focused control
            } else if (key == LogicalKeyboardKey.mediaRewind) {
              _seekBy(const Duration(seconds: -10));
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.mediaFastForward) {
              _seekBy(const Duration(seconds: 10));
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowRight ||
                key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown) {
              return KeyEventResult.ignored; // D-pad focus navigation
            } else if (key == LogicalKeyboardKey.goBack ||
                key == LogicalKeyboardKey.escape) {
              setState(() => _controlsVisible = false);
              _restartHideTimer();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }

          // TV with hidden controls: Just Player style — direct key handling
          // for seek/play-pause, any other key shows controls.
          if (_isTv && !_controlsVisible) {
            if (okKey || mediaPlayKey) {
              _togglePlayPause();
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.mediaRewind) {
              _seekBy(const Duration(seconds: -10));
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.mediaFastForward) {
              _seekBy(const Duration(seconds: 10));
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.arrowLeft) {
              _seekBy(const Duration(seconds: -10));
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.arrowRight) {
              _seekBy(const Duration(seconds: 10));
              _showControls();
              return KeyEventResult.handled;
            } else if (key == LogicalKeyboardKey.goBack ||
                key == LogicalKeyboardKey.escape) {
              return KeyEventResult.ignored; // exit player
            } else {
              _showControls();
              return KeyEventResult.handled;
            }
          } else if (mediaPlayKey) {
            // Media keys toggle playback even off the TV path — tvOS runs the
            // phone UI branches (_isTv false), and the Siri Remote's
            // play/pause button arrives here. A Bluetooth-keyboard media key
            // on phones benefits too.
            _togglePlayPause();
            _showControls();
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown) {
            _showControls();
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.escape) {
            // BACK on TV: hide the controls first if they're visible and
            // playing, then exit on a second press.
            if (_controlsVisible) {
              setState(() => _controlsVisible = false);
              _restartHideTimer();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          } else if (!_controlsVisible) {
            // Any other key while the controls are hidden reveals them
            // (Just Player behavior).
            _showControls();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            Positioned.fill(child: videoLayer),
            // Full-screen tap + swipe catcher on top of the (Android platform)
            // video layer. Hybrid-composition platform views can swallow
            // touches, so catching gestures one layer up guarantees they always
            // reach the app. Vertical drags adjust brightness (left half) or
            // volume (right half); taps toggle controls.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _onScreenTap,
                onVerticalDragStart: _onSwipeDragStart,
                onVerticalDragUpdate: _onSwipeDragUpdate,
                onVerticalDragEnd: _onSwipeDragEnd,
                onHorizontalDragStart: _onSeekDragStart,
                onHorizontalDragUpdate: _onSeekDragUpdate,
                onHorizontalDragEnd: _onSeekDragEnd,
                child: const SizedBox.expand(),
              ),
            ),
            // Horizontal-swipe seek preview (timestamp + frame thumbnail).
            if (_seekPreviewActive)
              Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: Center(child: _buildSeekPreview()),
              ),
            // Swipe-gesture feedback overlay (brightness / volume).
            if (_swipeType != null || _swipeOverlayTimer?.isActive == true)
              Center(
                child: AnimatedOpacity(
                  opacity: _swipeType != null ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    width: 140,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _swipeType == _SwipeType.brightness
                              ? Icons.brightness_6
                              : Icons.volume_up,
                          color: Colors.white,
                          size: 28,
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _swipeCurrentValue,
                            minHeight: 4,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation(
                              Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${(_swipeCurrentValue * 100).round()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
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
                            _TvControlButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.arrow_back),
                              color: Colors.white,
                              onFocusChange: (_) => _showControls(),
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
                        _TvControlButton(
                          onPressed: !_backendReady
                              ? null
                              : () => _seekBy(const Duration(seconds: -10)),
                          iconSize: 40,
                          icon: const Icon(Icons.replay_10),
                          color: Colors.white,
                          onFocusChange: (_) => _showControls(),
                        ),
                        const SizedBox(width: 8),
                        _TvControlButton(
                          focusNode: _playPauseFocusNode,
                          onPressed: !_backendReady ? null : _togglePlayPause,
                          iconSize: 72,
                          autofocus: true,
                          alwaysShowRing: !_isTv,
                          icon: Icon(
                            _completed
                                ? Icons.replay
                                : _playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                          ),
                          color: Colors.white,
                          onFocusChange: (_) => _showControls(),
                        ),
                        const SizedBox(width: 8),
                        _TvControlButton(
                          onPressed: !_backendReady
                              ? null
                              : () => _seekBy(const Duration(seconds: 10)),
                          iconSize: 40,
                          icon: const Icon(Icons.forward_10),
                          color: Colors.white,
                          onFocusChange: (_) => _showControls(),
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
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _formatDuration(
                                      _dragging
                                          ? Duration(
                                              milliseconds: _dragValue.round(),
                                            )
                                          : _position,
                                    ),
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  Text(
                                    _formatDuration(total),
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                              _BufferedSeekBar(
                                value: sliderValue,
                                max: maxMs,
                                bufferedMs: _buffered.inMilliseconds
                                    .toDouble()
                                    .clamp(0, maxMs),
                                onChangeStart: _onSeekStart,
                                onChanged: _onSeekUpdate,
                                onChangeEnd: _onSeekEnd,
                                onFocusChange: (_) => _showControls(),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  _TvControlButton(
                                    onPressed: _openAudioTrackSheet,
                                    icon: const Icon(Icons.graphic_eq),
                                    color: Colors.white,
                                    onFocusChange: (_) => _showControls(),
                                  ),
                                  _TvControlButton(
                                    onPressed: _openSubtitleSheet,
                                    icon: Icon(
                                      _subtitleOn
                                          ? Icons.closed_caption
                                          : Icons.closed_caption_off,
                                    ),
                                    color: _subtitleOn
                                        ? Colors.white
                                        : Colors.white54,
                                    onFocusChange: (_) => _showControls(),
                                  ),
                                  _TvControlButton(
                                    onPressed: _openFitModeSheet,
                                    icon: const Icon(Icons.tune),
                                    color: Colors.white,
                                    onFocusChange: (_) => _showControls(),
                                  ),
                                  if (!_isTv)
                                    _TvControlButton(
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
      ),
    );
  }
}

/// Custom seekbar with a gray buffer-progress indicator behind the active
/// progress. Flutter's [Slider] has no built-in buffer visualization, so this
/// draws three layers: background track (dark), buffer fill (medium gray),
/// progress fill (white), and a thumb circle.
class _BufferedSeekBar extends StatefulWidget {
  const _BufferedSeekBar({
    required this.value,
    required this.max,
    required this.bufferedMs,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
    this.onFocusChange,
  });

  final double value;
  final double max;
  final double bufferedMs;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<_BufferedSeekBar> createState() => _BufferedSeekBarState();
}

class _BufferedSeekBarState extends State<_BufferedSeekBar> {
  static const double _trackHeight = 4;
  static const double _thumbRadius = 7;
  static const double _touchHeight = 36; // total tappable area
  bool _dragging = false;
  double _dragValue = 0;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double get _clampedMax => widget.max > 0 ? widget.max : 1;

  double _fractionFromOffset(double dx, double width) {
    final fraction = (dx / width).clamp(0.0, 1.0);
    return fraction * _clampedMax;
  }

  void _stepSeek(double deltaMs) {
    final maxVal = _clampedMax;
    final current = _dragging ? _dragValue : widget.value;
    final target = (current + deltaMs).clamp(0.0, maxVal);
    widget.onChangeStart?.call(target);
    widget.onChanged?.call(target);
    widget.onChangeEnd?.call(target);
  }

  @override
  Widget build(BuildContext context) {
    final currentMs = _dragging ? _dragValue : widget.value;
    final positionFraction = (currentMs / _clampedMax).clamp(0.0, 1.0);
    final bufferFraction = (widget.bufferedMs / _clampedMax).clamp(0.0, 1.0);

    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) {
        if (focused) widget.onFocusChange?.call(focused);
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowLeft) {
            _stepSeek(-10000);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.arrowRight) {
            _stepSeek(10000);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: _focusNode.hasFocus
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border.all(
            color: _focusNode.hasFocus
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: GestureDetector(
          onHorizontalDragStart: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final ms = _fractionFromOffset(
              box.globalToLocal(details.globalPosition).dx,
              box.size.width,
            );
            setState(() {
              _dragging = true;
              _dragValue = ms;
            });
            widget.onChangeStart?.call(ms);
          },
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final ms = _fractionFromOffset(
              box.globalToLocal(details.globalPosition).dx,
              box.size.width,
            );
            setState(() => _dragValue = ms);
            widget.onChanged?.call(ms);
          },
          onHorizontalDragEnd: (_) {
            final ms = _dragValue;
            setState(() => _dragging = false);
            widget.onChangeEnd?.call(ms);
          },
          onTapUp: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final ms = _fractionFromOffset(
              box.globalToLocal(details.globalPosition).dx,
              box.size.width,
            );
            widget.onChangeStart?.call(ms);
            widget.onChanged?.call(ms);
            widget.onChangeEnd?.call(ms);
          },
          child: SizedBox(
            height: _touchHeight,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final thumbX = positionFraction * width;
                    final bufferX = bufferFraction * width;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Background track
                        Positioned(
                          top: (_touchHeight - _trackHeight) / 2,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: _trackHeight,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // Buffer fill
                        Positioned(
                          top: (_touchHeight - _trackHeight) / 2,
                          left: 0,
                          child: Container(
                            width: bufferX.clamp(0, width),
                            height: _trackHeight,
                            decoration: BoxDecoration(
                              color: Colors.white54,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // Progress fill
                        Positioned(
                          top: (_touchHeight - _trackHeight) / 2,
                          left: 0,
                          child: Container(
                            width: thumbX.clamp(0, width),
                            height: _trackHeight,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // Thumb
                        Positioned(
                          top: (_touchHeight - _thumbRadius * 2) / 2,
                          left: (thumbX - _thumbRadius).clamp(
                            -_thumbRadius,
                            width - _thumbRadius,
                          ),
                          child: Container(
                            width: _thumbRadius * 2,
                            height: _thumbRadius * 2,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _tvListTile({
  required Widget title,
  Widget? leading,
  Widget? subtitle,
  required VoidCallback onTap,
}) {
  return Focus(
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.gameButtonA) {
          onTap();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    },
    child: Builder(
      builder: (context) {
        final focused = Focus.of(context).hasFocus;
        final primary = Theme.of(context).colorScheme.primary;
        return AnimatedScale(
          scale: focused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: focused
                  ? primary.withValues(alpha: 0.3)
                  : Colors.transparent,
              border: Border.all(
                color: focused ? primary : Colors.transparent,
                width: 3,
              ),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: primary.withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: ListTile(
              leading: leading,
              title: title,
              subtitle: subtitle,
              onTap: onTap,
            ),
          ),
        );
      },
    ),
  );
}

class _TvControlButton extends StatefulWidget {
  const _TvControlButton({
    required this.icon,
    required this.onPressed,
    this.focusNode,
    this.iconSize = 28,
    this.color,
    this.autofocus = false,
    this.onFocusChange,
    this.alwaysShowRing = false,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final double iconSize;
  final Color? color;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;

  /// When true the button always renders its ring highlight (border + glow),
  /// even without keyboard/remote focus. Used for the center play/pause button
  /// on touch devices so the ring is visible without a D-pad.
  final bool alwaysShowRing;

  @override
  State<_TvControlButton> createState() => _TvControlButtonState();
}

class _TvControlButtonState extends State<_TvControlButton> {
  late final FocusNode _node = widget.focusNode ?? FocusNode();

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;

    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: enabled,
      onFocusChange: (focused) {
        if (focused) {
          widget.onFocusChange?.call(focused);
        }
        if (mounted) setState(() {});
      },
      onKeyEvent: (node, event) {
        if (!enabled) return KeyEventResult.ignored;
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA) {
            widget.onPressed?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = (_node.hasFocus || widget.alwaysShowRing) && enabled;
          final primary = Theme.of(context).colorScheme.primary;

          return AnimatedScale(
            scale: focused ? 1.12 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: focused
                    ? primary.withValues(alpha: 0.35)
                    : Colors.transparent,
                border: Border.all(
                  color: focused ? primary : Colors.transparent,
                  width: 3,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.35),
                          blurRadius: 9,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: IconButton(
                onPressed: widget.onPressed,
                iconSize: widget.iconSize,
                icon: widget.icon,
                color: widget.color ?? Colors.white,
              ),
            ),
          );
        },
      ),
    );
  }
}
