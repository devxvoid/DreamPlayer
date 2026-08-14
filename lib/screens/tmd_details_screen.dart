import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/resume_store.dart';
import '../services/tmdb_client.dart';
import 'player_screen.dart';

/// Shows TMDB metadata for a single video (backdrop, poster, synopsis, rating,
/// genres, cast) with a Play/Resume button and a "Fix match" manual search.
class TmdDetailsScreen extends StatefulWidget {
  const TmdDetailsScreen({
    super.key,
    required this.video,
    this.playlist = const [],
    this.playlistIndex = 0,
  });

  final VideoItem video;

  /// Optional sibling playlist (play-next in the folder) handed to the player.
  final List<VideoItem> playlist;
  final int playlistIndex;

  @override
  State<TmdDetailsScreen> createState() => _TmdDetailsScreenState();
}

class _TmdDetailsScreenState extends State<TmdDetailsScreen> {
  late final String _identityKey = TmdStore.identityKeyFor(widget.video);
  late final String _resumeKey =
      widget.video.resumeKey ?? widget.video.path ?? widget.video.uri ?? '';
  late final ParsedFileName _parsed = ParsedFileName.parse(widget.video.title);
  final TmdService _service = TmdService.instance;

  TmdMeta? _meta;
  TmdDetails? _details;
  bool _loading = true;
  bool _loadingError = false;

  /// Underlying failure detail from the metadata lookup, shown verbatim when
  /// the lookup throws (never blame the user's network when it's TMDB-side).
  String? _errorMessage;

  /// Saved playhead for this video (mirrors the player's resume lookup), used
  /// to label the action button "Resume from m:ss" instead of "Play".
  Duration? _resumePosition;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _load();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final meta = _service.metaFor(_identityKey);
    setState(() {
      _meta = meta;
      _details = meta?.details;
    });
  }

  Future<void> _load() async {
    await _service.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _meta = _service.metaFor(_identityKey);
      _details = _meta?.details;
      _loading = _meta == null;
      _loadingError = false;
    });
    _loadResume();
    if (_meta != null) return;
    try {
      await _service.resolve(widget.video);
      if (!mounted) return;
      final meta = _service.metaFor(_identityKey);
      setState(() {
        _meta = meta;
        _loading = false;
      });
      if (meta != null) {
        final details = await _service.detailsFor(_identityKey);
        if (mounted) setState(() => _details = details);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingError = true;
          _errorMessage = e is TmdException ? e.message : null;
        });
      }
    }
  }

  /// Mirrors the player's resume rules: ignore trivial positions and
  /// "basically finished" ones.
  Future<void> _loadResume() async {
    if (_resumeKey.isEmpty) return;
    var position = await ResumeStore.positionFor(_resumeKey);
    if (position != null && position < const Duration(seconds: 10)) {
      position = null;
    }
    if (position != null &&
        widget.video.duration > Duration.zero &&
        widget.video.duration - position < const Duration(seconds: 5)) {
      position = null;
    }
    if (mounted && position != _resumePosition) {
      setState(() => _resumePosition = position);
    }
  }

  /// Clears a wrong auto-fetched (or manually pinned) match so the metadata
  /// is dropped everywhere (home cards included) and the screen falls back to
  /// the no-match state, where it can be re-searched or just played.
  Future<void> _removeInfo() async {
    await _service.clear(_identityKey);
    if (!mounted) return;
    setState(() {
      _meta = null;
      _details = null;
      _loading = false;
      _loadingError = false;
    });
  }

  Future<void> _fixMatch() async {
    final picked = await showDialog<TmdMovie>(
      context: context,
      builder: (context) => _SearchDialog(
        initialQuery: ParsedFileName.parse(widget.video.title).title,
      ),
    );
    if (picked == null || !mounted) return;
    await _service.setManual(widget.video, picked);
    if (!mounted) return;
    final meta = _service.metaFor(_identityKey);
    setState(() => _meta = meta);
    final details = await _service.detailsFor(_identityKey);
    if (mounted) setState(() => _details = details);
  }

  Future<void> _play() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          video: widget.video,
          playlist: widget.playlist,
          playlistIndex: widget.playlistIndex,
        ),
      ),
    );
    // The playhead may have moved (or the video finished) — refresh the label.
    await _loadResume();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _meta;
    final title = (meta?.movie.title.isNotEmpty ?? false)
        ? meta!.movie.title
        : widget.video.title;
    final resume = _resumePosition;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(theme, meta),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          // Always reachable: a metadata failure (or a slow lookup) must never
          // block playing the video, whatever the metadata state.
          child: FilledButton.icon(
            onPressed: _play,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            icon: const Icon(Icons.play_arrow),
            label: Text(
              resume != null
                  ? 'Resume from ${_formatClock(resume)}'
                  : 'Play',
            ),
          ),
        ),
      ),
    );
  }

  static String _formatClock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildBody(ThemeData theme, TmdMeta? meta) {
    if (meta == null) return _buildNoMatch(theme);
    final movie = meta.movie;
    final details = _details;
    final colorScheme = theme.colorScheme;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: movie.backdropUrl() != null
                    ? Image.network(
                        movie.backdropUrl()!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            _artworkFallback(colorScheme),
                        loadingBuilder: (context, child, progress) =>
                            progress == null ? child : _artworkFallback(colorScheme),
                      )
                    : _artworkFallback(colorScheme),
              ),
              Positioned(
                bottom: 8,
                right: 12,
                child: _RatingBadge(rating: movie.voteAverage),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: movie.posterUrl(width: 342) != null
                          ? Image.network(
                              movie.posterUrl(width: 342)!,
                              width: 104,
                              height: 156,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _posterFallback(colorScheme),
                            )
                          : _posterFallback(colorScheme),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_parsed.isEpisode)
                            Text(
                              _parsed.seasonEpisodeLabel,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (movie.year != null)
                            Text(
                              '${movie.year}',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (_parsed.isEpisode)
                                _FactChip(
                                  icon: Icons.tag,
                                  label: _parsed.episodeLabel,
                                ),
                              if (details?.runtimeMinutes != null)
                                _FactChip(
                                  icon: Icons.schedule,
                                  label:
                                      '${details!.runtimeMinutes} min',
                                ),
                              if (details?.genres != null)
                                for (final genre in details!.genres)
                                  _FactChip(label: genre),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            details?.tagline ?? '',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Overview',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  details?.overview ?? movie.overview,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Cast',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _removeInfo,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Remove info'),
                    ),
                    TextButton(
                      onPressed: _fixMatch,
                      child: const Text('Fix match'),
                    ),
                  ],
                ),
                if (details != null && details.cast.isNotEmpty)
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: details.cast.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) =>
                          _CastTile(member: details.cast[index]),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNoMatch(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_filter_outlined,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'Could not find "${widget.video.title}" on TMDB',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _loadingError
                  ? (_errorMessage ??
                      'Couldn\'t fetch metadata from TMDB. Play the video anyway '
                          'or try again in a moment.')
                  : 'No TMDB API key is bundled in this build, so metadata is '
                      'unavailable. Play the video anyway.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _fixMatch,
              icon: const Icon(Icons.search),
              label: const Text('Search TMDB'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _artworkFallback(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.tertiaryContainer,
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_filter, size: 48, color: Colors.white24),
      ),
    );
  }

  Widget _posterFallback(ColorScheme colorScheme) {
    return Container(
      width: 104,
      height: 156,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.movie, color: colorScheme.onSurfaceVariant),
    );
  }
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) {
    if (rating <= 0) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 14, color: Colors.amber),
          const SizedBox(width: 4),
          Text(
            rating.toStringAsFixed(1),
            style: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({this.icon, required this.label});

  final IconData? icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _CastTile extends StatelessWidget {
  const _CastTile({required this.member});

  final TmdCastMember member;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipOval(
            child: member.profileUrl(width: 185) != null
                ? Image.network(
                    member.profileUrl(width: 185)!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _avatarFallback(colorScheme),
                  )
                : _avatarFallback(colorScheme),
          ),
          const SizedBox(height: 6),
          Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (member.character != null)
            Text(
              member.character!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _avatarFallback(ColorScheme colorScheme) {
    return Container(
      width: 56,
      height: 56,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person, color: colorScheme.onSurfaceVariant),
    );
  }
}

/// Manual search dialog for picking the right TMDB entry.
class _SearchDialog extends StatefulWidget {
  const _SearchDialog({this.initialQuery});

  final String? initialQuery;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _controller = TextEditingController();
  final _api = TmdApi();

  List<TmdMovie>? _results;
  bool _searching = false;
  bool _noKey = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    final key = await _api.effectiveApiKey();
    if (!mounted) return;
    if (key.isEmpty) {
      setState(() {
        _searching = false;
        _results = null;
        _noKey = true;
      });
      return;
    }
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
      _noKey = false;
    });
    try {
      final results = await _api.search(query);
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Search TMDB'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                hintText: 'Movie title',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_noKey)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'TMDB search is unavailable in this build (no API key bundled).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.error),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.error),
                ),
              )
            else if (_results != null)
              if (_results!.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No results. Try a different title.'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results!.length,
                    itemBuilder: (context, index) {
                      final movie = _results![index];
                      return ListTile(
                        leading: movie.posterUrl(width: 92) != null
                            ? Image.network(
                                movie.posterUrl(width: 92)!,
                                width: 36,
                                height: 54,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.movie),
                              )
                            : const Icon(Icons.movie),
                        title: Text(movie.title),
                        subtitle: Text(
                          [
                            if (movie.year != null) '${movie.year}',
                            if (movie.voteAverage > 0)
                              movie.voteAverage.toStringAsFixed(1),
                          ].join('  ·  '),
                        ),
                        onTap: () => Navigator.of(context).pop(movie),
                      );
                    },
                  ),
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
