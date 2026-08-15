import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/tmd_details_screen.dart';
import 'package:dream_player/services/tmdb_client.dart';

const _video = VideoItem(
  id: 'repro',
  title: 'Dolby Core Universe',
  path: '/storage/emulated/0/Download/video/Dolby-Core.mkv',
  duration: Duration(minutes: 136),
);

const _videoNoMatch = VideoItem(
  id: 'repro2',
  title: 'Some Unknown Movie',
  path: '/storage/emulated/0/Download/video/unknown.mkv',
  duration: Duration(minutes: 136),
);

Future<void> _pumpAndCheck(
  WidgetTester tester,
  VideoItem video,
  Size physical, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: TmdDetailsScreen(video: video),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: 'overflow at ${physical.width}x${physical.height}@3'
        ' textScale=$textScale',
  );
}

void main() {
  testWidgets('matched state has no overflow at device sizes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await TmdStore.save(
      _video.path!,
      const TmdMeta(
        movie: TmdMovie(
          id: 1,
          title: 'Dolby Core Universe',
          year: 2024,
          overview: 'A very long overview that keeps going on and on and on '
              'and on and on and on and on and on and on and on and on.',
          voteAverage: 8.2,
          posterPath: '/poster.jpg',
          backdropPath: '/backdrop.jpg',
        ),
        details: TmdDetails(
          title: 'Dolby Core Universe',
          overview: 'A very long overview that keeps going on and on and on '
              'and on and on and on and on and on and on and on and on.',
          voteAverage: 8.2,
          voteCount: 10,
          year: 2024,
          runtimeMinutes: 136,
          genres: ['Action', 'Sci-Fi', 'Adventure', 'Thriller', 'Drama'],
          cast: [
            TmdCastMember(name: 'Actor One', character: 'Character'),
            TmdCastMember(name: 'Actor Two', character: 'Character'),
            TmdCastMember(name: 'Actor Three', character: 'Character'),
          ],
        ),
      ),
    );

    await _pumpAndCheck(tester, _video, const Size(1080, 2400)); // portrait
    await _pumpAndCheck(tester, _video, const Size(2400, 1080)); // landscape
    await _pumpAndCheck(
      tester,
      _video,
      const Size(2400, 1080),
      textScale: 1.3,
    );
  });

  testWidgets('no-match/error state has no overflow at device sizes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // No metadata seeded: the lookup fails (test HTTP is blocked) and the
    // error no-match panel is shown.
    await _pumpAndCheck(tester, _videoNoMatch, const Size(1080, 2400));
    await _pumpAndCheck(tester, _videoNoMatch, const Size(2400, 1080));
  });
}
