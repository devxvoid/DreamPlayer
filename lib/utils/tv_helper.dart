import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the app is running on an Android TV / Fire TV device.
///
/// Uses screen width as a heuristic: Android TV launchers and Fire TV run
/// at 960dp+ landscape widths. This is checked at the widget level via
/// [MediaQuery] so it adapts at runtime (e.g. HDMI output to a TV).
bool isTvMode(BuildContext context) {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  return MediaQuery.sizeOf(context).width >= 960;
}

/// SharedPreferences key for the audio passthrough toggle.
const kAudioPassthroughKey = 'dreamplayer.audioPassthrough';

/// Whether audio passthrough is enabled (Android only).
///
/// When enabled AND an HDMI output is detected, ExoPlayer routes
/// compressed surround formats (AC3, E-AC3, DTS, DTS-HD, TrueHD)
/// through AudioTrack passthrough mode — the encoded bitstream goes
/// to the TV / soundbar / AVR for decoding.
Future<bool> isAudioPassthroughEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kAudioPassthroughKey) ?? false;
}
