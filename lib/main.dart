import 'package:flutter/material.dart';

import 'app.dart';
import 'services/display_refresh_rate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await useNativeDisplayRefreshRate();
  runApp(const DreamPlayerApp());
}
