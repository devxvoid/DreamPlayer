import 'package:flutter/material.dart';

import '../models/hdr_format.dart';
import '../models/video_item.dart';

class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
  });

  final VideoItem video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
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
                child: Stack(
                  children: [
                    const Center(
                      child: Icon(
                        Icons.play_circle_outline,
                        size: 40,
                        color: Colors.white54,
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
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
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
                  if (video.audioCodecLabel != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      video.audioCodecLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
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
    case HdrFormat.sdr:
      return const Color(0xFF616161);
  }
}
