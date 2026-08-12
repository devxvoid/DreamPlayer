import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/support_links.dart';
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
              'Support',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final option in supportOptions)
            ListTile(
              leading: Icon(option.icon),
              title: Text(option.title),
              subtitle: Text(option.subtitle),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () async {
                try {
                  await openSupportUrl(option.url);
                } on PlatformException {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not open this link'),
                      ),
                    );
                  }
                }
              },
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
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text('Engine'),
            subtitle: Text(
              defaultTargetPlatform == TargetPlatform.iOS
                  ? 'AetherEngine (AVPlayer + FFmpeg)'
                  : 'ExoPlayer (Media3) + FFmpeg',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Version'),
            subtitle: FutureBuilder<String>(
              future: _loadVersion(),
              builder: (context, snapshot) => Text(
                snapshot.hasData ? snapshot.data! : '…',
              ),
            ),
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

  Future<String> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } on Exception {
      return '0.0.6';
    }
  }
}
