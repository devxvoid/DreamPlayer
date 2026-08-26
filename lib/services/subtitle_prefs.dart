import 'package:shared_preferences/shared_preferences.dart';

class SubtitlePrefs {
  static const _langKey = 'dreamplayer.prefSubLang';
  static const _autoKey = 'dreamplayer.autoFetchSubs';

  static Future<String> loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_langKey) ?? 'en';
  }

  static Future<void> saveLanguage(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_langKey, lang.trim().toLowerCase().isEmpty ? 'en' : lang.trim().toLowerCase());
  }

  static Future<bool> loadAutoFetch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoKey) ?? false;
  }

  static Future<void> saveAutoFetch(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoKey, v);
  }
}
