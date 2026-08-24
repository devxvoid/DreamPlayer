import 'package:shared_preferences/shared_preferences.dart';

const String kAutoPlayNextKey = 'dreamplayer.autoPlayNext';

Future<bool> isAutoPlayNextEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kAutoPlayNextKey) ?? false;
}
