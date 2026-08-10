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
  final List<VideoItem> _videos = [
    VideoItem(
      id: '1',
      title: 'Sonic Anthem (IMAX)',
      path: '/storage/emulated/0/Download/video/'
          'IMAX_SONIC_ANTHEM_1000_THEATERS_1920x1012_DTS-HD_MA_51-'
          'thedigitaltheater (1).mkv',
      duration: const Duration(seconds: 50),
      sizeBytes: 307 * 1024 * 1024,
      resolution: '1920x1012',
      videoCodec: 'h264',
      audioCodec: 'dts_hd',
      audioProfile: 'MA',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '2',
      title: 'Dolby Vision People',
      path: '/storage/emulated/0/Download/video/'
          'dolby-vision-people-(www.demolandia.net).mp4',
      duration: const Duration(seconds: 76),
      sizeBytes: 277 * 1024 * 1024,
      resolution: '4K',
      videoCodec: 'hevc',
      hdrHint: 'DV P8',
      audioCodec: 'eac3',
      audioProfile: 'Atmos',
      audioChannels: '5.1',
    ),
    VideoItem(
      id: '3',
      title: 'Dolby Core Universe (UHD)',
      path: '/storage/emulated/0/Download/video/'
          'Dolby-Core-Universe-Lossless-Uhd-(Www.Demolandia.Net).mkv',
      duration: const Duration(seconds: 188),
      sizeBytes: 1029 * 1024 * 1024,
      resolution: '4K',
      videoCodec: 'hevc',
      audioCodec: 'truehd',
      audioProfile: 'Atmos',
      audioChannels: '7.1',
    ),
    VideoItem(
      id: '4',
      title: 'House S02E04 (x265 10-bit)',
      path: '/storage/emulated/0/Download/video/'
          'House.S02E04.1080p.10bit.BluRay.English.AAC.5.1.x265-Panda.mkv',
      duration: const Duration(minutes: 43, seconds: 45),
      sizeBytes: 1549 * 1024 * 1024,
      resolution: '1080p',
      videoCodec: 'hevc',
      audioCodec: 'aac',
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
              icon: const Icon(Icons.dns),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SmbScreen(),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: 'Scan for videos',
              icon: const Icon(Icons.refresh),
              onPressed: () {},
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
