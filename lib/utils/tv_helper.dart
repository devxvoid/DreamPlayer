import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether the app is running on an Android TV / Fire TV device.
///
/// Uses screen width as a heuristic: Android TV launchers and Fire TV run
/// at 960dp+ landscape widths. This is checked at the widget level via
/// [MediaQuery] so it adapts at runtime (e.g. HDMI output to a TV).
bool isTvMode(BuildContext context) {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  return MediaQuery.sizeOf(context).width >= 960;
}
