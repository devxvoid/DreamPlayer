import 'package:shared_preferences/shared_preferences.dart';

/// Repeat behaviour for the player screen.
enum LoopMode {
  off,
  one, // loop the current video
  all; // loop the folder (auto-advance with wrap-around)

  String get label => switch (this) {
        LoopMode.off => 'Off',
        LoopMode.one => 'Repeat one',
        LoopMode.all => 'Repeat all',
      };

  int get value => index;

  static LoopMode fromValue(int? v) =>
      (v != null && v >= 0 && v < LoopMode.values.length)
          ? LoopMode.values[v]
          : LoopMode.off;
}

/// Persists the player's repeat + shuffle choices
/// (`dreamplayer.repeatMode` / `dreamplayer.shuffle`).
class PlaybackModesStore {
  PlaybackModesStore._();

  static const String _repeatKey = 'dreamplayer.repeatMode';
  static const String _shuffleKey = 'dreamplayer.shuffle';

  static Future<LoopMode> loadRepeat() async {
    final prefs = await SharedPreferences.getInstance();
    return LoopMode.fromValue(prefs.getInt(_repeatKey));
  }

  static Future<void> saveRepeat(LoopMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_repeatKey, mode.value);
  }

  static Future<bool> loadShuffle() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shuffleKey) ?? false;
  }

  static Future<void> saveShuffle(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shuffleKey, on);
  }
}

/// Index of the next video to play in an ordered list of [count] entries.
///
/// - [wrap] (repeat all): last entry loops back to the first.
/// - [shuffle]: a uniformly random index; never the current one when the
///   list has more than one entry.
/// - Returns null at the end of a non-wrapping list (plain auto-next).
int? nextPlaybackIndex(
  int current,
  int count, {
  required bool wrap,
  required bool shuffle,
  int Function(int max)? random,
}) {
  if (count <= 0) return null;
  if (shuffle) {
    if (count == 1) return wrap ? 0 : null;
    final r = random ?? ((max) => DateTime.now().microsecondsSinceEpoch % max);
    var idx = r(count);
    if (idx == current) idx = (idx + 1) % count;
    return idx;
  }
  final next = current + 1;
  if (next < count) return next;
  return wrap ? 0 : null;
}
