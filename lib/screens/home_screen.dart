import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show appRouteObserver;
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_client.dart';
import '../widgets/video_card.dart';
import 'file_browser_screen.dart';
import 'jellyfin_screen.dart';
import 'tmd_details_screen.dart';
import 'webdav_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.refreshTick});

  /// Notifies the screen that it became visible again (e.g. the Library tab
  /// was re-selected) so it can reload its continue-watching list.
  final Listenable? refreshTick;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  /// "Continue watching": videos with a saved resume position, most recently
  /// played first (persisted via [ContinueWatchingStore]).
  List<ContinueWatchingEntry> _entries = const [];

  final JellyfinClient _client = JellyfinClient();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.refreshTick?.addListener(_loadLibrary);
    // Reload whenever the persisted list changes (e.g. a save or remove).
    ContinueWatchingStore.changes.addListener(_loadLibrary);
    // Update cards when TMDB metadata resolves for a visible entry.
    TmdService.instance.addListener(_onMetadataChanged);
    _loadLibrary();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    widget.refreshTick?.removeListener(_loadLibrary);
    ContinueWatchingStore.changes.removeListener(_loadLibrary);
    TmdService.instance.removeListener(_onMetadataChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A route pushed above Home popped (file browser, player, "Open with"), so
  /// resume positions may have changed — refresh the continue-watching list.
  @override
  void didPopNext() {
    _loadLibrary();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The list may have changed while the app was in the background (e.g. the
    // player paused and saved a resume position), so refresh on return.
    if (state == AppLifecycleState.resumed) _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final entries = await ContinueWatchingStore.load();
    if (mounted) {
      setState(() => _entries = entries);
    }
    _resolveMetadata(entries);
  }

  /// Best-effort TMDB lookups so cards can show poster art and real titles
  /// without waiting for a tap.
  Future<void> _resolveMetadata(List<ContinueWatchingEntry> entries) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    for (final e in entries) {
      final video = e.video;
      final key = TmdStore.identityKeyFor(video);
      if (service.metaFor(key) != null) continue;
      try {
        await service.resolve(video);
      } catch (_) {
        // Network failures are non-fatal; the card just stays a placeholder.
      }
    }
  }

  Future<void> _removeVideo(ContinueWatchingEntry entry) async {
    final video = entry.video;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from Continue watching?'),
        content: Text('"${video.title}" will no longer appear here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final key = ContinueWatchingStore.keyFor(video);
    await ContinueWatchingStore.remove(key);
    if (!mounted) return;
    setState(() {
      _entries = _entries
          .where((e) => ContinueWatchingStore.keyFor(e.video) != key)
          .toList();
    });
  }

  void _openVideo(ContinueWatchingEntry entry) async {
    // iOS: re-grant security-scoped access to the picked file if it's outside
    // the sandbox (the picker's grant expires between launches). Covers both
    // per-file imported videos and files inside bookmarked folders.
    if (entry.video.path != null) {
      await FileBrowserService.instance.resolvePath(entry.video.path!);
    }
    if (!mounted) return;
    final video = await _restoreWebDavSource(entry.video);
    if (!mounted) return;
    final restored = await _restoreJellyfinSource(video);
    if (!mounted) return;
    // Open the details page first; Play launches the player from there.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: restored),
      ),
    );
    // Resume positions may have changed while playing — refresh on return.
    await _loadLibrary();
  }

  /// WebDAV entries deliberately do NOT persist the Authorization header (no
  /// plaintext credentials). The saved key encodes the server id + path, so
  /// rebuild the source with a freshly-fetched header and the server's current
  /// URL when the user taps a continue-watching card.
  Future<VideoItem> _restoreWebDavSource(VideoItem video) async {
    final key = video.resumeKey;
    if (key == null || !key.startsWith('webdav_')) return video;
    final rest = key.substring('webdav_'.length);
    // Server id = leading UUID (or legacy integer id), the rest is the path.
    final id = RegExp('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
            .firstMatch(rest)
            ?.group(0) ??
        RegExp(r'^\d+').firstMatch(rest)?.group(0);
    if (id == null || rest.length <= id.length) return video;
    try {
      final servers = await WebDavClient.instance.listServers();
      WebDavServer? server;
      for (final s in servers) {
        if (s.id == id) {
          server = s;
          break;
        }
      }
      if (server == null) return video;
      var auth = '';
      try {
        auth = await WebDavClient.instance.authorizationHeader(id);
      } on PlatformException {
        auth = '';
      }
      final path = rest.substring(id.length);
      final base = server.url.replaceAll(RegExp(r'/+$'), '');
      return VideoItem(
        id: video.id,
        title: video.title,
        uri: '$base${_encodePath(path)}',
        resumeKey: key,
        duration: video.duration,
        sizeBytes: video.sizeBytes,
        httpHeaders: auth.isEmpty ? const {} : {'Authorization': auth},
        allowSelfSigned: server.allowSelfSigned,
      );
    } on PlatformException {
      return video;
    }
  }

  /// Jellyfin stream URLs embed the session's `api_key`, which rotates on
  /// re-login. Rebuild the URL from the stable resume key
  /// (`jellyfin:<host>/<item>`) against the current saved server + token.
  Future<VideoItem> _restoreJellyfinSource(VideoItem video) async {
    final key = video.resumeKey;
    if (key == null || !key.startsWith('jellyfin:')) return video;
    final rest = key.substring('jellyfin:'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return video;
    final host = rest.substring(0, slash);
    final itemId = rest.substring(slash + 1);
    if (host.isEmpty || itemId.isEmpty) return video;
    final servers = await _client.loadServers();
    JellyfinServer? server;
    for (final s in servers) {
      if (s.urlHost == host) {
        server = s;
        break;
      }
    }
    if (server == null || !server.isAuthenticated) return video;
    final item = JellyfinItem(id: itemId, name: video.title);
    return VideoItem(
      id: video.id,
      title: video.title,
      uri: _client.streamUrl(server, item),
      resumeKey: key,
      duration: video.duration,
      sizeBytes: video.sizeBytes,
      allowSelfSigned: server.allowSelfSigned,
      jellyfinServerId: server.urlHost,
      jellyfinItemId: itemId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                'Continue watching',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (_entries.isEmpty)
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
                        final entry = _entries[index];
                        final video = entry.video;
                        final progress = video.duration > Duration.zero
                            ? (entry.position.inMilliseconds /
                                  video.duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : null;
                        final parsed = ParsedFileName.parse(video.title);
                        final continueLabel =
                            'Continue from ${_positionLabel(entry.position)}';
                        return VideoCard(
                          video: video,
                          tmdbMeta: TmdService.instance
                              .metaFor(TmdStore.identityKeyFor(video)),
                          progress: progress,
                          subtitle: parsed.isEpisode
                              ? '${parsed.episodeLabel} · $continueLabel'
                              : continueLabel,
                          onTap: () => _openVideo(entry),
                          onLongPress: () => _removeVideo(entry),
                        );
                      },
                      childCount: _entries.length,
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
              leading: const Icon(Icons.live_tv_outlined),
              title: const Text('Jellyfin'),
              subtitle: const Text('Jellyfin / Emby media server'),
              onTap: () => Navigator.of(context).pop('jellyfin'),
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
      case 'jellyfin':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const JellyfinScreen()),
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

  /// Percent-encodes each path segment (mirrors `_encodePath` in
  /// `webdav_screen.dart`).
  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  static String _positionLabel(Duration position) {
    final minutes = position.inMinutes;
    final seconds = position.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
              'Nothing to continue yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Play a video from your storage or a WebDAV server and it '
              'will show up here so you can pick up where you left off.',
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
