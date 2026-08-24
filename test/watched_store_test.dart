import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/watched_store.dart';
import 'package:dream_player/services/exo_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WatchedStore', () {
    test('unwatched by default', () async {
      expect(await WatchedStore.isWatched('a'), isFalse);
    });

    test('set + load round-trip', () async {
      await WatchedStore.set('a', true);
      await WatchedStore.set('b', true);
      expect(await WatchedStore.isWatched('a'), isTrue);
      expect((await WatchedStore.load()), containsAll(['a', 'b']));
    });

    test('toggle off removes the mark', () async {
      await WatchedStore.set('a', true);
      await WatchedStore.set('a', false);
      expect(await WatchedStore.isWatched('a'), isFalse);
      expect(await WatchedStore.load(), isEmpty);
    });

    test('empty keys are ignored', () async {
      await WatchedStore.set('', true);
      expect(await WatchedStore.load(), isEmpty);
    });
  });

  group('ExoChapter', () {
    test('fromMap parses title/start/end', () {
      final c = ExoChapter.fromMap({
        'title': 'Intro',
        'startMs': 1500,
        'endMs': 60000,
      });
      expect(c.title, 'Intro');
      expect(c.startMs, 1500);
      expect(c.endMs, 60000);
    });

    test('fromMap tolerates a missing end', () {
      final c = ExoChapter.fromMap({'title': 'X', 'startMs': 5});
      expect(c.endMs, isNull);
    });
  });
}
