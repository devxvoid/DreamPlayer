import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show appRouteObserver;
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/file_browser.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_client.dart';
import '../widgets/folder_card.dart';
import '../widgets/video_card.dart';
import 'file_browser_screen.dart';
import 'jellyfin_screen.dart';
import 'smb_screen.dart';
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

  /// "Your library": the folders the user added (e.g. TV-show folders), most
  /// recently added first. Nothing is auto-scanned — only these appear.
  List<LibraryFolder> _folders = const [];

  /// Cached server-side metadata for the [JellyfinItemInfo] folders, keyed by
  /// `LibraryFolder.id` (fetch-on-bookmark, refreshed on open).
  Map<String, JellyfinItemInfo> _jellyfinMeta = const {};

  final JellyfinClient _client = JellyfinClient();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.refreshTick?.addListener(_loadLibrary);
    // Reload whenever the persisted list changes (e.g. a save or remove).
    ContinueWatchingStore.changes.addListener(_loadLibrary);
    LibraryFoldersStore.changes.addListener(_loadLibrary);
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
    LibraryFoldersStore.changes.removeListener(_loadLibrary);
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
    _loadLibraryFolders();
    if (mounted) {
      setState(() => _entries = entries);
    }
    _resolveMetadata(entries);
  }

  /// Loads the "Your library" folder list, then kicks off best-effort TMDB
  /// lookups so each folder card can show the show's poster.
  Future<void> _loadLibraryFolders() async {
    final folders = await LibraryFoldersStore.load();
    final metas = await _client.loadAllFolderMeta();
    if (mounted) {
      setState(() {
        _folders = folders;
        _jellyfinMeta = metas;
      });
    }
    _resolveFolderMetadata(folders);
    _refreshJellyfinMeta(folders);
  }

  /// Best-effort server-side metadata for the Jellyfin library folders: any
  /// folder with no cached entry gets its info fetched from the server (the
  /// bookmark flow already saves it, so this only fills gaps).
  Future<void> _refreshJellyfinMeta(List<LibraryFolder> folders) async {
    for (final folder in folders) {
      if (!folder.isJellyfin || _jellyfinMeta.containsKey(folder.id)) continue;
      final itemId = folder.jellyfinItemId;
      if (itemId == null || itemId.isEmpty) continue;
      try {
        final server =
            await _client.serverForUrl(folder.jellyfinServerUrl ?? '');
        if (server == null || !server.isAuthenticated) continue;
        final info = await _client.getPrimaryPosterInfo(server, itemId);
        if (info == null) continue;
        await _client.saveFolderMeta(folder.id, info);
        if (mounted) {
          setState(() {
            _jellyfinMeta = {..._jellyfinMeta, folder.id: info};
          });
        }
      } catch (_) {
        // Best-effort — the card falls back to the folder name / TMDB lookup.
      }
    }
  }

  Future<void> _resolveFolderMetadata(List<LibraryFolder> folders) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    for (final folder in folders) {
      final key = folder.metadataKey;
      if (service.metaFor(key) == null) {
        try {
          await service.resolveFolder(key, folder.name);
        } catch (_) {
          // Network failures are non-fatal; the card stays a placeholder.
          continue;
        }
      }
      // Pull the full details (backdrop/overview/cast) right away so the
      // folder's details screen is complete the moment it's opened — metadata
      // is fetched when the folder is added, not when it's opened.
      try {
        await service.detailsFor(key);
      } catch (_) {}
    }
  }

  /// Presents the system folder picker and adds the picked folder to the
  /// library. The folder becomes a card on home only — it is stored under its
  /// own library bookmark, so it never shows up as an Internal-storage root;
  /// its videos stay in place.
  Future<void> _addFolderToLibrary() async {
    final FileEntry? picked;
    try {
      picked = await FileBrowserService.instance.pickLibraryFolder();
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not pick a folder')),
      );
      return;
    }
    if (picked == null || !mounted) return;
    final folder = LibraryFolder(
      id: picked.bookmarkId ??
          'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: picked.name,
      path: picked.path,
      addedAt: DateTime.now(),
    );
    await LibraryFoldersStore.add(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${picked.name}" added to your library')),
    );
    // TMDB poster for the new card resolves in the background.
    _resolveFolderMetadata([folder]);
  }

  /// Opens a library folder: the show/movie details screen with the folder's
  /// files (episodes) listed below it.
  void _openFolder(LibraryFolder folder) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(
          folder: folder,
          jellyfinInfo: _jellyfinMeta[folder.id],
        ),
      ),
    );
    await _loadLibrary();
  }

  Future<void> _removeFolder(LibraryFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from library?'),
        content: Text(
          '"${folder.name}" will no longer appear here. '
          'The files stay on your device.',
        ),
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
    await LibraryFoldersStore.remove(folder.id);
    // Release the native library bookmark so its grant doesn't linger (only
    // for on-device folders — Jellyfin bookmarks have no native grant).
    if (!folder.isJellyfin) {
      try {
        await FileBrowserService.instance.removeLibraryBookmark(folder.id);
      } catch (_) {}
    } else {
      // Drop the cached server-side metadata too so a re-add re-fetches fresh.
      try {
        await _client.removeFolderMeta(folder.id);
      } catch (_) {}
    }
    // Drop the folder's TMDB metadata too so a re-add re-matches cleanly.
    try {
      await TmdService.instance.clear(folder.metadataKey);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _folders = _folders.where((f) => f.id != folder.id).toList();
    });
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
          // ---- Your library: user-added folders (e.g. TV-show folders) ----
          if (_folders.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  'No folders yet. Tap + to add one.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Your library',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            _folderGridSliver(
              count: _folders.length,
              itemBuilder: (context, index) {
                final folder = _folders[index];
                return FolderCard(
                  folder: folder,
                  tmdbMeta: TmdService.instance.metaFor(folder.metadataKey),
                  jellyfinInfo: _jellyfinMeta[folder.id],
                  onTap: () => _openFolder(folder),
                  onLongPress: () => _removeFolder(folder),
                );
              },
            ),
          ],
          // ---- Continue watching ----
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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
            _videoGridSliver(
              count: _entries.length,
              itemBuilder: (context, index) {
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

  /// A responsive grid of video cards (columns from the screen width), shared
  /// by the "Continue watching" section.
  Widget _videoGridSliver({
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    return SliverPadding(
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
              itemBuilder,
              childCount: count,
            ),
          );
        },
      ),
    );
  }

  /// A responsive grid of folder cards with poster-sized cells (2:3).
  Widget _folderGridSliver({
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final columns = _columnsForWidth(width);
          const spacing = 14.0;
          final itemWidth = (width - spacing * (columns - 1)) / columns;
          final itemHeight = itemWidth * 3 / 2 + _textBlockHeight;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              mainAxisExtent: itemHeight,
            ),
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: count,
            ),
          );
        },
      ),
    );
  }

  /// Opens the "+" menu: WebDAV server, internal storage, add folder, Jellyfin.
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
              leading: const Icon(Icons.folder_shared_outlined),
              title: const Text('Network shares'),
              subtitle: const Text('SMB / NAS shares'),
              onTap: () => Navigator.of(context).pop('smb'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Add folder to library'),
              subtitle: const Text('A TV-show folder, a movie folder\u2026'),
              onTap: () => Navigator.of(context).pop('add-folder'),
            ),
            ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('Internal storage'),
              subtitle: const Text('Browse files on this device'),
              onTap: () => Navigator.of(context).pop('storage'),
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
      case 'smb':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SmbScreen()),
        );
        break;
      case 'storage':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FileBrowserScreen()),
        );
      case 'add-folder':
        await _addFolderToLibrary();
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
              'Nothing yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Videos you play will appear here.',
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
