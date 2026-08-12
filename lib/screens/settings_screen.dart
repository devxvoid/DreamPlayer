import 'package:flutter/material.dart';

import 'licenses_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Playback',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.speaker_group_outlined),
            title: Text('Audio output'),
            subtitle: Text('Auto (recommended)'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            leading: Icon(Icons.speed),
            title: Text('Default playback speed'),
            subtitle: Text('1.0x'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            leading: Icon(Icons.volume_off_outlined),
            title: Text('Resume playback'),
            subtitle: Text('Remember position for each video'),
            trailing: Switch(value: true, onChanged: null),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Video',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.hdr_plus_outlined),
            title: Text('HDR / Dolby Vision'),
            subtitle: Text('Use device passthrough when supported'),
            trailing: Switch(value: true, onChanged: null),
          ),
          const ListTile(
            leading: Icon(Icons.crop_original_outlined),
            title: Text('Default aspect ratio'),
            subtitle: Text('Original'),
            trailing: Icon(Icons.chevron_right),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Library',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.folder_outlined),
            title: Text('Folders to scan'),
            subtitle: Text('Movies, Download'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            leading: Icon(Icons.video_library_outlined),
            title: Text('Include subfolders'),
            trailing: Switch(value: true, onChanged: null),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'About',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.memory),
            title: Text('Engine'),
            subtitle: Text('ExoPlayer (Media3) + FFmpeg'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('0.1.0'),
          ),
          ListTile(
            leading: const Icon(Icons.gavel),
            title: const Text('Open-source licenses'),
            subtitle: const Text('GNU GPL v3.0 and third-party notices'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const LicensesScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
