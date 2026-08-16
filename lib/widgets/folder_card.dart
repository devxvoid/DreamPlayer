import 'package:flutter/material.dart';

import '../services/library_folders.dart';
import '../services/tmdb_client.dart';

/// Library card for a user-added folder. Shows the folder's TMDB match (poster
/// art, real title, year, TV/Movie chip) when one resolves, or a gradient +
/// folder icon placeholder otherwise.
class FolderCard extends StatelessWidget {
  const FolderCard({
    super.key,
    required this.folder,
    required this.tmdbMeta,
    required this.onTap,
    this.onLongPress,
  });

  final LibraryFolder folder;
  final TmdMeta? tmdbMeta;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final movie = tmdbMeta?.movie;
    final hasMeta = movie != null && movie.title.isNotEmpty;
    final title = hasMeta ? movie.title : folder.name;
    final subtitle = hasMeta
        ? [
            if (movie.year != null) '${movie.year}',
            movie.kind == TmdKind.tv ? 'TV Series' : 'Movie',
          ].join(' · ')
        : folder.name;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
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
                  if (hasMeta && movie.posterUrl() != null)
                    Image.network(
                      movie.posterUrl()!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      loadingBuilder: (context, child, progress) =>
                          progress == null ? child : const SizedBox.shrink(),
                    ),
                  if (hasMeta)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _FolderBadge(
                        label: movie.kind == TmdKind.tv ? 'TV' : 'Movie',
                        background: movie.kind == TmdKind.tv
                            ? const Color(0xFF9C27B0)
                            : const Color(0xFF1565C0),
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
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
