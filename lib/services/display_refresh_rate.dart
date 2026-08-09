import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_displaymode/flutter_displaymode.dart';

/// Requests the highest refresh rate supported by the display.
///
/// On many Android devices apps render at 60 Hz by default even when the
/// display supports 90/120/144 Hz. Selecting the best display mode lets the
/// whole app run at the native smoothness. iOS/iPad (ProMotion) unlocks high
/// refresh rates automatically via `CADisableMinimumFrameDurationOnPhone` in
/// Info.plist.
Future<void> useNativeDisplayRefreshRate() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (_) {
    // Display mode selection is best-effort; fall back to the system default.
  }
}
