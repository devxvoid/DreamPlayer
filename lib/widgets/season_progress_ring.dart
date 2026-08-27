import 'package:flutter/material.dart';

/// Circular progress indicator showing watched/total (e.g. 3/10).
///
/// Uses a [Stack] + [CircularProgressIndicator] with a text overlay,
/// 28-32dp by default, primary color for progress.
class SeasonProgressRing extends StatelessWidget {
  const SeasonProgressRing({
    super.key,
    required this.watched,
    required this.total,
    this.size = 30,
    this.strokeWidth = 3,
  });

  final int watched;
  final int total;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = total <= 0 ? 0.0 : (watched / total).clamp(0.0, 1.0);
    final label = '$watched/$total';
    // Choose font size that fits 1-2 digit counts inside the ring.
    final fontSize = size <= 28 ? 8.0 : 10.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: total <= 0 ? 0 : progress,
            strokeWidth: strokeWidth,
            backgroundColor: colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}
