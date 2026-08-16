import 'package:dream_player/services/library_folders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LibraryFolder folder(
    String id, {
    String name = 'House',
    String path = 'tree:bookmark1',
    DateTime? addedAt,
  }) {
    return LibraryFolder(
      id: id,
      name: name,
      path: path,
      addedAt: addedAt ?? DateTime.fromMillisecondsSinceEpoch(1000),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LibraryFolder', () {
    test('json round-trip preserves fields', () {
      final original = folder('b1', name: 'Dune', path: '/sdcard/Movies');
      final restored = LibraryFolder.fromJson(original.toJson());
      expect(restored.id, 'b1');
      expect(restored.name, 'Dune');
      expect(restored.path, '/sdcard/Movies');
      expect(restored.addedAt, original.addedAt);
    });

    test('metadataKey is folder:<id>', () {
      expect(folder('abc').metadataKey, 'folder:abc');
    });
  });

  group('LibraryFoldersStore', () {
    test('load returns empty when nothing stored', () async {
      expect(await LibraryFoldersStore.load(), isEmpty);
    });

    test('add persists, most recently added first', () async {
      await LibraryFoldersStore.add(folder('a'));
      await LibraryFoldersStore.add(folder('b'));
      final loaded = await LibraryFoldersStore.load();
      expect(loaded.map((f) => f.id), ['b', 'a']);
    });

    test('add with an existing id moves it to the front', () async {
      await LibraryFoldersStore.add(folder('a'));
      await LibraryFoldersStore.add(folder('b'));
      await LibraryFoldersStore.add(folder('a'));
      final loaded = await LibraryFoldersStore.load();
      expect(loaded.map((f) => f.id), ['a', 'b']);
    });

    test('remove deletes the folder', () async {
      await LibraryFoldersStore.add(folder('a'));
      await LibraryFoldersStore.add(folder('b'));
      await LibraryFoldersStore.remove('a');
      final loaded = await LibraryFoldersStore.load();
      expect(loaded.map((f) => f.id), ['b']);
    });

    test('corrupt json falls back to empty', () async {
      SharedPreferences.setMockInitialValues(
        {'dreamplayer.libraryFolders': 'not json'},
      );
      expect(await LibraryFoldersStore.load(), isEmpty);
    });
  });
}
