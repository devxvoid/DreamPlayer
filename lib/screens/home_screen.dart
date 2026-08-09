import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../widgets/video_card.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<VideoItem> _videos = [
    VideoItem(
      id: '1',
      title: 'Interstellar (2014) 1080p',
      path: '/storage/emulated/0/Movies/interstellar.mkv',
      duration: const Duration(hours: 2, minutes: 49),
      sizeBytes: 16 * 1024 * 1024 * 1024,
      resolution: '1080p',
      videoCodec: 'h264',
      audioCodec: 'dts_hd',
      audioProfile: 'MA',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '2',
      title: 'Dune: Part Two',
      path: '/storage/emulated/0/Movies/dune2.mkv',
      duration: const Duration(hours: 2, minutes: 46),
      sizeBytes: 32 * 1024 * 1024 * 1024,
      resolution: '4K',
      videoCodec: 'hevc',
      hdrHint: 'DV P8',
      audioCodec: 'truehd',
      audioProfile: 'Atmos',
      audioChannels: '7.1',
    ),
    VideoItem(
      id: '3',
      title: 'Blade Runner 2049',
      path: '/storage/emulated/0/Movies/br2049.mkv',
      duration: const Duration(hours: 2, minutes: 44),
      sizeBytes: 28 * 1024 * 1024 * 1024,
      resolution: '1080p',
      videoCodec: 'hevc',
      hdrHint: 'HDR10+',
      audioCodec: 'eac3',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '4',
      title: 'The Dark Knight',
      path: '/storage/emulated/0/Movies/tdk.mkv',
      duration: const Duration(hours: 2, minutes: 32),
      sizeBytes: 20 * 1024 * 1024 * 1024,
      resolution: '1080p',
      videoCodec: 'h264',
      audioCodec: 'dts',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '5',
      title: 'Oppenheimer',
      path: '/storage/emulated/0/Movies/oppenheimer.mkv',
      duration: const Duration(hours: 3, minutes: 0),
      sizeBytes: 24 * 1024 * 1024 * 1024,
      resolution: '4K',
      videoCodec: 'hevc',
      hdrHint: 'HDR10+',
      audioCodec: 'dts_hd',
      audioProfile: 'MA',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '6',
      title: 'Gravity (Dolby Vision)',
      path: '/storage/emulated/0/Movies/gravity.mkv',
      duration: const Duration(hours: 1, minutes: 31),
      sizeBytes: 18 * 1024 * 1024 * 1024,
      resolution: '4K DV',
      videoCodec: 'hevc',
      hdrHint: 'DV P8',
      audioCodec: 'truehd',
      audioProfile: 'Atmos',
      audioChannels: '7.1',
    ),
    VideoItem(
      id: '7',
      title: 'Tenet (IMAX)',
      path: '/storage/emulated/0/Movies/tenet.mkv',
      duration: const Duration(hours: 2, minutes: 30),
      sizeBytes: 40 * 1024 * 1024 * 1024,
      resolution: '4K',
      videoCodec: 'hevc',
      hdrHint: 'HDR10',
      audioCodec: 'dts_hd',
      audioProfile: 'MA',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '8',
      title: 'Alien: Covenant',
      path: '/storage/emulated/0/Movies/alien.mkv',
      duration: const Duration(hours: 2, minutes: 2),
      sizeBytes: 8 * 1024 * 1024 * 1024,
      resolution: '1080p',
      videoCodec: 'h264',
      audioCodec: 'aac',
      audioChannels: '2.0',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: const Text('DreamPlayer'),
          floating: true,
          actions: [
            IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search),
              onPressed: () {},
            ),
            IconButton(
              tooltip: 'Scan for videos',
              icon: const Icon(Icons.refresh),
              onPressed: () {},
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          sliver: SliverToBoxAdapter(
            child: SearchBar(
              hintText: 'Search your library',
              leading: const Icon(Icons.search),
              onChanged: (_) {},
            ),
          ),
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
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 0.82,
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
          ),
        ),
      ],
    );
  }
}
