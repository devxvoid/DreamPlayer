import 'package:flutter/material.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';
import '../widgets/format_chip.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.video});

  final VideoItem video;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  bool _controlsVisible = true;

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
    });
  }

  Color get _hdrColor {
    switch (widget.video.hdrFormat) {
      case HdrFormat.dolbyVision:
        return const Color(0xFFB388FF);
      case HdrFormat.hdr10plus:
        return const Color(0xFFFFC400);
      case HdrFormat.hdr10:
        return const Color(0xFFFF8A65);
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleControls,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colorScheme.primaryContainer,
                      Colors.black,
                    ],
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.movie_filter,
                    size: 96,
                    color: Colors.white24,
                  ),
                ),
              ),
            ),
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
                          onPressed: () {},
                          icon: const Icon(Icons.cast),
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
                          FormatChip(
                            label: video.hdrLabel,
                            color: _hdrColor,
                          ),
                          if (video.videoCodecLabel != null)
                            FormatChip(
                              label: video.videoCodecLabel!,
                              color: _videoColor,
                            ),
                          if (video.audioCodecLabel != null)
                            FormatChip(
                              label: video.audioCodecLabel!,
                              color: _audioColor,
                            ),
                          if (video.resolution != null)
                            FormatChip(
                              label: video.resolution!,
                              color: _infoColor,
                            ),
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
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '00:00',
                              style: TextStyle(color: Colors.white),
                            ),
                            Text(
                              video.durationLabel,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                        Slider(
                          value: 0,
                          max: 100,
                          onChanged: (_) {},
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.replay_10),
                              color: Colors.white,
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(
                                Icons.play_circle_fill,
                                size: 48,
                              ),
                              color: Colors.white,
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.forward_10),
                              color: Colors.white,
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              onPressed: () {},
                              icon: const Icon(Icons.volume_up),
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
                              onPressed: () {},
                              icon: const Icon(Icons.fullscreen),
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
        ],
      ),
    );
  }
}
