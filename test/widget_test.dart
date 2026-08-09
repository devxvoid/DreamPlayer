import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/app.dart';

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

  testWidgets('Tapping a video opens the player screen', (tester) async {
    await tester.pumpWidget(const DreamPlayerApp());

    await tester.tap(find.text('Interstellar (2014) 1080p'));
    await tester.pumpAndSettle();

    expect(find.text('Now playing'), findsOneWidget);
  });
}
