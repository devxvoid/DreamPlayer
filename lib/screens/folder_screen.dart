import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import 'tmd_details_screen.dart';

/// The contents of a library folder. For a TV-show folder this is the episode
/// list; subfolders navigate one level at a time. Videos open their TMDB
/// details page (Play/Resume) instead of playing directly. Home routes folder
/// taps to `TmdDetailsScreen(folder:)`; this screen is used for subfolder
/// navigation once you're inside.
class FolderScreen extends StatefulWidget {
  const FolderScreen({super.key, required this.folder, this.initialPath});

  final LibraryFolder folder;

  /// Start browsing at this subfolder instead of the folder root (deep links
  /// from the details screen's episode list).
  final String? initialPath;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  static final FileBrowserService _service = FileBrowserService.instance;

  late String _currentPath;
  List<FileEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  bool get _atRoot => _currentPath == widget.folder.path;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath ?? widget.folder.path;
    TmdService.instance.addListener(_onMetadataChanged);
    _resolveMeta();
    _load();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolveMeta() async {
    try {
      await TmdService.instance
          .resolveFolder(widget.folder.metadataKey, widget.folder.name);
    } catch (_) {
      // Non-fatal: the header just stays a placeholder.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service.listDirectory(_currentPath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? 'Could not list this folder';
        _loading = false;
      });
    }
  }

  Future<void> _openEntry(FileEntry entry) async {
    if (entry.isDirectory) {
      setState(() => _currentPath = entry.path);
      await _load();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: _toVideoItem(entry)),
      ),
    );
    // Resume positions may have changed while playing.
    await _load();
  }

  VideoItem _toVideoItem(FileEntry entry) {
    // Bookmarked-tree videos come back as content:// URIs (no real file
    // path), so hand those to the player's `uri` field.
    final isContentUri = entry.path.startsWith('content://');
    return VideoItem(
      id: 'folder_${widget.folder.id}_${entry.path.hashCode}',
      title: entry.name,
      path: isContentUri ? null : entry.path,
      uri: isContentUri ? entry.path : null,
      resumeKey: entry.resumeKey,
      duration: Duration.zero,
      sizeBytes: entry.size,
    );
  }

  Future<void> _goUp() async {
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _currentPath = _parentOf(_currentPath) ?? widget.folder.path);
    await _load();
  }

  static String? _parentOf(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return null;
    return path.substring(0, index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _atRoot ? widget.folder.name : (_currentPath.split('/').lastOrNull ?? ''),
        ),
        leading: IconButton(
          tooltip: 'Up',
          icon: const Icon(Icons.arrow_back),
          onPressed: _goUp,
        ),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Error: $_error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    return Column(
      children: [
        if (_atRoot) _header(context),
        Expanded(
          child: _entries.isEmpty
              ? const Center(child: Text('No videos or folders here'))
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return _FolderTile(
                      entry: entry,
                      onTap: () => _openEntry(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final meta = TmdService.instance.metaFor(widget.folder.metadataKey);
    final movie = meta?.movie;
    final backdrop = movie?.backdropUrl();
    final videoCount = _entries.where((e) => !e.isDirectory).length;

    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          if (backdrop != null)
            Image.network(
              backdrop,
              height: 140,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: backdrop != null ? 0.55 : 0.0),
                  Colors.transparent,
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        movie?.title.isNotEmpty == true
                            ? movie!.title
                            : widget.folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _headerSubtitle(movie, videoCount),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _headerSubtitle(TmdMovie? movie, int videoCount) {
    final countLabel = videoCount == 1 ? '1 video' : '$videoCount videos';
    if (movie == null) return countLabel;
    final parts = <String>[
      if (movie.kind == TmdKind.tv) 'TV Series',
      if (movie.year != null) '${movie.year}',
      countLabel,
    ];
    return parts.join(' · ');
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.entry, required this.onTap});

  final FileEntry entry;
  final VoidCallback onTap;

  static String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (entry.isDirectory) {
      return ListTile(
        leading: Icon(Icons.folder, color: colorScheme.primary),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }

    // Episode files get their parsed SxxExx label next to the size.
    final parsed = ParsedFileName.parse(entry.name);
    final subtitle = <String>[
      if (parsed.isEpisode) parsed.episodeLabel,
      _sizeLabel(entry.size),
    ].where((s) => s.isNotEmpty).join(' · ');

    return ListTile(
      leading: Icon(
        parsed.isEpisode ? Icons.movie_outlined : Icons.play_circle_outline,
        color: colorScheme.secondary,
      ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: onTap,
    );
  }
}
