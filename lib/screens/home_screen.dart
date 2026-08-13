import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../widgets/video_card.dart';
import 'file_browser_screen.dart';
import 'player_screen.dart';
import 'webdav_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The user's library. Empty until real library scanning lands (the file
  /// browser and network shares are the current way to open videos).
  final List<VideoItem> _videos = const [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            title: const Text('DreamPlayer'),
            floating: true,
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Your library',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ),
          if (_videos.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyLibrary(),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.crossAxisExtent;
                  final columns = _columnsForWidth(width);
                  const spacing = 14.0;
                  final itemWidth = (width - spacing * (columns - 1)) / columns;
                  final itemHeight = itemWidth * 9 / 16 + _textBlockHeight;
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: spacing,
                      crossAxisSpacing: spacing,
                      mainAxisExtent: itemHeight,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final video = _videos[index];
                        return VideoCard(
                          video: video,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => PlayerScreen(video: video),
                              ),
                            );
                          },
                        );
                      },
                      childCount: _videos.length,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddMenu,
        tooltip: 'Add a source',
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Opens the "+" menu: WebDAV server, internal storage, or pick a folder.
  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('WebDAV'),
              subtitle: const Text('Add a WebDAV server'),
              onTap: () => Navigator.of(context).pop('webdav'),
            ),
            ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('Internal storage'),
              subtitle: const Text('Browse files on this device'),
              onTap: () => Navigator.of(context).pop('storage'),
            ),
            ListTile(
              leading: const Icon(Icons.add_to_drive),
              title: const Text('Pick a folder'),
              subtitle: const Text('SD card, USB drive, cloud apps\u2026'),
              onTap: () => Navigator.of(context).pop('folder'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'webdav':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const WebDavScreen()),
        );
      case 'storage':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FileBrowserScreen()),
        );
      case 'folder':
        await _pickFolder();
    }
  }

  Future<void> _pickFolder() async {
    try {
      final picked = await FileBrowserService.instance.pickFolder();
      if (!mounted) return;
      if (picked == null) return;
      // The picked folder is now bookmarked as a root; open the file browser
      // so it (and the rest of storage) is browsable.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const FileBrowserScreen()),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not open the folder')),
      );
    }
  }

  static int _columnsForWidth(double width) {
    if (width >= 1000) return 6;
    if (width >= 760) return 4;
    if (width >= 480) return 3;
    return 2;
  }

  static const double _textBlockHeight = 84;
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 72,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'Your library is empty',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Browse files to play videos.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
