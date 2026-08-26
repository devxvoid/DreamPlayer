import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dream_player/services/playback_modes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoopMode', () {
    test('fromValue round-trips and defaults to off', () {
      for (final m in LoopMode.values) {
        expect(LoopMode.fromValue(m.value), m);
      }
      expect(LoopMode.fromValue(null), LoopMode.off);
      expect(LoopMode.fromValue(99), LoopMode.off);
      expect(LoopMode.fromValue(-1), LoopMode.off);
    });

    test('store round-trips repeat + shuffle', () async {
      SharedPreferences.setMockInitialValues({});
      await PlaybackModesStore.saveRepeat(LoopMode.all);
      await PlaybackModesStore.saveShuffle(true);
      expect(await PlaybackModesStore.loadRepeat(), LoopMode.all);
      expect(await PlaybackModesStore.loadShuffle(), isTrue);
      await PlaybackModesStore.saveRepeat(LoopMode.one);
      await PlaybackModesStore.saveShuffle(false);
      expect(await PlaybackModesStore.loadRepeat(), LoopMode.one);
      expect(await PlaybackModesStore.loadShuffle(), isFalse);
    });

    test('fresh prefs default to off / no shuffle', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PlaybackModesStore.loadRepeat(), LoopMode.off);
      expect(await PlaybackModesStore.loadShuffle(), isFalse);
    });
  });

  group('nextPlaybackIndex', () {
    test('sequential next', () {
      expect(nextPlaybackIndex(0, 5, wrap: false, shuffle: false), 1);
      expect(nextPlaybackIndex(3, 5, wrap: false, shuffle: false), 4);
    });

    test('end of non-wrapping list returns null', () {
      expect(nextPlaybackIndex(4, 5, wrap: false, shuffle: false), isNull);
    });

    test('wrap loops back to the first entry', () {
      expect(nextPlaybackIndex(4, 5, wrap: true, shuffle: false), 0);
      expect(nextPlaybackIndex(2, 5, wrap: true, shuffle: false), 3);
    });

    test('single-entry list: wrap replays, no-wrap ends', () {
      expect(nextPlaybackIndex(0, 1, wrap: true, shuffle: false), 0);
      expect(nextPlaybackIndex(0, 1, wrap: false, shuffle: false), isNull);
      expect(nextPlaybackIndex(0, 1, wrap: true, shuffle: true), 0);
      expect(nextPlaybackIndex(0, 1, wrap: false, shuffle: true), isNull);
    });

    test('empty list returns null', () {
      expect(nextPlaybackIndex(0, 0, wrap: true, shuffle: false), isNull);
    });

    test('shuffle never returns the current index when count > 1', () {
      var r = 0; // deterministic "random" that always picks 0
      for (var current = 0; current < 4; current++) {
        final idx = nextPlaybackIndex(current, 4,
            wrap: false, shuffle: true, random: (max) => r % max);
        expect(idx, isNot(current));
        expect(idx, inInclusiveRange(0, 3));
      }
    });

    test('shuffle honours the injected random source', () {
      expect(
        nextPlaybackIndex(0, 5, wrap: false, shuffle: true, random: (m) => 3),
        3,
      );
    });
  });
}
