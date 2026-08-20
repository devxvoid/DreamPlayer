import 'package:flutter/material.dart';

import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../utils/tv_helper.dart';

/// Library card for a user-added folder. Shows the folder's TMDB match (poster
/// art, real title, year, TV/Movie chip) when one resolves, otherwise the
/// server-provided [JellyfinItemInfo] for Jellyfin folders, otherwise a
/// gradient + folder icon placeholder.
class FolderCard extends StatefulWidget {
  const FolderCard({
    super.key,
    required this.folder,
    required this.tmdbMeta,
    this.jellyfinInfo,
    required this.onTap,
    this.onLongPress,
  });

  final LibraryFolder folder;
  final TmdMeta? tmdbMeta;

  /// Server-side metadata for a Jellyfin library folder (poster/title/year),
  /// used when no TMDB match is available.
  final JellyfinItemInfo? jellyfinInfo;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<FolderCard> createState() => _FolderCardState();
}

class _FolderCardState extends State<FolderCard> {
  /// Owned focus node handed to the InkWell. Putting focus directly on the
  /// InkWell (rather than a wrapping `Focus`) means D-pad traversal reaches the
  /// card AND `select`/enter activates it through the InkWell's own
  /// ActivateIntent handler. The highlight follows the node via
  /// [ListenableBuilder].
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final folder = widget.folder;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final movie = widget.tmdbMeta?.movie;
    final hasMeta = movie != null && movie.title.isNotEmpty;
    final info = widget.jellyfinInfo;
    final hasJellyfin = info != null && info.name.isNotEmpty;
    final title = hasMeta
        ? movie.title
        : (hasJellyfin ? info.name : folder.name);
    final subtitle = hasMeta
        ? [
            if (movie.year != null) '${movie.year}',
            movie.kind == TmdKind.tv ? 'TV Series' : 'Movie',
            if (folder.isJellyfin) 'Jellyfin',
          ].join(' · ')
        : hasJellyfin
            ? [
                if (info.kindLabel.isNotEmpty) info.kindLabel,
                if (info.year != null) '${info.year}',
                'Jellyfin',
              ].where((s) => s.isNotEmpty).join(' · ')
            : [
                if (folder.name.isNotEmpty) folder.name,
                if (folder.isJellyfin) 'Jellyfin',
              ].join(' · ');

    // Poster: TMDB when matched, else the Jellyfin server art, else the
    // gradient placeholder.
    final posterUrl = hasMeta
        ? movie.posterUrl()
        : (hasJellyfin ? info.imageUrl : null);

    // TV/Movie badge: TMDB kind, else the Jellyfin type, else none.
    final kindBadge = hasMeta
        ? (movie.kind == TmdKind.tv ? 'TV' : 'Movie')
        : (hasJellyfin && info.kindLabel.isNotEmpty
            ? (info.isTv ? 'TV' : 'Movie')
            : null);
    final kindColor = (hasMeta && movie.kind == TmdKind.tv) ||
            (hasJellyfin && info.isTv)
        ? const Color(0xFF9C27B0)
        : const Color(0xFF1565C0);

    final tv = isTvMode(context);

    return ListenableBuilder(
      listenable: _focusNode,
      builder: (context, _) {
        final focused = tv && _focusNode.hasFocus;
        return AnimatedScale(
          scale: focused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  )
                : null,
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                focusNode: _focusNode,
                onTap: onTap,
                onLongPress: onLongPress,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
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
                              child: Icon(
                                Icons.video_library_outlined,
                                size: 40,
                                color: Colors.white54,
                              ),
                            ),
                          ),
                          if (posterUrl != null)
                            Image.network(
                              posterUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                              loadingBuilder: (context, child, progress) =>
                                  progress == null
                                      ? child
                                      : const SizedBox.shrink(),
                            ),
                          if (kindBadge != null)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: _FolderBadge(
                                label: kindBadge,
                                background: kindColor,
                              ),
                            ),
                          if (folder.isJellyfin)
                            const Positioned(
                              top: 8,
                              left: 8,
                              child: _FolderBadge(
                                label: 'Jellyfin',
                                background: Color(0xFF00B8A9),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FolderBadge extends StatelessWidget {
  const _FolderBadge({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
