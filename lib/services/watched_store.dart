import 'package:shared_preferences/shared_preferences.dart';

/// Persisted watched/unwatched marks, keyed by the same stable resume keys
/// the rest of the app uses (`ResumeStore`/`TmdStore.identityKeyFor`).
///
/// Marks are set automatically when a video plays to the end and can be
/// toggled manually from library lists. Unwatched is the absence of a key,
/// so legacy installs start clean.
class WatchedStore {
  WatchedStore._();

  static const String _prefsKey = 'dreamplayer.watched';

  static Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_prefsKey) ?? const []).toSet();
  }

  static Future<bool> isWatched(String key) async {
    if (key.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_prefsKey) ?? const []).contains(key);
  }

  static Future<void> set(String key, bool watched) async {
    if (key.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final marks = (prefs.getStringList(_prefsKey) ?? const []).toSet();
    final changed = watched ? marks.add(key) : marks.remove(key);
    if (changed) {
      await prefs.setStringList(_prefsKey, marks.toList());
    }
  }
}
