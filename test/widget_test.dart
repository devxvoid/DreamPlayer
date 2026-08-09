import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'package:dream_player/app.dart';
import 'package:dream_player/screens/player_screen.dart';
import 'package:dream_player/widgets/format_chip.dart';
import 'package:dream_player/widgets/video_card.dart';

void main() {
  testWidgets('App shows library and settings shell', (tester) async {
    await tester.pumpWidget(const DreamPlayerApp());

    expect(find.text('DreamPlayer'), findsOneWidget);
    expect(find.text('Your library'), findsOneWidget);
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
    await tester.pumpWidget(const DreamPlayerApp());

    await tester.tap(find.text('Sonic Anthem (IMAX)'));
    await tester.pumpAndSettle();

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

    final card = find.byType(VideoCard).first;
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.byType(PlayerScreen), findsOneWidget);
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
