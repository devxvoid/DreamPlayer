import 'dart:async';

import 'package:flutter/services.dart';

import '../models/video_item.dart';

/// Represents a video handed to the app via an Android "Open with" intent.
class OpenIntent {
  const OpenIntent({required this.title, this.uri, this.path});

  final String title;
  final String? uri;
  final String? path;

  VideoItem toVideoItem() => VideoItem(
        id: 'intent_${DateTime.now().microsecondsSinceEpoch}',
        title: title,
        path: path,
        uri: uri,
        duration: Duration.zero,
      );
}

/// Bridges the native `dreamplayer/intent` channel (see `MainActivity.kt`):
/// receives videos opened from file explorers / "Open with" menus.
class OpenIntentService {
  OpenIntentService._();

  static final OpenIntentService instance = OpenIntentService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/intent');

  final StreamController<OpenIntent> _controller =
      StreamController<OpenIntent>.broadcast();

  Stream<OpenIntent> get intents => _controller.stream;

  bool _initialized = false;

  /// Sets up the channel listener. [onOpen] is invoked for every intent that
  /// arrives (including one that launched the app), before [intents] is added.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        final args = (call.arguments as Map?) ?? const {};
        final intent = OpenIntent(
          title: (args['title'] as String?) ?? 'Video',
          uri: args['uri'] as String?,
          path: args['path'] as String?,
        );
        _controller.add(intent);
      }
    });

    final initial = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getInitialIntent',
    );
    if (initial != null) {
      final intent = OpenIntent(
        title: (initial['title'] as String?) ?? 'Video',
        uri: initial['uri'] as String?,
        path: initial['path'] as String?,
      );
      _controller.add(intent);
    }
  }
}