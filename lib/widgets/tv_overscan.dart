import 'package:flutter/material.dart';

import '../utils/tv_helper.dart';

/// TV overscan safe-area padding. Some TV panels crop the outer few percent of
/// the picture, so on TV (`isTvMode`) the app's non-player screens inset their
/// content by a safe margin; touch devices render [child] unchanged.
class TvOverscan extends StatelessWidget {
  const TvOverscan({super.key, required this.child});

  final Widget child;

  static const EdgeInsets _safeArea = EdgeInsets.symmetric(
    horizontal: 36,
    vertical: 20,
  );

  @override
  Widget build(BuildContext context) {
    if (!isTvMode(context)) return child;
    return Padding(padding: _safeArea, child: child);
  }
}
