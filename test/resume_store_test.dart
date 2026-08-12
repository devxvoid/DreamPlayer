import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/services/resume_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save and load a position', () async {
    await ResumeStore.save('/a/b.mkv', const Duration(minutes: 12));
    final pos = await ResumeStore.positionFor('/a/b.mkv');
    expect(pos, const Duration(minutes: 12));
  });

  test('clear removes a position', () async {
    await ResumeStore.save('/a/b.mkv', const Duration(minutes: 12));
    await ResumeStore.clear('/a/b.mkv');
    expect(await ResumeStore.positionFor('/a/b.mkv'), isNull);
  });

  test('positions are isolated per key', () async {
    await ResumeStore.save('/a.mkv', const Duration(seconds: 30));
    await ResumeStore.save('/b.mkv', const Duration(seconds: 90));
    expect(
      await ResumeStore.positionFor('/a.mkv'),
      const Duration(seconds: 30),
    );
    expect(
      await ResumeStore.positionFor('/b.mkv'),
      const Duration(seconds: 90),
    );
  });

  test('empty keys and non-positive positions are ignored', () async {
    await ResumeStore.save('', const Duration(minutes: 1));
    await ResumeStore.save('/a.mkv', Duration.zero);
    expect(await ResumeStore.positionFor('/a.mkv'), isNull);
  });
}
