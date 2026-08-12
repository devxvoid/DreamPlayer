import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../widgets/video_card.dart';
import 'file_browser_screen.dart';
import 'player_screen.dart';
import 'smb_screen.dart';

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
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: const Text('DreamPlayer'),
          floating: true,
          actions: [
            IconButton(
              tooltip: 'Browse files',
              icon: const Icon(Icons.folder_open),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const FileBrowserScreen(),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: 'Network shares',
              icon: const Icon(Icons.lan_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SmbScreen(),
                  ),
                );
              },
            ),
          ],
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
    );
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
