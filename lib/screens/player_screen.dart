import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../services/exo_player.dart';
import '../utils/codec_info.dart';
import '../widgets/format_chip.dart';

/// Whether the app is running under `flutter test`.
const bool _inTests = bool.fromEnvironment('FLUTTER_TEST');

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.video});

  final VideoItem video;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// Native ExoPlayer (Media3) backend hosted in a platform view.
  ExoPlayerController? _exo;
  StreamSubscription<ExoPlayerEvent>? _exoSub;

  bool _controlsVisible = true;
  bool _muted = false;
  bool _fullscreen = false;

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

  bool get _backendReady => _exo != null;

  @override
  void initState() {
    super.initState();
    if (!_inTests) {
      _init();
    }
  }

  Future<void> _init() async {
    if (!Platform.isAndroid) {
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
      if (mounted) setState(() {});
      await exo.open(widget.video.path);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Playback unavailable: $e');
      }
    }
  }

  void _onExoEvent(ExoPlayerEvent e) {
    _playing = e.playing;
    _position = e.position;
    _duration = e.duration;
    _buffering = e.buffering;
    _completed = e.ended;
    if (e.error != null && e.error!.isNotEmpty) _error = e.error;
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
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _exoSub?.cancel();
    _exo?.dispose();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    SystemChrome.setEnabledSystemUIMode(
      _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _toggleMute() {
    _muted = !_muted;
    _exo?.setMuted(_muted);
    setState(() {});
  }

  void _seekBy(Duration delta) {
    _exo?.seekTo(_position + delta);
  }

  void _onSeekStart(double value) {
    _dragging = true;
    _dragValue = value;
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
    setState(() {});
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
    if (widget.video.hdrFormat != HdrFormat.sdr) return widget.video.hdrFormat;
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
    final video = widget.video;

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
    final videoChip = _liveVideoCodec != null
        ? FormatChip(label: _liveVideoCodec!, color: _videoColor)
        : video.videoCodecLabel != null
            ? FormatChip(label: video.videoCodecLabel!, color: _videoColor)
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

    final videoLayer = _exo != null && _error == null
        ? GestureDetector(
            onTap: _toggleControls,
            child: ExoPlayerView(controller: _exo!),
          )
        : GestureDetector(
            onTap: _toggleControls,
            child: Container(
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
          );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: videoLayer),
          if (_buffering && _backendReady && _error == null)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            offset: _controlsVisible ? Offset.zero : const Offset(0, -1),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
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
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          hdrChip,
                          ?videoChip,
                          ?audioChip,
                          ?resolutionChip,
                        ],
                      ),
                    ),
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
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Container(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                    ),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      reverse: true,
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
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                onPressed: !_backendReady
                                    ? null
                                    : () => _seekBy(const Duration(seconds: -10)),
                                icon: const Icon(Icons.replay_10),
                                color: Colors.white,
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                onPressed: !_backendReady
                                    ? null
                                    : _togglePlayPause,
                                icon: Icon(
                                  _completed
                                      ? Icons.replay
                                      : _playing
                                          ? Icons.pause_circle_filled
                                          : Icons.play_circle_fill,
                                  size: 48,
                                ),
                                color: Colors.white,
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                onPressed: !_backendReady
                                    ? null
                                    : () => _seekBy(const Duration(seconds: 10)),
                                icon: const Icon(Icons.forward_10),
                                color: Colors.white,
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                onPressed: _toggleMute,
                                icon: Icon(
                                  _muted ? Icons.volume_off : Icons.volume_up,
                                ),
                                color: Colors.white,
                              ),
                              IconButton(
                                onPressed: () {},
                                icon: const Icon(Icons.closed_caption),
                                color: Colors.white,
                              ),
                              IconButton(
                                onPressed: () {},
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
        ],
      ),
    );
  }
}
