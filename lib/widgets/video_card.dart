import 'package:flutter/material.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';

class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onLongPress,
    this.progress,
    this.subtitle,
  });

  final VideoItem video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Playback progress (0..1) shown as a thin bar, e.g. for Continue watching.
  final double? progress;

  /// Optional label shown under the title, e.g. "Continue from 12:34".
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          colorScheme.primaryContainer,
                          colorScheme.tertiaryContainer,
                        ],
                      ),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.play_circle_outline,
                        size: 40,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                  if (video.hdrFormat != HdrFormat.sdr)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _Badge(
                        label: _hdrShortLabel(video.hdrFormat),
                        background: _hdrColor(video.hdrFormat),
                      ),
                    ),
                  if (video.resolution != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _Badge(label: video.resolution!),
                    ),
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: _Badge(label: video.durationLabel),
                  ),
                  if (progress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress!.clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: Colors.black45,
                        color: Colors.white70,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    if (subtitle != null)
                      Flexible(
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      )
                    else if (video.audioCodecLabel != null)
                      Flexible(
                        child: Text(
                          video.audioCodecLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.background = Colors.black54});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _hdrShortLabel(HdrFormat format) {
  switch (format) {
    case HdrFormat.dolbyVision:
      return 'DV';
    case HdrFormat.hdr10plus:
      return 'HDR10+';
    case HdrFormat.hdr10:
      return 'HDR10';
    case HdrFormat.hlg:
      return 'HLG';
    case HdrFormat.sdr:
      return 'SDR';
  }
}

Color _hdrColor(HdrFormat format) {
  switch (format) {
    case HdrFormat.dolbyVision:
      return const Color(0xFF7C4DFF);
    case HdrFormat.hdr10plus:
      return const Color(0xFFF9A825);
    case HdrFormat.hdr10:
      return const Color(0xFFF57C00);
    case HdrFormat.hlg:
      return const Color(0xFFEF6C00);
    case HdrFormat.sdr:
      return const Color(0xFF616161);
  }
}
