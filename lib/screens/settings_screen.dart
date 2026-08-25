import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auto_play_store.dart';
import '../services/cache_cleaner.dart';
import '../services/decoder_mode.dart';
import '../services/exo_player.dart';
import '../services/support_links.dart';
import '../services/trakt_client.dart';
import '../services/trakt_sync.dart';
import '../services/tmdb_client.dart';
import '../services/watched_store.dart';
import '../utils/tv_helper.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'licenses_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _diskBytes = 0;
  bool _cleared = false;
  bool _passthrough = false;
  bool _swipeGestures = true;
  bool _autoPlayNext = false;
  DecoderMode _decoderMode = DecoderMode.auto;
  double _audioBoost = 1.0;
  bool _nightMode = false;
  bool _traktConnected = false;
  DateTime? _traktLastSync;

  @override
  void initState() {
    super.initState();
    _refreshDiskSize();
    _loadPassthrough();
    _loadSwipeGestures();
    _loadAutoPlayNext();
    _loadDecoderMode();
    _loadAudioFilters();
    _loadTrakt();
  }

  Future<void> _loadTrakt() async {
    final client = TraktClient();
    if (!client.isConfigured) return;
    try {
      final connected = await client.isAuthenticated();
      final lastSync = await client.lastSyncAt();
      if (mounted) {
        setState(() {
          _traktConnected = connected;
          _traktLastSync = lastSync;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadPassthrough() async {
    final enabled = await isAudioPassthroughEnabled();
    if (mounted) setState(() => _passthrough = enabled);
  }

  Future<void> _loadSwipeGestures() async {
    try {
      final enabled = await areSwipeGesturesEnabled();
      if (mounted) setState(() => _swipeGestures = enabled);
    } catch (_) {}
  }

  Future<void> _loadAutoPlayNext() async {
    try {
      final enabled = await isAutoPlayNextEnabled();
      if (mounted) setState(() => _autoPlayNext = enabled);
    } catch (_) {}
  }

  Future<void> _loadDecoderMode() async {
    try {
      final mode = await DecoderModeStore.load();
      if (mounted) setState(() => _decoderMode = mode);
    } catch (_) {}
  }

  Future<void> _loadAudioFilters() async {
    try {
      final boost = await PlaybackBoostStore.load();
      final night = await NightModeStore.load();
      if (mounted) {
        setState(() {
          _audioBoost = boost;
          _nightMode = night;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshDiskSize() async {
    final size = await CacheCleaner.diskSizeBytes();
    if (mounted) setState(() => _diskBytes = size);
  }

  Future<void> _clearCache() async {
    final totalBytes = _diskBytes + CacheCleaner.memoryBytes();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cache?'),
        content: Text(
          'Removes ${CacheCleaner.formatBytes(totalBytes)} of cached images '
          'and temporary files. Posters and details may need to be reloaded '
          'from the network the next time you open them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await CacheCleaner.clearDisk();
    CacheCleaner.clearMemoryImages();
    if (!mounted) return;
    setState(() => _cleared = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
    await _refreshDiskSize();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTv = isTvMode(context);

    return SafeArea(
      child: TvOverscan(
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
              TvTile(
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
                'Storage',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TvTile(
              leading: const Icon(Icons.cleaning_services),
              title: const Text('Clear cache'),
              subtitle: Text(
                _cleared
                    ? 'Cached images and temporary files cleared'
                    : '${CacheCleaner.formatBytes(_diskBytes)} on disk · '
                          '${CacheCleaner.formatBytes(CacheCleaner.memoryBytes())} in memory',
              ),
              onTap: _clearCache,
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Audio',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.surround_sound),
                title: const Text('Audio passthrough'),
                subtitle: Text(
                  _passthrough
                      ? 'Auto — passthrough when HDMI detected'
                      : 'Off — decode to PCM (default)',
                ),
                value: _passthrough,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAudioPassthroughKey, value);
                  if (mounted) setState(() => _passthrough = value);
                },
              ),
            ],
            if (!isTv) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Player',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.swipe),
                title: const Text('Swipe gestures'),
                subtitle: const Text(
                  'Swipe left side for brightness, right side for volume',
                ),
                value: _swipeGestures,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kSwipeGesturesKey, value);
                  if (mounted) setState(() => _swipeGestures = value);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.skip_next),
                title: const Text('Auto-play next episode'),
                subtitle: const Text('Play the next episode when one ends'),
                value: _autoPlayNext,
                onChanged: (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(kAutoPlayNextKey, value);
                  if (mounted) setState(() => _autoPlayNext = value);
                },
              ),
              // Subtitle appearance settings moved into the player's ⋮ sheet
              // (subtitle_settings_screen.dart is pushed from there now).
              // Volume Boost + Night Mode need Media3's LoudnessEnhancer
              // (Android only) — AVPlayer caps volume at 1.0 and exposes no
              // DRC, so showing these on iOS would be cosmetic no-ops.
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                TvTile(
                  leading: const Icon(Icons.volume_up),
                  title: const Text('Volume Boost'),
                  subtitle: Text(
                    _audioBoost > 1.01
                        ? '${_audioBoost.toStringAsFixed(1)}× (LoudnessEnhancer)'
                        : 'Off — 1.0×',
                  ),
                  onTap: () async {
                    double temp = _audioBoost;
                    final picked = await showDialog<double>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Volume Boost'),
                        content: StatefulBuilder(
                          builder: (context, setD) => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Slider(
                                value: temp.clamp(1.0, 3.0),
                                min: 1.0,
                                max: 3.0,
                                divisions: 20,
                                label: '${temp.toStringAsFixed(1)}×',
                                onChanged: (v) => setD(
                                  () =>
                                      temp = double.parse(v.toStringAsFixed(1)),
                                ),
                              ),
                              Text(
                                '${temp.toStringAsFixed(1)}×',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, temp),
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await PlaybackBoostStore.save(picked);
                      if (mounted) setState(() => _audioBoost = picked);
                    }
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.nights_stay),
                  title: const Text('Night Mode'),
                  subtitle: const Text(
                    'Compress dynamic range for quiet listening',
                  ),
                  value: _nightMode,
                  onChanged: (value) async {
                    await NightModeStore.save(value);
                    if (mounted) setState(() => _nightMode = value);
                  },
                ),
              ],
              if (defaultTargetPlatform == TargetPlatform.android)
                TvTile(
                  leading: const Icon(Icons.memory),
                  title: const Text('Video decoder'),
                  subtitle: Text(switch (_decoderMode) {
                    DecoderMode.hw => 'Hardware — fastest, HDR passthrough',
                    DecoderMode.sw => 'Software — compatibility fallback',
                    _ => 'Auto — hardware when available',
                  }),
                  onTap: () async {
                    final picked = await showDialog<DecoderMode>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: const Text('Video decoder'),
                        children: [
                          RadioGroup<DecoderMode>(
                            groupValue: _decoderMode,
                            onChanged: (v) => Navigator.of(context).pop(v),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final m in DecoderMode.values)
                                  RadioListTile<DecoderMode>(
                                    value: m,
                                    title: Text(m.label),
                                    subtitle: Text(switch (m) {
                                      DecoderMode.hw =>
                                        'Force hardware decoders',
                                      DecoderMode.sw =>
                                        'Prefer software decoders',
                                      _ =>
                                        'Let the system choose (recommended)',
                                    }),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await DecoderModeStore.save(picked);
                      if (mounted) setState(() => _decoderMode = picked);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Takes effect on next video'),
                        ),
                      );
                    }
                  },
                ),
            ],
            if (TraktClient().isConfigured) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Trakt',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_traktConnected) ...[
                TvTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Sync now'),
                  subtitle: Text(
                    _traktLastSync == null
                        ? 'Push watched + resume to Trakt'
                        : 'Last synced ${_formatWhen(_traktLastSync!)}',
                  ),
                  onTap: _syncTrakt,
                ),
                TvTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('Disconnect Trakt'),
                  subtitle: const Text('Sign out and stop syncing'),
                  onTap: () async {
                    await TraktClient().signOut();
                    if (mounted) {
                      setState(() {
                        _traktConnected = false;
                        _traktLastSync = null;
                      });
                    }
                  },
                ),
              ] else
                TvTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Connect Trakt'),
                  subtitle: const Text('Sync watched history with trakt.tv'),
                  onTap: _connectTrakt,
                ),
            ],
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
            TvTile(
              leading: const Icon(Icons.memory),
              title: const Text('Engine'),
              subtitle: Text(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? 'AetherEngine (AVPlayer + FFmpeg)'
                    : 'ExoPlayer (Media3) + FFmpeg',
              ),
            ),
            TvTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Version'),
              subtitle: FutureBuilder<String>(
                future: _loadVersion(),
                builder: (context, snapshot) =>
                    Text(snapshot.hasData ? snapshot.data! : '…'),
              ),
            ),
            TvTile(
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
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                children: [
                  Text(
                    'Made with ❤️ by Mangesh Ghodke',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'DreamPlayer',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } on Exception {
      return '0.0.7';
    }
  }

  String _formatWhen(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _connectTrakt() async {
    final client = TraktClient();
    try {
      final code = await client.requestDeviceCode();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _TraktConnectDialog(client: client, code: code),
      );
      await _loadTrakt();
    } on TraktException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _syncTrakt() async {
    final client = TraktClient();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final items = await _collectTraktItems();
      await client.syncWatched(items);
      if (mounted) {
        setState(() => _traktLastSync = DateTime.now());
        messenger.showSnackBar(
          SnackBar(content: Text('Synced ${items.length} item(s) to Trakt')),
        );
      }
    } on TraktException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Builds the list of watched items to push to Trakt from the local
  /// [WatchedStore] marks, resolving each to a TMDB id via [TmdService].
  Future<List<TraktWatchItem>> _collectTraktItems() async {
    final keys = await WatchedStore.load();
    final items = <TraktWatchItem>[];
    for (final key in keys) {
      final meta = TmdService.instance.metaFor(key);
      if (meta == null) continue;
      final movie = meta.movie;
      if (movie.id == 0) continue;
      final parsed = ParsedFileName.parse(key);
      items.add(
        TraktWatchItem(
          tmdbId: movie.id,
          isTv: movie.kind == TmdKind.tv,
          season: parsed.isEpisode ? parsed.season : null,
          episode: parsed.isEpisode ? parsed.episode : null,
        ),
      );
    }
    return items;
  }
}

/// Device-flow dialog: shows the user code + activation URL and polls in the
/// background until the user authorizes (or the code expires).
class _TraktConnectDialog extends StatefulWidget {
  const _TraktConnectDialog({required this.client, required this.code});

  final TraktClient client;
  final TraktDeviceCode code;

  @override
  State<_TraktConnectDialog> createState() => _TraktConnectDialogState();
}

class _TraktConnectDialogState extends State<_TraktConnectDialog> {
  String _status = 'Waiting for authorization…';

  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    try {
      final ok = await widget.client.pollForToken(widget.code);
      if (!mounted) return;
      setState(() {
        _status = ok ? 'Connected!' : 'Timed out — try again.';
      });
      if (ok) {
        // First pull right after connecting so watched checks appear fast.
        unawaited(TraktSync.pullWatched(force: true));
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (mounted) Navigator.of(context).pop();
      }
    } on TraktException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Connect Trakt'),
      // Scroll-wrapped: a fixed Column here sat within ~5% of the dialog
      // height ceiling at the app's 1.3x text-scale clamp in phone landscape.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Go to the address below and enter this code:'),
            const SizedBox(height: 12),
            Center(
              child: Text(
                widget.code.userCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                widget.code.verificationUrl,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
