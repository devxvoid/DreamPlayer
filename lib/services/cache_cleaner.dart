import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// Clears the app's cached data: on-disk cache (subtitle re-encode temp files
/// and anything else the engine wrote to the platform cache dirs) plus
/// Flutter's in-memory image cache, which holds the TMDB posters/backdrops/
/// stills the cards and details screens have fetched via [Image.network].
class CacheCleaner {
  CacheCleaner._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/cache');

  /// Total bytes used by the on-disk cache. 0 when the platform channel isn't
  /// available (tests, unsupported platform).
  static Future<int> diskSizeBytes() async {
    try {
      return await _channel.invokeMethod<int>('size') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes the on-disk cache; returns the bytes freed. 0 on failure.
  static Future<int> clearDisk() async {
    try {
      return await _channel.invokeMethod<int>('clear') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Drops every cached network image (posters, backdrops, episode stills)
  /// from Flutter's in-memory image cache, including live ones still held by
  /// the frame tree. Images re-appear on the next load of the owning screen.
  static void clearMemoryImages() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  /// Bytes currently held by Flutter's in-memory image cache.
  static int memoryBytes() => PaintingBinding.instance.imageCache.currentSizeBytes;

  /// Formats [bytes] compactly: 412 B / 2.4 KB / 1.8 MB.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
