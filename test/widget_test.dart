import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/app.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/player_screen.dart';
import 'package:dream_player/widgets/format_chip.dart';

void main() {
  testWidgets('App shows library and settings shell', (tester) async {
    await tester.pumpWidget(const DreamPlayerApp());

    expect(find.text('DreamPlayer'), findsOneWidget);
    expect(find.text('Your library'), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('Switching to settings tab shows settings', (tester) async {
    await tester.pumpWidget(const DreamPlayerApp());

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Folders to scan'), findsOneWidget);
  });

  testWidgets('Tapping a video opens the player with codec chips', (
    tester,
  ) async {
    const video = VideoItem(
      id: '1',
      title: 'Sonic Anthem (IMAX)',
      path: '/storage/emulated/0/Download/video/test.mkv',
      duration: Duration(seconds: 50),
      videoCodec: 'h264',
      audioCodec: 'dts_hd',
      audioProfile: 'MA',
      audioChannels: '5.1',
    );
    await tester.pumpWidget(
      const MaterialApp(home: PlayerScreen(video: video)),
    );

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(FormatChip), findsWidgets);
    expect(find.text('DTS-HD MA 5.1'), findsOneWidget);
  });

  testWidgets('No overflow on small phone screen', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DreamPlayerApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('No overflow on tablet screen', (tester) async {
    tester.view.physicalSize = const Size(1024 * 2, 1366 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DreamPlayerApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('No overflow on landscape phone', (tester) async {
    tester.view.physicalSize = const Size(640 * 2, 360 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DreamPlayerApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('No overflow with large text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const DreamPlayerApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
