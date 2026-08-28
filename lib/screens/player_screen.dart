import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/exo_player.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/playback_modes.dart';
import '../services/auto_play_store.dart';
import '../services/decoder_mode.dart';
import '../services/smb_client.dart';
import '../services/resume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/tmdb_client.dart';
import '../services/simkl_client.dart';
import '../services/watched_store.dart';
import '../services/sidecar_subtitle_service.dart';
import '../services/subtitle_style.dart';
import '../services/downloaded_subtitles_store.dart';
import '../services/opensubtitles_client.dart';
import '../services/subtitle_languages.dart';
import '../services/subtitle_prefs.dart';
import 'subtitle_settings_screen.dart';
import 'opensubtitles_sheet.dart';
import '../utils/codec_info.dart';
import '../utils/tv_helper.dart';
import '../widgets/format_chip.dart';

/// Whether the app is running under `flutter test`.
const bool _inTests = bool.fromEnvironment('FLUTTER_TEST');

enum _SwipeType { brightness, volume }

enum _PanAxis { horizontal, vertical }

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
  String? _error;

  bool _dragging = false;
  double _dragValue = 0;

  /// Auto-retry on transient IO errors (network blip).
  int _ioRetries = 0;
  static const int _maxIoRetries = 5;
  bool _retrying = false;

  /// Jellyfin transcode fallback: tried at most once per video, and only
  /// while the current URI is still a direct stream.
  bool _transcodeRetried = false;
  bool _transcodeActive = false;
  String? _transcodeServerUrl;

  String? _liveVideoCodec;
  String? _liveVideoCodecRaw;
  String? _liveVideoMimeRaw;
  String? _liveAudioCodec;
  int? _liveAudioChannelCount;
  String? _liveAudioLanguage;
  bool _liveAudioPassthrough = false;
  String _liveSpatial = '';
  int _liveBass = 0;
  String? _liveResolution;
  HdrFormat _liveHdr = HdrFormat.sdr;
  String? _liveDecoderName;
  bool? _isHwDecoder;
  /// Source URI scheme, used to label the source in the ⓘ info sheet
  /// (Local / SMB / WebDAV / FTP / HTTP / etc.).
  String _liveSourceScheme = '';
  List<ExoAudioTrack> _audioTracks = const [];
  int _selectedAudioTrackIndex = -1;

  bool _subtitleOn = false;
  List<ExoSubtitleTrack> _subtitleTracks = const [];

  /// Container chapters (MKV, local files) — populated from the native event
  /// once parsed. Empty hides the chapters button.
  List<ExoChapter> _chapters = const [];

  /// Guard so an ended video is marked watched exactly once per session.
  bool _markedWatched = false;
  bool _autoPlayFired = false;
  int _selectedSubtitleTrack = -1;
  bool _autoFetchFired = false;
  bool _readingAutoSelected = false;

  /// True while the activity floats in picture-in-picture mode: every overlay
  /// (bars, transport pill, gestures) hides so the pip window shows only the
  /// video.
  bool _inPip = false;

  /// Format chips stay visible under the title while controls are showing.
  /// Pip hides them (floating window = video only). The ⓘ top-bar button
  /// opens a richer info sheet for the full decoder / network details.

  VideoFitMode _fitMode = VideoFitMode.fit;

  /// Persisted playback speed, re-applied on every (re)open.
  double _playbackSpeed = 1.0;

  /// Volume boost (1.0–3.0) and Night Mode — persisted and re-applied on open.
  double _audioBoost = 1.0;
  bool _nightMode = false;

  int _subtitleDelayMs = 0;
  bool _autoPlayNext = false;

  /// Repeat + shuffle (Phase 2). Persisted via [PlaybackModesStore]; repeat
  /// one loops the current file, repeat all loops the folder (with shuffle
  /// randomizing the order).
  LoopMode _repeat = LoopMode.off;
  bool _shuffle = false;

  /// A-B repeat loop points (milliseconds), or null when unset. Both set →
  /// the position ticker seeks back to A whenever playback passes B.
  int? _abA;
  int? _abB;

  /// Manual A/V sync (Android): audio shifted relative to video, ±5 s.
  /// Positive = audio later. Session-only (not persisted).
  int _audioDelayMs = 0;

  /// Sleep timer: absolute deadline for minute-based timers, a flag for
  /// "end of current video", and the periodic ticker driving the countdown.
  DateTime? _sleepUntil;
  bool _sleepAtEnd = false;
  Timer? _sleepTicker;
  DecoderMode _decoderMode = DecoderMode.auto;

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

  /// Pinch-to-zoom crop scale (1.0 = fit, up to 3.0). Transient per session.
  double _zoomScale = 1.0;

  /// Base scale at the start of the current pinch gesture.
  double _pinchBaseScale = 1.0;

  /// Touch lock: when on, taps/swipes/pinch are ignored (accidental-touch
  /// guard). Toggled from the bottom bar; auto-cleared on player close.
  bool _touchLocked = false;

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
      // Background-playback notification needs POST_NOTIFICATIONS on 13+.
      // Fire-and-forget: denial only hides the notification, playback and
      // the foreground service keep working.
      unawaited(Permission.notification.request());
    }
    try {
      final exo = ExoPlayerController();
      _exo = exo;
      _exoSub = exo.events.listen(_onExoEvent);
      try {
        _fitMode = await FitModeStore.load();
        _playbackSpeed = await PlaybackSpeedStore.load();
        _audioBoost = await PlaybackBoostStore.load();
        _nightMode = await NightModeStore.load();
        _swipeEnabled = await areSwipeGesturesEnabled();
        _subtitleDelayMs = (await SubtitleStyle.load()).delayMs;
        _autoPlayNext = await isAutoPlayNextEnabled();
        _repeat = await PlaybackModesStore.loadRepeat();
        _shuffle = await PlaybackModesStore.loadShuffle();
        _decoderMode = await DecoderModeStore.load();
        // Repeat one loops natively on Android (no ended event); iOS handles
        // the restart from the Dart ended-handler.
        unawaited(exo.setRepeatMode(_repeat.index));
      } catch (_) {
        // Persistence unavailable; keep the default fit.
      }
      // Push the saved subtitle appearance (size/color/background/outline +
      // cue delay) so native rendering matches Settings from frame one.
      try {
        await exo.setSubtitleStyle(await SubtitleStyle.load());
      } catch (_) {}
      try {
        await exo.setAudioBoost(_audioBoost);
        await exo.setNightMode(_nightMode);
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
    _markedWatched = false;
    _autoPlayFired = false;
    _autoFetchFired = false;
    _readingAutoSelected = false;
    // A-B loop points are per-video.
    _abA = null;
    _abB = null;
    // Seed chapters from the VideoItem (e.g. Jellyfin `MediaSources[].Chapters`);
    // native MKV parsing (`e.chapters`) will override once available.
    _chapters = video.chapters
        .map((c) => ExoChapter(title: c.title, startMs: c.startMs, endMs: c.endMs))
        .toList();
    if (_chapters.isNotEmpty && mounted) setState(() {});
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
    final externalSubs = await _resolveExternalSubtitles(video);
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
        externalSubtitles: externalSubs,
      );
      // Re-apply the user's persisted fit mode + speed + audio filters.
      _exo?.setFitMode(_fitMode);
      _exo?.setSpeed(_playbackSpeed);
      _exo?.setAudioBoost(_audioBoost);
      _exo?.setNightMode(_nightMode);
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

  /// Resolves the external subtitle track list for the current video.
  ///
  /// **Priority: sidecar files in the same folder > server-supplied
  /// external subs (Jellyfin DeliveryUrls) > embedded container tracks.**
  /// If the source already provides external subs (e.g. the WebDAV / SMB /
  /// FTP browser screens), they're used as-is. Otherwise, when the video
  /// is opened from a network share that supports directory listing
  /// (Android only), the parent folder is probed for matching `.srt` /
  /// `.ass` / `.vtt` / `.sub` / `.ttml` / `.smi` / `.mpl2` files and the
  /// best match is auto-selected (with the rest still reachable in the CC
  /// sheet).
  ///
  /// Falls through to the existing external list when no sidecars are
  /// found; the player then falls back to the container's embedded track.
  /// Errors are swallowed (sidecar discovery is best-effort and must never
  /// block playback).
  Future<List<VideoExternalSub>> _resolveExternalSubtitles(VideoItem video) async {
    final existing = video.externalSubtitles;
    List<VideoExternalSub> resolved;
    // Source already attached its own external subs (Jellyfin, folder
    // bookmark, etc.) — use them as-is, but enforce the
    // "external > embedded always" priority by promoting the first
    // external to default when none is flagged. Without this, the
    // engine falls back to the container's embedded PGS/ASS track on
    // any media server that didn't mark an external as default
    // (Jellyfin only does so for explicitly-flagged sidecars; most DLNA
    // servers never fill the field).
    if (existing.isNotEmpty) {
      resolved = promoteFirstExternalAsDefault(existing);
    } else if (_inTests) {
      return const [];
    } else {
      final sidecars = await SidecarSubtitleService.instance.find(video);
      // `SidecarSubtitleService.find` already marks the first match
      // `isDefault: true`, so no promotion needed here.
      resolved = sidecars;
    }
    if (_inTests) return resolved;
    // Nova-parity: copy any remotely-streamed sidecar (SMB/FTP/HTTP external
    // subs) to a local cache file so the engine reads it locally rather than
    // re-streaming the remote URL (AVP issue #1605).
    return SidecarSubtitleService.instance.ensureLocal(video, resolved);
  }

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
    final externalSubs = await _resolveExternalSubtitles(video);
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
        externalSubtitles: externalSubs,
      );
      _exo?.setFitMode(_fitMode);
      _exo?.setSpeed(_playbackSpeed);
      _exo?.setAudioBoost(_audioBoost);
      _exo?.setNightMode(_nightMode);
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

  /// Fire-and-forget: push a finished video to SIMKL history.
  void _pushSimklHistory(String key) {
    final client = SimklClient();
    if (!client.isConfigured) return;
    final meta = TmdService.instance.metaFor(key);
    if (meta == null || meta.movie.id == 0) return;
    final parsed = ParsedFileName.parse(_current.title);
    final item = SimklWatchItem(
      tmdbId: meta.movie.id,
      isTv: meta.movie.kind == TmdKind.tv,
      season: parsed.isEpisode ? parsed.season : null,
      episode: parsed.isEpisode ? parsed.episode : null,
    );
    unawaited(client.addToHistoryOne(item).catchError((_) {}));
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
    if (fallback?.uri == null ||
        !JellyfinClient.isTranscodeUri(fallback!.uri)) {
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
      // Marks the session as transcoded: the "Transcoding" badge shows and
      // dispose stops the server-side job (previously never set → leak).
      _transcodeActive = true;
    });
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
      _exo?.setAudioBoost(_audioBoost);
      _exo?.setNightMode(_nightMode);
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
      case 'error_code_io_unspecified':
        return 'Connection interrupted while playing. '
            'The file may have been moved, the network may be unstable, or '
            'the server may have timed out. Try playing the file again, or '
            'check the connection to the source.';
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
      case 'error_code_unsupported_audio':
        return 'The audio format is not supported on this device. '
            'Try a different audio track if the file has multiple, '
            'or play a version with a supported audio codec (AAC, AC3, E-AC3, DTS, FLAC).';
      case 'error_code_unsupported_video':
        return 'The video format is not supported on this device. '
            'Common unsupported formats: MPEG-2, VC-1, H.265 on older devices. '
            'Try a re-encoded version (H.264/AVC or hardware-supported HEVC).';
      case 'error_code_unsupported_format':
      case 'error_code_unsupported_type':
        return 'This file format is not supported. The container (e.g. .m2ts, .ts, .vob) '
            'may use codecs this device cannot decode. Try a remuxed or re-encoded version.';
      case 'error_code_undecodable':
        return 'The file could not be decoded. It may be corrupt, use an '
            'unsupported codec, or have DRM protection.';
      case 'error_code_decoder_init_failed':
      case 'error_code_decoder_query_failed':
        return 'Hardware decoder initialization failed. '
            'Try a file with a codec supported by this device\'s hardware '
            '(H.264, HEVC, VP9).';
      case 'error_code_audio_track_init_failed':
        return 'Audio output could not be initialized. '
            'Check if another app is using the audio system, or try a different audio track.';
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
      // Auto-retry on transient IO errors (network blip). Uses exponential
      // backoff: 2s, 4s, 8s, 16s, 32s — gives a flaky NAS / Wi-Fi enough
      // time to recover before we give up.
      if (_isRetryableIoError(code) &&
          _ioRetries < _maxIoRetries &&
          !_retrying) {
        _ioRetries++;
        _retrying = true;
        final pos = _position;
        final dur = _duration;
        final delay = Duration(seconds: 1 << _ioRetries); // 2, 4, 8, 16, 32
        _error = 'Reconnecting\u2026 ($_ioRetries/$_maxIoRetries)';
        setState(() {});
        Future.delayed(delay, () {
          if (!mounted || _retrying != true) return;
          _retrying = false;
          _error = null;
          setState(() {});
          _reopenAt(pos, dur);
        });
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
    if (e.videoMime != null && e.videoMime!.isNotEmpty) {
      _liveVideoMimeRaw = e.videoMime;
    }
    _liveHdr = detectMedia3HdrFormat(
      colorTransfer: e.colorTransfer,
      videoCodecs: _liveVideoCodecRaw,
      videoMime: _liveVideoMimeRaw,
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
      // Derive the selected track's language for the on-screen chip.
      final sel = e.selectedAudioTrack;
      if (sel >= 0 && sel < e.audioTracks.length) {
        final lang = e.audioTracks[sel].language;
        _liveAudioLanguage = (lang != null && lang.isNotEmpty) ? lang : null;
      } else {
        _liveAudioLanguage = null;
      }
    }
    _liveAudioPassthrough = e.audioPassthrough;
    if (e.videoDecoderName != null && e.videoDecoderName!.isNotEmpty) {
      _liveDecoderName = e.videoDecoderName;
    }
    if (e.isHwDecoder != null) _isHwDecoder = e.isHwDecoder;
    _liveSpatial = e.spatialAudio;
    _liveBass = e.bassBoost;
    _liveSourceScheme = e.sourceScheme;
    if (e.inPip != _inPip) {
      _inPip = e.inPip;
      if (_inPip) {
        // Floating window shows ONLY the video: drop every overlay. The
        // chip row lives inside the controls overlay, so hiding controls
        // hides the chips automatically.
        _hideTimer?.cancel();
        _controlsVisible = false;
      } else {
        // Expanding back restores the controls.
        _controlsVisible = true;
        _restartHideTimer();
      }
    }
    _audioTracks = e.audioTracks;
    _selectedAudioTrackIndex = e.selectedAudioTrack;
    if (e.chapters.isNotEmpty) _chapters = e.chapters;

    // Watched state: a video that played to the end is marked watched so
    // library lists can show it (Phase 2). Once per session per video.
    if (e.ended && !_markedWatched) {
      _markedWatched = true;
      final key = _resumeKey;
      if (!_inTests && key.isNotEmpty) WatchedStore.set(key, true);
      if (!_inTests) _pushSimklHistory(key);
    }

    // A-B repeat: loop back to A whenever playback passes B. Only while
    // actually playing (not while paused/dragging the scrubber).
    if (_abA != null &&
        _abB != null &&
        e.playing &&
        !_dragging &&
        e.position >= Duration(milliseconds: _abB!)) {
      _exo?.seekTo(Duration(milliseconds: _abA!));
      _position = Duration(milliseconds: _abA!);
    }

    // End-of-media routing, in priority order:
    //   sleep "end of video" → stay ended (no next),
    //   repeat one           → restart this file,
    //   repeat all / shuffle → next in folder (wrapping),
    //   auto-play next       → existing sequential behaviour.
    if (e.ended && !_inTests) {
      if (_sleepAtEnd) {
        _sleepAtEnd = false;
      } else if (_repeat == LoopMode.one) {
        _restartForRepeatOne();
      } else if (!_autoPlayFired) {
        _autoPlayFired = true;
        if (_repeat == LoopMode.all || _shuffle) {
          _advancePlayback(wrap: _repeat == LoopMode.all);
        } else {
          _maybeAutoPlayNext();
        }
      }
    }

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
    // Nova-style: reading language auto-select (pick track matching pref when nothing selected).
    if (!_readingAutoSelected && e.subtitleTracks.isNotEmpty && e.selectedSubtitleTrack < 0) {
      _readingAutoSelected = true;
      Future.microtask(() => _maybeAutoSelectReading(e.subtitleTracks));
    }
    // Auto-fetch online subtitles once per video when no tracks exist (Nova-style).
    if (!_autoFetchFired && e.state == _nativeStateReady && _subtitleTracks.isEmpty && e.subtitleTracks.isEmpty) {
      // Fire-and-forget; handle async outside setState.
      Future.microtask(() => _maybeAutoFetchSubs());
    }
    if (mounted) setState(() {});
  }

  Future<void> _maybeAutoPlayNext() async {
    try {
      if (!await isAutoPlayNextEnabled()) return;
    } catch (_) {
      return;
    }
    final next = await _pickNextVideo(wrap: false);
    if (next == null || !mounted) return;
    // Small grace period so the user sees the ended state and can cancel
    // via back. If the screen is popped in that window, `mounted` is false.
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    // Verify we're still in the ended state (user didn't seek/replay).
    if (!_completed) return;
    _current = next;
    if (mounted) setState(() => _error = null);
    await _openCurrent();
  }

  /// Repeat one: replay the current file from the start. Android loops
  /// natively via `setRepeatMode` (no ended event ever fires); this Dart
  /// path covers iOS (AetherEngine parks in `.ended`, and play-after-ended
  /// reloads the session) and acts as the fallback everywhere.
  void _restartForRepeatOne() {
    _exo?.seekTo(Duration.zero);
    _exo?.play();
  }

  /// Arms (or cancels) the sleep timer. A null [duration] with [endOfVideo]
  /// set arms the "stop after this video" variant; both null cancels.
  void _setSleepTimer({Duration? duration, bool endOfVideo = false}) {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepUntil = null;
    _sleepAtEnd = false;
    if (endOfVideo) {
      _sleepAtEnd = true;
    } else if (duration != null && duration > Duration.zero) {
      _sleepUntil = DateTime.now().add(duration);
      _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final left = _sleepUntil?.difference(DateTime.now());
        if (left == null || left <= Duration.zero) {
          _fireSleepTimer();
        } else if (_sleepUntil != null) {
          setState(() {}); // refresh the countdown label
        }
      });
    }
    if (mounted) setState(() {});
  }

  void _fireSleepTimer() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepUntil = null;
    _sleepAtEnd = false;
    _exo?.pause();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sleep timer finished — playback paused'),
          duration: Duration(seconds: 3),
        ),
      );
      setState(() {});
    }
  }

  /// "12:34" remaining, or null when no minute-based timer is armed.
  String? get _sleepCountdown {
    final until = _sleepUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) return '0:00';
    final m = left.inMinutes;
    final s = left.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Repeat-all / shuffle advance: pick the next video from the same folder
  /// (wrapping at the end when repeating) and open it. A single-video folder
  /// loops the file itself.
  Future<void> _advancePlayback({required bool wrap}) async {
    final next = await _pickNextVideo(wrap: wrap);
    if (!mounted) return;
    // Grace period, same rationale as auto-play-next.
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted || !_completed) return;
    _current = next ?? _current; // null → single-video folder: loop it
    setState(() => _error = null);
    await _openCurrent();
  }

  /// Picks the next video from the current folder honouring shuffle and
  /// wrap. Returns null when there is nothing to advance to (end of a
  /// non-wrapping sequence, or listing unavailable).
  Future<VideoItem?> _pickNextVideo({required bool wrap}) async {
    final siblings = await _orderedSiblings();
    if (siblings == null || siblings.length < 2) {
      // Single-file folder: repeat all means replay the same file.
      return (wrap && siblings != null && siblings.length == 1) ? siblings.first : null;
    }
    final cur = _current;
    final idx = siblings.indexWhere(
      (v) => v.path == cur.path && v.uri == cur.uri,
    );
    final nextIdx = nextPlaybackIndex(
      idx < 0 ? 0 : idx,
      siblings.length,
      wrap: wrap,
      shuffle: _shuffle,
    );
    if (nextIdx == null || nextIdx == idx) return null;
    return siblings[nextIdx];
  }

  /// Lists the current folder's videos in playback order (season/episode
  /// aware when the folder looks episodic, else alphabetical). Returns null
  /// when the current video isn't in a listable file folder. Jellyfin
  /// folders aren't listed here yet (auto-play stays sequential-only there).
  Future<List<VideoItem>?> _orderedSiblings() async {
    final cur = _current;
    // Local / SMB file folders (path or content:// handled via FileBrowser).
    final p = cur.path;
    if (p != null && p.isNotEmpty) {
      final parent = _parentDir(p);
      if (parent == null) return null;
      try {
        final entries = await FileBrowserService.instance.listDirectory(parent);
        final videos = entries.where((e) => !e.isDirectory).toList();
        if (videos.isEmpty) return null;
        // Prefer season/episode ordering when the folder looks episodic.
        final episodic = videos.any((e) => ParsedFileName.parse(e.name).isEpisode);
        if (episodic) {
          videos.sort((a, b) {
            final pa = ParsedFileName.parse(a.name);
            final pb = ParsedFileName.parse(b.name);
            final c = pa.season.compareTo(pb.season);
            if (c != 0) return c;
            final d = pa.episode.compareTo(pb.episode);
            if (d != 0) return d;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        } else {
          videos.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
        return videos
            .map((e) {
              final isContent = e.path.startsWith('content://');
              return VideoItem(
                id: 'folder_next_${e.path.hashCode}',
                title: e.name,
                path: isContent ? null : e.path,
                uri: isContent ? e.path : null,
                resumeKey: e.resumeKey,
                duration: Duration.zero,
                sizeBytes: e.size,
              );
            })
            .toList();
      } catch (_) {
        return null;
      }
    }
    // Jellyfin: next playable in the same parent folder.
    if (cur.jellyfinItemId != null && cur.jellyfinServerId != null) {
      try {
        final client = JellyfinClient();
        final server = await client.serverForUrl(cur.jellyfinServerId!);
        JellyfinServer? resolved = server;
        if (resolved == null) {
          final servers = await client.loadServers();
          try {
            resolved = servers.firstWhere((s) => s.urlHost == cur.jellyfinServerId);
          } catch (_) {
            resolved = null;
          }
        }
        if (resolved == null) return null;
        // Fetch the current item to learn its ParentId, then list siblings.
        final item = await client.getItem(resolved, cur.jellyfinItemId!);
        final parentId = item?.parentId;
        if (parentId == null || parentId.isEmpty) return null;
        final siblings = await client.getItems(resolved, parentId);
        final playable = siblings.where((e) => e.isPlayable).toList();
        if (playable.isEmpty) return null;
        final episodic = playable.any((e) => e.parentIndexNumber != null && e.indexNumber != null);
        if (episodic) {
          playable.sort((a, b) {
            final c = (a.parentIndexNumber ?? 0).compareTo(b.parentIndexNumber ?? 0);
            if (c != 0) return c;
            final d = (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
            if (d != 0) return d;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        } else {
          playable.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        }
        return playable.map((e) => client.videoItem(resolved!, e)).toList();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  String? _parentDir(String path) {
    // Handles both `/storage/.../Show/S01E01.mkv` and `tree:<id>/Show/...`
    // synthetic paths used for SAF bookmark trees.
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

  /// Keeps the controls visible while paused or buffering, and starts the
  /// auto-hide countdown only while playing. In picture-in-picture the
  /// floating window always shows ONLY the video — never reveal anything
  /// (a paused/ended pip would otherwise pop the whole control UI into the
  /// tiny window).
  void _syncControlsForPlaybackState() {
    if (_inPip) {
      _hideTimer?.cancel();
      _controlsVisible = false;
      return;
    }
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
    // Background playback: audio KEEPS PLAYING when the app is backgrounded
    // or the screen locks — that's the MediaSession + foreground-service
    // feature (Android) / background-audio mode (iOS). We only bookmark the
    // position above; on resume, media that the OS destroyed is reopened.
    if (state == AppLifecycleState.resumed) {
      _reopenAfterBackground();
    }
  }

  /// Media3 `Player.STATE_IDLE`: the native player lost its media (e.g. the
  /// platform view was recreated while the device was locked).
  static const int _nativeStateIdle = 1;

  /// Media3 `Player.STATE_READY`: media is open and metadata is known —
  /// the per-open format-chip flash fires on the first of these.
  static const int _nativeStateReady = 3;

  /// After returning to the foreground, verify the native player still has
  /// the media loaded. Android may destroy the video surface while locked and
  /// even recreate the whole platform view (a fresh ExoPlayer, reset to
  /// IDLE); if the media is gone, reopen from the saved resume position.
  /// When playback survived the background (the normal case now that audio
  /// keeps playing), it is left untouched — a user-paused player stays
  /// paused instead of being force-played.
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
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _sleepTicker?.cancel();
    _swipeOverlayTimer?.cancel();
    _singleTapTimer?.cancel();
    _dtSeekTimer?.cancel();
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
    // In picture-in-picture the floating window shows only the video.
    if (_inPip) return;
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

  // ---- Double-tap seek (phones only; TV uses the D-pad buttons) ----

  /// Pending single-tap, fired only if no double-tap lands within the window.
  Timer? _singleTapTimer;
  int? _dtSeekSide; // -1 back, +1 forward
  Timer? _dtSeekTimer;

  void _onTapUp(TapUpDetails details) {
    // PiP window: taps do nothing — the floating video stays clean.
    if (_inPip) return;
    if (_isTv) {
      _onScreenTap();
      return;
    }
    if (_touchLocked) {
      // Locked: reveal the bars so the amber Unlock button is reachable.
      // This tap must not toggle play/pause nor hide the controls — without
      // it a locked player is unrecoverable once the auto-hide fires.
      if (!_controlsVisible) _showControls();
      return;
    }
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(const Duration(milliseconds: 260), _onScreenTap);
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_isTv || !_backendReady || _touchLocked || _inPip) return;
    _singleTapTimer?.cancel();
    final w = MediaQuery.of(context).size.width;
    final forward = details.globalPosition.dx >= w / 2;
    _seekBy(Duration(seconds: forward ? 10 : -10));
    _dtSeekTimer?.cancel();
    _dtSeekTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _dtSeekSide = null);
    });
    setState(() => _dtSeekSide = forward ? 1 : -1);
  }

  // ---- Unified gesture handling (single-finger pan + two-finger pinch) ----
  //
  // A single GestureDetector can't own vertical + horizontal + scale
  // recognizers at once (the scale recognizer would be starved), so all
  // pointer movement flows through the scale recognizer and is routed by
  // pointer count: one finger = pan (vertical → brightness/volume, horizontal
  // → seek), two fingers = pinch-to-zoom.

  bool _panActive = false;
  _PanAxis? _panAxis;

  void _onScaleStart(ScaleStartDetails details) {
    if (_isTv || _touchLocked || _inPip) return;
    if (details.pointerCount >= 2) {
      _pinchBaseScale = _zoomScale;
      _hideTimer?.cancel();
      return;
    }
    _panActive = true;
    _panAxis = null;
    _hideTimer?.cancel();
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_isTv || _touchLocked || _inPip) return;
    if (details.pointerCount >= 2) {
      if (!_backendReady) return;
      final next = (_pinchBaseScale * details.scale).clamp(1.0, 3.0);
      if ((next - _zoomScale).abs() < 0.01) return;
      setState(() => _zoomScale = next);
      _exo?.setZoom(next);
      return;
    }
    if (!_panActive) return;
    final delta = details.focalPointDelta;
    if (_panAxis == null) {
      if (delta.dx.abs() < 4 && delta.dy.abs() < 4) return;
      _panAxis = delta.dx.abs() > delta.dy.abs()
          ? _PanAxis.horizontal
          : _PanAxis.vertical;
      if (_panAxis == _PanAxis.vertical) {
        _startSwipe(details.focalPoint);
      } else {
        _startSeek();
      }
      return;
    }
    if (_panAxis == _PanAxis.vertical) {
      _updateSwipe(delta.dy);
    } else {
      _updateSeek(delta.dx);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_isTv || _touchLocked || _inPip) return;
    if (details.pointerCount >= 2) {
      _restartHideTimer();
      return;
    }
    if (_panAxis == _PanAxis.vertical) {
      _endSwipe();
    } else if (_panAxis == _PanAxis.horizontal) {
      _endSeek();
    }
    _panActive = false;
    _panAxis = null;
    _restartHideTimer();
  }

  // ---- Swipe gesture (brightness / volume) ----

  void _startSwipe(Offset focal) {
    if (!_swipeEnabled) return;
    final w = MediaQuery.of(context).size.width;
    _swipeType = focal.dx < w / 2 ? _SwipeType.brightness : _SwipeType.volume;
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

  void _updateSwipe(double dy) {
    if (_swipeType == null || !_swipeGestureActive) return;
    _swipeDragDelta += -dy / (MediaQuery.of(context).size.height * 0.7);
    setState(_applySwipeValue);
  }

  void _endSwipe() {
    if (_swipeType == null) return;
    // active flag stops further updates/platform pushes.
    _swipeGestureActive = false;
    _swipeOverlayTimer?.cancel();
    _swipeOverlayTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted && !_swipeGestureActive) {
        setState(() => _swipeType = null);
      }
    });
  }

  // MARK: Horizontal-swipe seek with frame preview

  void _startSeek() {
    if (!_swipeEnabled) return;
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

  void _updateSeek(double dx) {
    if (!_seekPreviewActive) return;
    final w = MediaQuery.of(context).size.width;
    final dur = _duration.inMilliseconds;
    if (dur <= 0 || w <= 0) return;
    _seekDragPx += dx;
    final seconds = (_seekDragPx / w) * _seekDragSpanSeconds;
    setState(() {
      _seekTargetMs = (_seekBaseMs + seconds * 1000).round().clamp(0, dur);
    });
  }

  void _endSeek() {
    if (!_seekPreviewActive) return;
    final targetMs = _seekTargetMs;
    setState(() => _seekPreviewActive = false);
    if ((targetMs - _position.inMilliseconds).abs() >= 500) {
      _exo?.seekTo(Duration(milliseconds: targetMs));
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
    if (_touchLocked) return;
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
    if (_touchLocked) return;
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

  /// Read-only "Video info" sheet behind the top-bar ⓘ button. Surfaces
  /// every detail the chip row can show, plus the full source URL, live
  /// Read-only "Video info" sheet behind the top-bar ⓘ button. Surfaces
  /// the details the chip row can show, plus the full source URL, audio
  /// channel / sample-rate, chapter count, full decoder path, and file size.
  Future<void> _openVideoInfoSheet() async {
    if (_touchLocked) return;
    _showControls();
    final video = _current;
    // Resolve a few helpers outside the rows list to keep the literal tidy.
    final sourceLabel = _sourceLabel(video);
    final sourceUrl = (video.uri?.isNotEmpty == true)
        ? video.uri!
        : (video.path?.isNotEmpty == true ? video.path! : '');
    final fileSize = (video.sizeBytes ?? 0) > 0 ? _formatBytes(video.sizeBytes!) : null;
    final speedLabel = (_playbackSpeed - 1.0).abs() > 0.001
        ? '${_playbackSpeed.toStringAsFixed(2)}×'
        : null;
    final rows = <({String label, String value})>[
      (label: 'Title', value: video.title),
      (label: 'Source', value: sourceLabel),
      if (sourceUrl.isNotEmpty && sourceUrl != video.title)
        (label: 'URL', value: sourceUrl),
      if (fileSize != null) (label: 'File size', value: fileSize),
      (label: 'HDR', value: _hdrLabel),
      if (_videoCodecInfoLabel != null)
        (label: 'Video', value: _videoCodecInfoLabel!),
      if (_resolutionInfoLabel != null)
        (label: 'Resolution', value: _resolutionInfoLabel!),
      if (Platform.isAndroid && _liveDecoderName != null)
        (
          label: 'Decoder',
          value: '$_liveDecoderName${(_isHwDecoder ?? true) ? " · hardware" : " · software"}',
        ),
      if (_audioInfoLabel != null || _liveAudioPassthrough)
        (
          label: 'Audio',
          value: _liveAudioPassthrough
              ? '${_audioInfoLabel ?? "Audio"} · Passthrough'
              : _audioInfoLabel!,
        ),
      if (_liveAudioChannelCount != null && _liveAudioChannelCount! > 0)
        (
          label: 'Audio ch.',
          value: '$_liveAudioChannelCount ch',
        ),
      if (_transcodeActive ||
          video.isTranscoded ||
          JellyfinClient.isTranscodeUri(video.uri ?? ''))
        (label: 'Stream', value: 'Server transcoding'),
      if (Platform.isAndroid && _liveSpatial == 'on')
        (label: 'Spatial audio', value: 'On'),
      if (Platform.isAndroid && _audioBoost > 1.01)
        (label: 'Volume boost', value: '${_audioBoost.toStringAsFixed(1)}×'),
      if (Platform.isAndroid && _nightMode) (label: 'Night mode', value: 'On'),
      if (Platform.isAndroid && _liveBass > 0)
        (label: 'Bass boost', value: '$_liveBass/3'),
      if (speedLabel != null) (label: 'Speed', value: speedLabel),
      if (_chapters.isNotEmpty)
        (label: 'Chapters', value: '${_chapters.length}'),
    ];
    await showModalBottomSheet<void>(
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
                  'Video info',
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
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 110,
                            child: Text(
                              r.label,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 13),
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              r.value,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
  /// plus auto-paired sidecar files) plus an Off option and a manual
  /// "Load subtitle file..." entry (system picker for CX / any source).
  Future<void> _openSubtitleSheet() async {
    if (_touchLocked) return;
    _showControls();
    final tracks = _subtitleTracks;
    final selected = _selectedSubtitleTrack;
    // Sentinel for "Load subtitle file..." and "Search online…".
    const loadSentinel = -2;
    const onlineSentinel = -3;
    const downloadedBase = -10;
    // Load persisted online downloads for this video (Nova-style top section).
    final resumeKey = _current.resumeKey ?? _current.id;
    final downloaded = await DownloadedSubtitlesStore.loadForVideo(resumeKey);
    if (!mounted) return;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          // One scrollable list (not a fixed Column with nested Flexible
          // lists) — in landscape the fixed tiles alone can exceed the cap
          // and overflow the bottom.
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
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
              if (downloaded.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text('Downloaded', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                for (var i = 0; i < downloaded.length; i++)
                  () {
                    final d = downloaded[i];
                    final isSelected = _current.subtitleUri == d.path;
                    return _tvListTile(
                      leading: Icon(isSelected ? Icons.radio_button_checked : Icons.file_download_done, color: isSelected ? Colors.white : Colors.white70),
                      title: Text('${d.fileName} · ${d.language.toUpperCase()}', style: const TextStyle(color: Colors.white)),
                      onTap: () => Navigator.of(sheetContext).pop(downloadedBase - i),
                    );
                  }(),
                const Divider(color: Colors.white12, height: 1),
              ],
              if (tracks.isEmpty && downloaded.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Text(
                    'No subtitles found in this video',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                )
              else if (tracks.isNotEmpty) ...[
                _tvListTile(
                  leading: Icon(
                    selected < 0
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected < 0 ? Colors.white : Colors.white54,
                  ),
                  title: const Text(
                    'Off',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(-1),
                ),
                for (final t in tracks)
                  () {
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
                      onTap: () => Navigator.of(sheetContext).pop(t.index),
                    );
                  }(),
              ],
              const Divider(color: Colors.white12, height: 1),
              _tvListTile(
                leading: const Icon(Icons.language, color: Colors.white70),
                title: const Text(
                  'Search online subtitles…',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.of(sheetContext).pop(onlineSentinel),
              ),
              _tvListTile(
                leading: const Icon(Icons.file_open, color: Colors.white70),
                title: const Text(
                  'Load subtitle file…',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.of(sheetContext).pop(loadSentinel),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    if (choice == onlineSentinel) {
      await _searchOnlineSubtitle();
      return;
    }
    if (choice == loadSentinel) {
      await _pickAndLoadSubtitle();
      return;
    }
    if (choice <= downloadedBase) {
      final idx = downloadedBase - choice;
      if (idx >= 0 && idx < downloaded.length) {
        final picked = downloaded[idx];
        final pos = _position;
        _current = VideoItem(
          id: _current.id,
          title: _current.title,
          path: _current.path,
          uri: _current.uri,
          resumeKey: _current.resumeKey,
          duration: _current.duration,
          sizeBytes: _current.sizeBytes,
          resolution: _current.resolution,
          videoCodec: _current.videoCodec,
          hdrHint: _current.hdrHint,
          audioCodec: _current.audioCodec,
          audioProfile: _current.audioProfile,
          audioChannels: _current.audioChannels,
          subtitleUri: picked.path,
          httpHeaders: _current.httpHeaders,
          allowSelfSigned: _current.allowSelfSigned,
          jellyfinServerId: _current.jellyfinServerId,
          jellyfinItemId: _current.jellyfinItemId,
          externalSubtitles: _current.externalSubtitles,
        );
        await _reopenAt(pos, _duration);
      }
      return;
    }
    if (choice != selected) {
      _exo?.selectSubtitleTrack(choice);
    }
  }

  Future<void> _pickAndLoadSubtitle() async {
    // For CX / SMB videos, first try to auto-discover subtitle files sitting
    // next to the video on the same NAS share (via saved SMB credentials).
    // This is more reliable than the system picker, since CX doesn't expose
    // its NAS files through SAF and won't appear in the Files chooser.
    final smbUri = await _tryPickSmbSiblingSubtitle();
    if (smbUri == '__CANCEL__') return;
    if (smbUri != null) {
      // User picked a NAS sibling — load it.
      if (!mounted) return;
      final pos = _position;
      _current = VideoItem(
        id: _current.id,
        title: _current.title,
        path: _current.path,
        uri: _current.uri,
        resumeKey: _current.resumeKey,
        duration: _current.duration,
        sizeBytes: _current.sizeBytes,
        resolution: _current.resolution,
        videoCodec: _current.videoCodec,
        hdrHint: _current.hdrHint,
        audioCodec: _current.audioCodec,
        audioProfile: _current.audioProfile,
        audioChannels: _current.audioChannels,
        subtitleUri: smbUri,
        httpHeaders: _current.httpHeaders,
        allowSelfSigned: _current.allowSelfSigned,
        jellyfinServerId: _current.jellyfinServerId,
        jellyfinItemId: _current.jellyfinItemId,
        externalSubtitles: _current.externalSubtitles,
      );
      await _reopenAt(pos, _duration);
      return;
    }
    // Fallback: system file picker — shows any file manager on the device
    // (Files, CX Explorer, Solid Explorer, etc.) via GET_CONTENT chooser.
    String? uri;
    try {
      uri = await FileBrowserService.instance.pickSubtitle();
    } on PlatformException {
      uri = null;
    }
    if (uri == null || uri.isEmpty || !mounted) return;
    final pos = _position;
    _current = VideoItem(
      id: _current.id,
      title: _current.title,
      path: _current.path,
      uri: _current.uri,
      resumeKey: _current.resumeKey,
      duration: _current.duration,
      sizeBytes: _current.sizeBytes,
      resolution: _current.resolution,
      videoCodec: _current.videoCodec,
      hdrHint: _current.hdrHint,
      audioCodec: _current.audioCodec,
      audioProfile: _current.audioProfile,
      audioChannels: _current.audioChannels,
      subtitleUri: uri,
      httpHeaders: _current.httpHeaders,
      allowSelfSigned: _current.allowSelfSigned,
      jellyfinServerId: _current.jellyfinServerId,
      jellyfinItemId: _current.jellyfinItemId,
      externalSubtitles: _current.externalSubtitles,
    );
    await _reopenAt(pos, _duration);
  }

  Future<void> _searchOnlineSubtitle() async {
    // Prefill with the video title without extension / noise.
    final raw = _current.title.trim();
    final q = raw.isEmpty ? _current.id : raw;
    final filePath = _current.path;
    final resumeKey = _current.resumeKey ?? _current.id;
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (ctx) => OpensubtitlesSheet(initialQuery: q, filePath: filePath, resumeKey: resumeKey),
    );
    if (result == null || result.isEmpty || !mounted) return;
    final pos = _position;
    _current = VideoItem(
      id: _current.id,
      title: _current.title,
      path: _current.path,
      uri: _current.uri,
      resumeKey: _current.resumeKey,
      duration: _current.duration,
      sizeBytes: _current.sizeBytes,
      resolution: _current.resolution,
      videoCodec: _current.videoCodec,
      hdrHint: _current.hdrHint,
      audioCodec: _current.audioCodec,
      audioProfile: _current.audioProfile,
      audioChannels: _current.audioChannels,
      subtitleUri: result,
      httpHeaders: _current.httpHeaders,
      allowSelfSigned: _current.allowSelfSigned,
      jellyfinServerId: _current.jellyfinServerId,
      jellyfinItemId: _current.jellyfinItemId,
      externalSubtitles: _current.externalSubtitles,
    );
    await _reopenAt(pos, _duration);
  }

  Future<String> _writeTempForAuto(String fileName, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    // Use dart:io via path_provider's temp; need import already via player_screen? Add.
    // Fallback: use system temp via Directory.systemTemp
    final sub = Directory('${dir.path}/opensubs');
    if (!await sub.exists()) await sub.create(recursive: true);
    final safe = fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final f = File('${sub.path}/$safe');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<void> _maybeAutoFetchSubs() async {
    if (_autoFetchFired) return;
    _autoFetchFired = true;
    try {
      final auto = await SubtitlePrefs.loadAutoFetch();
      if (!auto) return;
      if (!OpensubtitlesClient.instance.hasApiKey) return;
      if (_subtitleTracks.isNotEmpty) return;
      final resumeKey = _current.resumeKey ?? _current.id;
      final downloaded = await DownloadedSubtitlesStore.loadForVideo(resumeKey);
      if (downloaded.isNotEmpty) return;
      if (_current.subtitleUri != null && _current.subtitleUri!.isNotEmpty) return;
      final nova = await SubtitlePrefs.loadDownloadLanguage();
      final lang = openSubsCodeForNovaCode(nova);
      final query = _current.title.trim().isEmpty ? _current.id : _current.title.trim();
      String? hash;
      if (_current.path != null && _current.path!.isNotEmpty) {
        hash = await opensubtitlesHashForFile(_current.path!);
      }
      final results = await OpensubtitlesClient.instance.search(query: query, languages: lang, movieHash: hash);
      if (results.isEmpty) return;
      final best = results.first;
      if (!mounted || _subtitleTracks.isNotEmpty) return;
      final info = await OpensubtitlesClient.instance.requestDownload(best.fileId);
      final bytes = await OpensubtitlesClient.instance.fetchBytes(info.link);
      final tmp = await _writeTempForAuto(info.fileName, bytes);
      final entry = await DownloadedSubtitlesStore.saveForVideo(resumeKey: resumeKey, tempPath: tmp, fileName: info.fileName, language: best.language);
      if (!mounted) return;
      final pos = _position;
      _current = VideoItem(
        id: _current.id,
        title: _current.title,
        path: _current.path,
        uri: _current.uri,
        resumeKey: _current.resumeKey,
        duration: _current.duration,
        sizeBytes: _current.sizeBytes,
        resolution: _current.resolution,
        videoCodec: _current.videoCodec,
        hdrHint: _current.hdrHint,
        audioCodec: _current.audioCodec,
        audioProfile: _current.audioProfile,
        audioChannels: _current.audioChannels,
        subtitleUri: entry.path,
        httpHeaders: _current.httpHeaders,
        allowSelfSigned: _current.allowSelfSigned,
        jellyfinServerId: _current.jellyfinServerId,
        jellyfinItemId: _current.jellyfinItemId,
        externalSubtitles: _current.externalSubtitles,
      );
      await _reopenAt(pos, _duration);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Auto-fetched: ${entry.fileName}')));
    } catch (_) {}
  }

  Future<void> _maybeAutoSelectReading(List<ExoSubtitleTrack> tracks) async {
    try {
      final pref = await SubtitlePrefs.loadReadingLanguage();
      if (pref == 'system') return;
      for (final t in tracks) {
        if (trackMatchesNovaCode(t.language, pref) || trackMatchesNovaCode(t.label, pref)) {
          await _exo?.selectSubtitleTrack(t.index);
          break;
        }
      }
    } catch (_) {}
  }

  /// For CX / SMB playback, scan the video's NAS folder via the saved SMB
  /// server for subtitle files next to the video. If siblings are found,
  /// shows a picker; returns the chosen `smb://` URI or null to fall back
  /// to the system file picker. Returns null immediately for non-NAS sources.
  Future<String?> _tryPickSmbSiblingSubtitle() async {
    try {
      final key = _current.resumeKey ?? '';
      String folder = '';
      String fileName = '';
      String? share;
      SmbServer? server;
      if (key.startsWith('cx:')) {
        // cx:/SMB/host/share/dir/file.mkv
        final raw = key.substring(3);
        final without = raw.startsWith('/SMB/')
            ? raw.substring(5)
            : raw.startsWith('SMB/')
            ? raw.substring(4)
            : raw;
        final parts = without.split('/');
        if (parts.length < 3) return null;
        final host = parts[0];
        share = parts[1];
        fileName = parts.last;
        folder = parts.length > 3
            ? parts.sublist(2, parts.length - 1).join('/')
            : '';
        final servers = await SmbClient.instance.listServers();
        for (final s in servers) {
          if (s.host.toLowerCase() == host.toLowerCase()) {
            server = s;
            break;
          }
        }
        if (server == null) return null;
      } else if (key.startsWith('smb:')) {
        // smb:serverId/share/dir/file.mkv
        final raw = key.substring(4);
        final slash = raw.indexOf('/');
        if (slash < 0) return null;
        final serverId = raw.substring(0, slash);
        final rest = raw.substring(slash + 1);
        final slash2 = rest.indexOf('/');
        if (slash2 < 0) return null;
        share = rest.substring(0, slash2);
        final fullPath = rest.substring(slash2 + 1);
        final lastSlash = fullPath.lastIndexOf('/');
        if (lastSlash >= 0) {
          folder = fullPath.substring(0, lastSlash);
          fileName = fullPath.substring(lastSlash + 1);
        } else {
          folder = '';
          fileName = fullPath;
        }
        final servers = await SmbClient.instance.listServers();
        for (final s in servers) {
          if (s.id == serverId) {
            server = s;
            break;
          }
        }
        if (server == null) return null;
      } else {
        return null;
      }
      // ignore: unnecessary_non_null_assertion
      final s = server!;
      // ignore: unnecessary_non_null_assertion
      final sh = share!;
      final f = fileName;
      final entries = await SmbClient.instance.listDirectory(s.id, sh, folder);
      final dot = f.lastIndexOf('.');
      final base = (dot > 0 ? f.substring(0, dot) : f).toLowerCase();
      final subExts = {'srt', 'ass', 'ssa', 'vtt', 'sub', 'smi'};
      final candidates = entries.where((e) => !e.isDirectory).where((e) {
        final n = e.name.toLowerCase();
        final d = n.lastIndexOf('.');
        if (d < 0) return false;
        final ext = n.substring(d + 1);
        if (!subExts.contains(ext)) return false;
        final bn = n.substring(0, d);
        return bn == base || bn.startsWith('$base.');
      }).toList();
      if (candidates.isEmpty) return null;
      candidates.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      if (!mounted) return null;
      // Show sibling picker + fallback to device storage.
      final picked = await showModalBottomSheet<String>(
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
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    'Subtitles on NAS',
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
                    itemCount: candidates.length,
                    itemBuilder: (context, i) {
                      final c = candidates[i];
                      return _tvListTile(
                        leading: const Icon(
                          Icons.subtitles,
                          color: Colors.white54,
                        ),
                        title: Text(
                          c.name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () => Navigator.of(context).pop(c.path),
                      );
                    },
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                _tvListTile(
                  leading: const Icon(Icons.file_open, color: Colors.white70),
                  title: const Text(
                    'Browse device storage…',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () => Navigator.of(context).pop('__BROWSE__'),
                ),
              ],
            ),
          ),
        ),
      );
      if (picked == null) return '__CANCEL__';
      if (picked == '__BROWSE__') return null;
      return await SmbClient.instance.openShare(s.id, sh, picked);
    } catch (_) {
      return null;
    }
  }

  /// Aspect / fit-mode picker: Fit, Crop to screen, Stretch to screen, then the
  /// fixed ratios (16:9, 4:3). The list is scrollable and height-capped so the
  /// sheet never overflows in landscape. Choice is applied to the native
  /// surface and persisted for future sessions.
  // ignore: unused_element
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

  /// Bottom-sheet playback-speed picker (0.25×–2×). Choice applies natively
  /// immediately and persists for future sessions.
  ///
  /// Button/sheet label for a speed value ("1×", "1.5×").
  static String speedLabel(double speed) =>
      speed == speed.roundToDouble() ? '${speed.toInt()}×' : '$speed×';

  static String _subtitleDelayLabel(int ms) {
    if (ms == 0) return 'Off';
    final s = (ms / 1000).toStringAsFixed(1);
    return '${ms > 0 ? '+' : ''}${s}s';
  }

  // ignore: unused_element
  Future<void> _openSpeedSheet() async {
    _showControls();
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final choice = await showModalBottomSheet<double>(
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
                  'Playback speed',
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
                  itemCount: speeds.length,
                  itemBuilder: (context, i) {
                    final speed = speeds[i];
                    final isSelected = speed == _playbackSpeed;
                    return _tvListTile(
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: isSelected ? Colors.white : Colors.white54,
                      ),
                      title: Text(
                        speedLabel(speed),
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => Navigator.of(sheetContext).pop(speed),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice != null && choice != _playbackSpeed) {
      setState(() => _playbackSpeed = choice);
      _exo?.setSpeed(choice);
      if (!_inTests) PlaybackSpeedStore.save(choice);
    }
  }

  /// Chapter list sheet. Tap a row to seek to the chapter start; the current
  /// chapter (position within [start, end)) is highlighted.
  // ignore: unused_element
  Future<void> _openChaptersSheet() async {
    _showControls();
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  'Chapters (${_chapters.length})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _chapters.length,
                  itemBuilder: (context, i) {
                    final chapter = _chapters[i];
                    final next = i + 1 < _chapters.length
                        ? _chapters[i + 1].startMs
                        : chapter.endMs;
                    final posMs = _position.inMilliseconds;
                    final isCurrent = posMs >= chapter.startMs &&
                        (next == null || posMs < next);
                    return _tvListTile(
                      leading: Icon(
                        isCurrent
                            ? Icons.play_arrow
                            : Icons.history_edu_outlined,
                        color:
                            isCurrent ? Theme.of(context).colorScheme.primary : Colors.white54,
                      ),
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              isCurrent ? Colors.white : Colors.white70,
                          fontWeight: isCurrent
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      subtitle: Text(
                        _formatDuration(
                          Duration(milliseconds: chapter.startMs),
                        ),
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      onTap: () => Navigator.of(sheetContext).pop(chapter.startMs),
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
      _exo?.seekTo(Duration(milliseconds: choice));
      if (!_playing && !_completed) _exo?.play();
    }
  }

  /// Unified overflow sheet for the bottom bar (aspect + speed + chapters in
  /// one place to keep the bar uncluttered). Aspect/speed taps apply
  /// immediately and stay in the sheet; chapter taps seek and close.
  Future<void> _openMoreSheet() async {
    if (_touchLocked) return;
    _showControls();
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    const fitOrder = VideoFitMode.values;
    bool expandAspect = false;
    bool expandSpeed = false;
    bool expandRepeat = false;
    bool expandSleep = false;
    bool expandAB = false;
    bool expandAudioDelay = false;
    bool expandChapters = false;
    bool expandSubtitleDelay = false;
    bool expandDecoder = false;
    bool expandBoost = false;
    bool expandBass = false;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSheet) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Text(
                      'Playback settings',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  // Picture-in-picture lives in app Settings (Player section):
                  // the toggle gates the automatic HOME/recents entry on both
                  // platforms; there is no manual ⋮ entry.
                  // Aspect ratio dropdown
                  _tvListTile(
                    leading: const Icon(Icons.aspect_ratio, color: Colors.white70),
                    title: const Text('Aspect ratio', style: TextStyle(color: Colors.white)),
                    subtitle: Text(_fitMode.label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    trailing: Icon(expandAspect ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                    onTap: () => setSheet(() => expandAspect = !expandAspect),
                  ),
                  if (expandAspect)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        children: [
                          for (final mode in fitOrder)
                            _tvListTile(
                              leading: Icon(
                                _fitMode == mode ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: _fitMode == mode ? Colors.white : Colors.white54,
                              ),
                              title: Text(mode.label, style: const TextStyle(color: Colors.white)),
                              onTap: () {
                                if (_fitMode != mode) {
                                  setState(() => _fitMode = mode);
                                  _exo?.setFitMode(mode);
                                  if (!_inTests) FitModeStore.save(mode);
                                }
                                setSheet(() {});
                              },
                            ),
                        ],
                      ),
                    ),
                  const Divider(color: Colors.white12, height: 1),
                  // Playback speed dropdown
                  _tvListTile(
                    leading: const Icon(Icons.speed, color: Colors.white70),
                    title: const Text('Playback speed', style: TextStyle(color: Colors.white)),
                    subtitle: Text(speedLabel(_playbackSpeed), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    trailing: Icon(expandSpeed ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                    onTap: () => setSheet(() => expandSpeed = !expandSpeed),
                  ),
                  if (expandSpeed)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        children: [
                          for (final s in speeds)
                            _tvListTile(
                              leading: Icon(
                                _playbackSpeed == s ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: _playbackSpeed == s ? Colors.white : Colors.white54,
                              ),
                              title: Text(speedLabel(s), style: const TextStyle(color: Colors.white)),
                              onTap: () {
                                if (_playbackSpeed != s) {
                                  setState(() => _playbackSpeed = s);
                                  _exo?.setSpeed(s);
                                  if (!_inTests) PlaybackSpeedStore.save(s);
                                }
                                setSheet(() {});
                              },
                            ),
                        ],
                      ),
                    ),
                  const Divider(color: Colors.white12, height: 1),
                  // Repeat & shuffle dropdown (Phase 2)
                  _tvListTile(
                    leading: Icon(
                      _repeat == LoopMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                      color: _repeat == LoopMode.off
                          ? Colors.white70
                          : const Color(0xFF7C8BFF),
                    ),
                    title: const Text('Repeat & shuffle', style: TextStyle(color: Colors.white)),
                    subtitle: Text(
                      _shuffle
                          ? '${_repeat.label} · Shuffle'
                          : _repeat.label,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: Icon(expandRepeat ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                    onTap: () => setSheet(() => expandRepeat = !expandRepeat),
                  ),
                  if (expandRepeat)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        children: [
                          for (final mode in LoopMode.values)
                            _tvListTile(
                              leading: Icon(
                                _repeat == mode ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: _repeat == mode ? Colors.white : Colors.white54,
                              ),
                              title: Text(mode.label, style: const TextStyle(color: Colors.white)),
                              onTap: () {
                                if (_repeat != mode) {
                                  setState(() => _repeat = mode);
                                  _exo?.setRepeatMode(mode.index);
                                  if (!_inTests) PlaybackModesStore.saveRepeat(mode);
                                }
                                setSheet(() {});
                              },
                            ),
                          SwitchListTile(
                            value: _shuffle,
                            onChanged: (v) {
                              setState(() => _shuffle = v);
                              if (!_inTests) PlaybackModesStore.saveShuffle(v);
                              setSheet(() {});
                            },
                            title: const Text('Shuffle', style: TextStyle(color: Colors.white)),
                            subtitle: const Text('Random order inside the folder', style: TextStyle(color: Colors.white54, fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  const Divider(color: Colors.white12, height: 1),
                  // Sleep timer dropdown (Phase 2)
                  _tvListTile(
                    leading: const Icon(Icons.bedtime, color: Colors.white70),
                    title: const Text('Sleep timer', style: TextStyle(color: Colors.white)),
                    subtitle: Text(
                      _sleepCountdown != null
                          ? '${_sleepCountdown!} left'
                          : _sleepAtEnd
                              ? 'End of video'
                              : 'Off',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: Icon(expandSleep ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                    onTap: () => setSheet(() => expandSleep = !expandSleep),
                  ),
                  if (expandSleep)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        children: [
                          for (final option in const [
                            (Duration.zero, 'Off'),
                            (Duration(minutes: 5), '5 minutes'),
                            (Duration(minutes: 10), '10 minutes'),
                            (Duration(minutes: 15), '15 minutes'),
                            (Duration(minutes: 30), '30 minutes'),
                            (Duration(minutes: 60), '60 minutes'),
                          ])
                            _tvListTile(
                              leading: Icon(
                                (_sleepUntil != null ? option.$1 : Duration.zero) == option.$1
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                color: (_sleepUntil != null ? option.$1 : Duration.zero) == option.$1
                                    ? Colors.white
                                    : Colors.white54,
                              ),
                              title: Text(option.$2, style: const TextStyle(color: Colors.white)),
                              onTap: () {
                                _setSleepTimer(
                                  duration: option.$1 == Duration.zero ? null : option.$1,
                                );
                                setSheet(() {});
                              },
                            ),
                          _tvListTile(
                            leading: Icon(
                              _sleepAtEnd ? Icons.radio_button_checked : Icons.radio_button_off,
                              color: _sleepAtEnd ? Colors.white : Colors.white54,
                            ),
                            title: const Text('End of current video', style: TextStyle(color: Colors.white)),
                            onTap: () {
                              _setSleepTimer(endOfVideo: true);
                              setSheet(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  const Divider(color: Colors.white12, height: 1),
                  // Audio delay (manual A/V sync) — Android only; AetherEngine
                  // exposes no audio-offset hook on iOS.
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    _tvListTile(
                      leading: const Icon(Icons.graphic_eq, color: Colors.white70),
                      title: const Text('Audio delay', style: TextStyle(color: Colors.white)),
                      subtitle: Text(
                        _audioDelayMs == 0
                            ? 'Off'
                            : _audioDelayMs > 0
                                ? '+${(_audioDelayMs / 1000).toStringAsFixed(1)} s (audio later)'
                                : '${(_audioDelayMs / 1000).toStringAsFixed(1)} s (audio earlier)',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      trailing: Icon(expandAudioDelay ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                      onTap: () => setSheet(() => expandAudioDelay = !expandAudioDelay),
                    ),
                    if (expandAudioDelay)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Column(
                          children: [
                            Slider(
                              value: _audioDelayMs.toDouble(),
                              min: -5000,
                              max: 5000,
                              divisions: 100,
                              label: '${(_audioDelayMs / 1000).toStringAsFixed(1)} s',
                              onChanged: (v) {
                                final ms = v.round();
                                setState(() => _audioDelayMs = ms);
                                _exo?.setAudioDelay(ms);
                              },
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () {
                                  setState(() => _audioDelayMs = 0);
                                  _exo?.setAudioDelay(0);
                                  setSheet(() {});
                                },
                                child: const Text('Reset', style: TextStyle(color: Colors.white70)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(color: Colors.white12, height: 1),
                  ],
                  // A-B repeat dropdown (Phase 2)
                  _tvListTile(
                    leading: Icon(
                      Icons.loop,
                      color: _abA != null && _abB != null
                          ? const Color(0xFF7C8BFF)
                          : Colors.white70,
                    ),
                    title: const Text('A-B repeat', style: TextStyle(color: Colors.white)),
                    subtitle: Text(
                      _abA != null && _abB != null
                          ? '${_formatDuration(Duration(milliseconds: _abA!))} – ${_formatDuration(Duration(milliseconds: _abB!))}'
                          : _abA != null
                              ? 'A ${_formatDuration(Duration(milliseconds: _abA!))} — pick B'
                              : 'Off',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: Icon(expandAB ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                    onTap: () => setSheet(() => expandAB = !expandAB),
                  ),
                  if (expandAB)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        children: [
                          _tvListTile(
                            leading: const Icon(Icons.flag, color: Colors.white54),
                            title: const Text('Set A to current position', style: TextStyle(color: Colors.white)),
                            onTap: () {
                              setState(() => _abA = _position.inMilliseconds);
                              setSheet(() {});
                            },
                          ),
                          _tvListTile(
                            leading: const Icon(Icons.flag, color: Colors.white54),
                            title: const Text('Set B to current position', style: TextStyle(color: Colors.white)),
                            onTap: () {
                              setState(() => _abB = _position.inMilliseconds);
                              setSheet(() {});
                            },
                          ),
                          _tvListTile(
                            leading: const Icon(Icons.clear, color: Colors.white54),
                            title: const Text('Clear', style: TextStyle(color: Colors.white)),
                            onTap: () {
                              setState(() {
                                _abA = null;
                                _abB = null;
                              });
                              setSheet(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  const Divider(color: Colors.white12, height: 1),
                  // Subtitle appearance (moved here from the app Settings
                  // screen — it belongs next to the CC picker it configures).
                  _tvListTile(
                    leading: const Icon(Icons.closed_caption, color: Colors.white70),
                    title: const Text('Subtitle settings', style: TextStyle(color: Colors.white)),
                    subtitle: const Text('Size, color, background, delay', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SubtitleSettingsScreen(),
                      ),
                    );
                    // Re-apply the (possibly changed) style to the live
                    // player — the settings screen only persists; without
                    // this the change only landed on the NEXT open.
                    if (!mounted) return;
                    try {
                      final style = await SubtitleStyle.load();
                      await _exo?.setSubtitleStyle(style);
                      final delayChanged = style.delayMs != _subtitleDelayMs;
                      _subtitleDelayMs = style.delayMs;
                      if (delayChanged &&
                          Platform.isAndroid &&
                          (_subtitleTracks.isNotEmpty || _subtitleOn)) {
                        await _reopenAt(_position, _duration);
                      }
                    } catch (_) {}
                  },
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    _tvListTile(
                      leading: const Icon(Icons.memory, color: Colors.white70),
                      title: const Text('Video decoder', style: TextStyle(color: Colors.white)),
                      subtitle: Text(_decoderMode.label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: Icon(expandDecoder ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                      onTap: () => setSheet(() => expandDecoder = !expandDecoder),
                    ),
                    if (expandDecoder)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Column(
                          children: [
                            for (final m in DecoderMode.values)
                              _tvListTile(
                                leading: Icon(
                                  _decoderMode == m ? Icons.radio_button_checked : Icons.radio_button_off,
                                  color: _decoderMode == m ? Colors.white : Colors.white54,
                                ),
                                title: Text(m.label, style: const TextStyle(color: Colors.white)),
                                subtitle: Text(
                                  switch (m) {
                                    DecoderMode.hw => 'Force hardware decoders',
                                    DecoderMode.sw => 'Prefer software decoders',
                                    _ => 'Automatic (recommended)',
                                  },
                                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                                ),
                                onTap: () async {
                                  if (m != _decoderMode) {
                                    setState(() => _decoderMode = m);
                                    setSheet(() {});
                                    await DecoderModeStore.save(m);
                                    // Live: reopen at same position so the
                                    // fresh MediaCodecSelector query picks the
                                    // new decoder (HW vs SW) immediately.
                                    if (!sheetContext.mounted) {
                                      if (mounted) await _reopenAt(_position, _duration);
                                      return;
                                    }
                                    Navigator.of(sheetContext).pop();
                                    if (mounted) await _reopenAt(_position, _duration);
                                  }
                                },
                              ),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                              child: Text('Reopens at same position to switch decoder.', style: TextStyle(color: Colors.white38, fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                    const Divider(color: Colors.white12, height: 1),
                  ],
                  // Volume Boost + Night Mode are Android-only (Media3
                  // LoudnessEnhancer) — AVPlayer caps volume at 1.0 and has
                  // no DRC, so the toggles would be cosmetic no-ops on iOS.
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    _tvListTile(
                      leading: const Icon(Icons.volume_up, color: Colors.white70),
                      title: const Text('Volume Boost', style: TextStyle(color: Colors.white)),
                      subtitle: Text(_audioBoost > 1.01 ? '${_audioBoost.toStringAsFixed(1)}×' : 'Off', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: Icon(expandBoost ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                      onTap: () => setSheet(() => expandBoost = !expandBoost),
                    ),
                    if (expandBoost)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Column(
                          children: [
                            Slider(
                              value: _audioBoost.clamp(1.0, 3.0),
                              min: 1.0,
                              max: 3.0,
                              divisions: 20,
                              label: '${_audioBoost.toStringAsFixed(1)}×',
                              onChanged: (v) {
                                final b = double.parse(v.toStringAsFixed(1));
                                setState(() => _audioBoost = b);
                                setSheet(() {});
                              },
                              onChangeEnd: (v) async {
                                final b = double.parse(v.toStringAsFixed(1));
                                setState(() => _audioBoost = b);
                                _exo?.setAudioBoost(b);
                                await PlaybackBoostStore.save(b);
                              },
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextButton(onPressed: () async {
                                  setState(() => _audioBoost = 1.0);
                                  setSheet(() {});
                                  _exo?.setAudioBoost(1.0);
                                  await PlaybackBoostStore.save(1.0);
                                }, child: const Text('Reset')),
                                Text('${_audioBoost.toStringAsFixed(1)}×', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                const SizedBox(width: 48),
                              ],
                            ),
                            const Text('LoudnessEnhancer (0–1500 mB)', style: TextStyle(color: Colors.white38, fontSize: 11)),
                          ],
                        ),
                      ),
                    // Bass Boost appears only while platform spatial audio
                    // is actually engaged — it exists to offset the HRTF
                    // low-end thinning of virtualized surround.
                    if (_liveSpatial == 'on') ...[
                      const Divider(color: Colors.white12, height: 1),
                      _tvListTile(
                        leading: const Icon(Icons.music_note, color: Colors.white70),
                        title: const Text('Bass Boost', style: TextStyle(color: Colors.white)),
                        subtitle: Text(
                          const ['Off', 'Low', 'Medium', 'High'][_liveBass.clamp(0, 3)],
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing: Icon(expandBass ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                        onTap: () => setSheet(() => expandBass = !expandBass),
                      ),
                      if (expandBass)
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Column(
                            children: [
                              for (final level in [0, 1, 2, 3])
                                _tvListTile(
                                  leading: Icon(
                                    _liveBass == level ? Icons.radio_button_checked : Icons.radio_button_off,
                                    color: _liveBass == level ? Colors.white : Colors.white54,
                                  ),
                                  title: Text(
                                    const ['Off', 'Low', 'Medium', 'High'][level],
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  onTap: () {
                                    setState(() => _liveBass = level);
                                    setSheet(() {});
                                    _exo?.setBassBoost(level);
                                  },
                                ),
                            ],
                          ),
                        ),
                    ],
                    const Divider(color: Colors.white12, height: 1),
                    _tvListTile(
                      leading: const Icon(Icons.nights_stay, color: Colors.white70),
                      title: const Text('Night Mode', style: TextStyle(color: Colors.white)),
                      subtitle: Text(_nightMode ? 'On — compressed dynamic range' : 'Off', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: Switch(
                        value: _nightMode,
                        onChanged: (v) async {
                          setState(() => _nightMode = v);
                          setSheet(() {});
                          _exo?.setNightMode(v);
                          await NightModeStore.save(v);
                        },
                      ),
                      onTap: () async {
                        final v = !_nightMode;
                        setState(() => _nightMode = v);
                        setSheet(() {});
                        _exo?.setNightMode(v);
                        await NightModeStore.save(v);
                      },
                    ),
                    const Divider(color: Colors.white12, height: 1),
                  ],
                  _tvListTile(
                    leading: const Icon(Icons.skip_next, color: Colors.white70),
                    title: const Text('Auto-play next', style: TextStyle(color: Colors.white)),
                    subtitle: Text(_autoPlayNext ? 'On' : 'Off', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    trailing: Switch(
                      value: _autoPlayNext,
                      onChanged: (v) async {
                        setState(() => _autoPlayNext = v);
                        setSheet(() {});
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool(kAutoPlayNextKey, v);
                      },
                    ),
                    onTap: () async {
                      final v = !_autoPlayNext;
                      setState(() => _autoPlayNext = v);
                      setSheet(() {});
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool(kAutoPlayNextKey, v);
                    },
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  _tvListTile(
                    leading: const Icon(Icons.timer_outlined, color: Colors.white70),
                    title: const Text('Subtitle delay', style: TextStyle(color: Colors.white)),
                    subtitle: Text(_subtitleDelayLabel(_subtitleDelayMs), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    trailing: Icon(expandSubtitleDelay ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                    onTap: () => setSheet(() => expandSubtitleDelay = !expandSubtitleDelay),
                  ),
                  if (expandSubtitleDelay)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Column(
                        children: [
                          Slider(
                            value: _subtitleDelayMs.toDouble().clamp(-30000, 30000).toDouble(),
                            min: -30000,
                            max: 30000,
                            divisions: 60,
                            label: _subtitleDelayLabel(_subtitleDelayMs),
                            onChanged: (v) {
                              final ms = v.round();
                              setState(() => _subtitleDelayMs = ms);
                              setSheet(() {});
                            },
                            onChangeEnd: (v) async {
                              await _applySubtitleDelay(v.round(), setSheet);
                            },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextButton(onPressed: () async {
                                await _applySubtitleDelay(0, setSheet);
                              }, child: const Text('Reset')),
                              Text(_subtitleDelayLabel(_subtitleDelayMs), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              Row(
                                children: [
                                  IconButton(icon: const Icon(Icons.remove, color: Colors.white70), onPressed: () async {
                                    await _applySubtitleDelay((_subtitleDelayMs - 500).clamp(-30000, 30000), setSheet);
                                  }),
                                  IconButton(icon: const Icon(Icons.add, color: Colors.white70), onPressed: () async {
                                    await _applySubtitleDelay((_subtitleDelayMs + 500).clamp(-30000, 30000), setSheet);
                                  }),
                                ],
                              ),
                            ],
                          ),
                          const Text('Live on iOS · reopens at same position on Android', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
                  if (_chapters.isNotEmpty) ...[
                    const Divider(color: Colors.white12, height: 1),
                    _tvListTile(
                      leading: const Icon(Icons.format_list_numbered, color: Colors.white70),
                      title: const Text('Chapters', style: TextStyle(color: Colors.white)),
                      subtitle: Text('${_chapters.length} chapters', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: Icon(expandChapters ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                      onTap: () => setSheet(() => expandChapters = !expandChapters),
                    ),
                    if (expandChapters)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Column(
                          children: [
                            for (int i = 0; i < _chapters.length; i++)
                              Builder(builder: (context) {
                                final ch = _chapters[i];
                                final next = i + 1 < _chapters.length ? _chapters[i + 1].startMs : ch.endMs;
                                final posMs = _position.inMilliseconds;
                                final isCurrent = posMs >= ch.startMs && (next == null || posMs < next);
                                return _tvListTile(
                                  leading: Icon(
                                    isCurrent ? Icons.play_arrow : Icons.history_edu_outlined,
                                    color: isCurrent ? Theme.of(context).colorScheme.primary : Colors.white54,
                                  ),
                                  title: Text(ch.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: isCurrent ? Colors.white : Colors.white70, fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400)),
                                  subtitle: Text(_formatDuration(Duration(milliseconds: ch.startMs)), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    _exo?.seekTo(Duration(milliseconds: ch.startMs));
                                    if (!_playing && !_completed) _exo?.play();
                                  },
                                );
                              }),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _applySubtitleDelay(int ms, StateSetter setSheet) async {
    setState(() => _subtitleDelayMs = ms);
    setSheet(() {});
    try {
      final style = await SubtitleStyle.load();
      final updated = style.copyWith(delayMs: ms);
      await updated.save();
      await _exo?.setSubtitleStyle(updated);
      if (Platform.isAndroid && (_subtitleTracks.isNotEmpty || _subtitleOn)) {
        await _reopenAt(_position, _duration);
      }
    } catch (_) {}
  }

  void _seekBy(Duration delta) {
    if (_touchLocked) return;
    _exo?.seekTo(_position + delta);
    _showControls();
  }

  void _onSeekStart(double value) {
    if (_touchLocked) return;
    _dragging = true;
    _dragValue = value;
    _hideTimer?.cancel();
    setState(() {});
  }

  void _onSeekUpdate(double value) {
    if (_touchLocked || !_dragging) return;
    _dragValue = value;
    setState(() {});
  }

  void _onSeekEnd(double value) {
    if (_touchLocked) return;
    final target = Duration(milliseconds: value.round());
    _exo?.seekTo(target);
    _dragging = false;
    _dragValue = value;
    _showControls();
  }

  void _toggleTouchLock() {
    setState(() => _touchLocked = !_touchLocked);
    _showControls();
  }

  void _togglePlayPause() {
    if (_touchLocked) return;
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

  /// Pretty-print a byte count for the ⓘ sheet "File size" row.
  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// Human-readable source label for the ⓘ sheet. Matches the
  /// PlaybackSource badge in library cards.
  String _sourceLabel(VideoItem video) {
    final uri = video.uri ?? '';
    final scheme = _liveSourceScheme;
    if (scheme == 'http' || scheme == 'https') {
      if (uri.contains('Jellyfin') || uri.toLowerCase().contains('jellyfin')) {
        return 'Jellyfin (HTTP)';
      }
      return uri.startsWith('http') ? 'Network (HTTP)' : 'WebDAV';
    }
    if (scheme == 'file' || scheme.isEmpty) {
      return 'Local file';
    }
    if (scheme == 'content') return 'Document (SAF)';
    if (scheme == 'ftp' || scheme == 'sftp') return 'FTP/SFTP';
    if (scheme.startsWith('dreamplayersmb')) return 'SMB';
    if (scheme.startsWith('dreamplayerwebdav')) return 'WebDAV';
    if (scheme == 'asset') return 'App asset';
    return scheme;
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
              color: deltaMs >= 0
                  ? Colors.lightGreenAccent
                  : Colors.orangeAccent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  HdrFormat get _effectiveHdr {
    if (_current.hdrFormat != HdrFormat.sdr) return _current.hdrFormat;
    if (_liveHdr != HdrFormat.sdr) return _liveHdr;
    return HdrFormat.sdr;
  }

  /// Dolby Vision label with profile (e.g. "Dolby Vision P8") when the codec
  /// carries a profile number; falls back to the plain format label.
  String get _hdrLabel {
    if (_effectiveHdr == HdrFormat.dolbyVision) {
      final raw = _liveVideoCodecRaw ?? _current.hdrHint ?? '';
      final mime = _liveVideoMimeRaw;
      // Prefer codec, fall back to mime/hint.
      final lab = dolbyVisionLabel(raw.isNotEmpty ? raw : mime, fallbackHint: _current.hdrHint);
      // dolbyVisionLabel returns generic when no profile; show P8 etc when known.
      return lab;
    }
    return _effectiveHdr.label;
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

  Color get _audioColor => const Color(0xFF81C784);

  Color get _passthroughColor => const Color(0xFFFFB74D);

  /// True when the current source is a live http/https stream (Jellyfin
  /// direct-play, URL playback, CX-Explorer "Open with" handoff, etc.)
  /// Live video codec label for the chip / info sheet, or null when unknown.
  /// For Dolby Vision the HDR chip already says "Dolby Vision", so the
  /// duplicate codec label is suppressed.
  String? get _videoCodecInfoLabel {
    final label = _liveVideoCodec ?? _current.videoCodecLabel;
    if (label == null) return null;
    if (_effectiveHdr == HdrFormat.dolbyVision && label.startsWith('Dolby Vision')) {
      return null;
    }
    return label;
  }

  /// Live audio label (codec · channels) for the chip / info sheet.
  String? get _audioInfoLabel {
    if (_liveAudioCodec != null) {
      return formatLiveAudioLabel(
        liveCodec: _liveAudioCodec,
        liveChannels: _liveAudioChannelCount,
        metaCodec: _current.audioCodec,
        metaProfile: _current.audioProfile,
        liveLanguage: _liveAudioLanguage,
      );
    }
    return _current.audioCodecLabel;
  }

  String? get _resolutionInfoLabel => _liveResolution ?? _current.resolution;

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

    final hdrChip = FormatChip(label: _hdrLabel, color: _hdrColor);
    final audioChipLabel = _audioInfoLabel;
    final audioChip = audioChipLabel != null || _liveAudioPassthrough
        ? FormatChip(
            label: _liveAudioPassthrough
                ? '${audioChipLabel ?? "Audio"} · Passthrough'
                : audioChipLabel!,
            color: _liveAudioPassthrough ? _passthroughColor : _audioColor,
          )
        : null;
    // The on-screen chip row shows only the two pieces of info the user
    // checks at a glance while playing: the HDR format (so they know
    // they're getting real HDR / DV / SDR) and the audio codec + channels
    // (so they know what they're hearing). Everything else — resolution,
    // decoder, transcode, network speed, source type, speed, audio
    // effects, spatial — lives in the ⓘ info sheet (no clutter, no
    // chip-row overflow on phones in landscape).
    final chips = [
      hdrChip,
      ?audioChip,
    ];

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
            // Media keys toggle playback even when not in TV mode —
            // a Bluetooth keyboard's play/pause button arrives here.
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
          } else if (!_controlsVisible && !_inPip) {
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
                onTapUp: _onTapUp,
                onDoubleTapDown: _onDoubleTapDown,
                onDoubleTap: () {},
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: const SizedBox.expand(),
              ),
            ),
            // Double-tap seek ripple (±10 s on the tapped half).
            if (_dtSeekSide != null)
              Positioned(
                top: 0,
                bottom: 0,
                left: _dtSeekSide == -1 ? 0 : null,
                right: _dtSeekSide == 1 ? 0 : null,
                width: MediaQuery.sizeOf(context).width / 2,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: 0.85,
                      duration: const Duration(milliseconds: 120),
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _dtSeekSide == -1
                              ? Icons.replay_10
                              : Icons.forward_10,
                          color: Colors.white,
                          size: 42,
                        ),
                      ),
                    ),
                  ),
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
                            _TvControlButton(
                              onPressed: _openVideoInfoSheet,
                              icon: const Icon(Icons.info_outline),
                              color: Colors.white,
                              onFocusChange: (_) => _showControls(),
                            ),
                            const SizedBox(width: 4),
                          ],
                        ),
                        // Defense-in-depth pip gate: the top bar already slides
                        // off when _controlsVisible is false (which happens
                        // when pip activates), but we also explicitly skip
                        // rendering the chip row if _inPip is true. The pip
                        // window must show ONLY the video — no chips, no
                        // network indicator, no title bar.
                        if (!_inPip && chips.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: chips,
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ±10 s buttons are TV-only (D-pad has no double-tap
                      // gesture); phones use the double-tap-to-seek gesture.
                      if (_isTv) ...[
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
                      ],
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
                      if (_isTv) ...[
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
                    ],
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
                                    onPressed: _openMoreSheet,
                                    icon: const Icon(Icons.more_vert),
                                    color: Colors.white,
                                    onFocusChange: (_) => _showControls(),
                                  ),
                                  if (!_isTv)
                                    _TvControlButton(
                                      onPressed: _toggleTouchLock,
                                      icon: Icon(
                                        _touchLocked
                                            ? Icons.lock
                                            : Icons.lock_open,
                                      ),
                                      color: _touchLocked
                                          ? Colors.amber
                                          : Colors.white,
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
  static const double _activeTrackHeight = 6;
  static const double _thumbRadius = 7;
  static const double _thumbActiveRadius = 11;
  static const double _touchHeight = 48;
  static const double _horizontalPadding = 12;

  bool _dragging = false;
  double _dragValue = 0;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double get _clampedMax => widget.max > 0 ? widget.max : 1;

  double _valueFromOffset(double localX, double totalWidth) {
    final trackWidth = totalWidth - (_horizontalPadding * 2);
    if (trackWidth <= 0) return 0;
    final trackDx = (localX - _horizontalPadding).clamp(0.0, trackWidth);
    final fraction = trackDx / trackWidth;
    return fraction * _clampedMax;
  }

  void _handleTouchStart(Offset localPosition, double totalWidth) {
    final ms = _valueFromOffset(localPosition.dx, totalWidth);
    setState(() {
      _dragging = true;
      _dragValue = ms;
    });
    widget.onChangeStart?.call(ms);
    widget.onChanged?.call(ms);
  }

  void _handleTouchUpdate(Offset localPosition, double totalWidth) {
    if (!_dragging) return;
    final ms = _valueFromOffset(localPosition.dx, totalWidth);
    setState(() => _dragValue = ms);
    widget.onChanged?.call(ms);
  }

  void _handleTouchEnd() {
    if (!_dragging) return;
    final ms = _dragValue;
    setState(() => _dragging = false);
    widget.onChangeEnd?.call(ms);
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
    final isFocused = _focusNode.hasFocus;
    final currentThumbRadius = _dragging ? _thumbActiveRadius : _thumbRadius;

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final trackWidth = (totalWidth - (_horizontalPadding * 2)).clamp(0.0, double.infinity);
          final thumbX = _horizontalPadding + positionFraction * trackWidth;
          final bufferWidth = bufferFraction * trackWidth;
          final activeWidth = positionFraction * trackWidth;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _handleTouchStart(details.localPosition, totalWidth),
            onTapUp: (_) => _handleTouchEnd(),
            onTapCancel: () => _handleTouchEnd(),
            onHorizontalDragStart: (details) => _handleTouchStart(details.localPosition, totalWidth),
            onHorizontalDragUpdate: (details) => _handleTouchUpdate(details.localPosition, totalWidth),
            onHorizontalDragEnd: (_) => _handleTouchEnd(),
            onHorizontalDragCancel: () => _handleTouchEnd(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: _touchHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: isFocused
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                border: Border.all(
                  color: isFocused
                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.7)
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Background track (dark)
                  Positioned(
                    top: (_touchHeight - _trackHeight) / 2,
                    left: _horizontalPadding,
                    width: trackWidth,
                    child: Container(
                      height: _trackHeight,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Buffer fill (gray)
                  Positioned(
                    top: (_touchHeight - _trackHeight) / 2,
                    left: _horizontalPadding,
                    width: bufferWidth,
                    child: Container(
                      height: _trackHeight,
                      decoration: BoxDecoration(
                        color: Colors.white54,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Active progress fill (white)
                  Positioned(
                    top: (_touchHeight - (_dragging ? _activeTrackHeight : _trackHeight)) / 2,
                    left: _horizontalPadding,
                    width: activeWidth,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      height: _dragging ? _activeTrackHeight : _trackHeight,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  // Thumb circle (with glow when dragging)
                  Positioned(
                    top: (_touchHeight - currentThumbRadius * 2) / 2,
                    left: thumbX - currentThumbRadius,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      width: currentThumbRadius * 2,
                      height: currentThumbRadius * 2,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 4,
                            spreadRadius: 1,
                          ),
                          if (_dragging)
                            BoxShadow(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 3,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

Widget _tvListTile({
  required Widget title,
  Widget? leading,
  Widget? subtitle,
  Widget? trailing,
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
              trailing: trailing,
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

/// Top-right live network speed indicator — small down-arrow + the current
/// "5.2 MB/s" label, updated on every bandwidth event from the player.
/// Lives next to the ⓘ button in the player top bar; hidden entirely in
/// pip mode (the parent gates the widget out so the floating window shows
/// only the video). When the speed is still loading (the player hasn't

