import 'package:shared_preferences/shared_preferences.dart';

/// Persists per-video playback positions so a video stopped mid-way can be
/// resumed from where it left off on the next open.
///
/// Keyed by a stable source identifier (file path, content URI, or an explicit
/// `resumeKey` for sources whose playable URL rotates between sessions, e.g.
/// the iPad SMB per-file token URLs).
class ResumeStore {
  ResumeStore._();

  static const String _prefix = 'resume_pos_ms_';

  static Future<Duration?> positionFor(String key) async {
    if (key.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_prefix + key);
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms);
  }

  static Future<void> save(String key, Duration position) async {
    if (key.isEmpty) return;
    final ms = position.inMilliseconds;
    if (ms <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefix + key, ms);
  }

  static Future<void> clear(String key) async {
    if (key.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefix + key);
  }
}
