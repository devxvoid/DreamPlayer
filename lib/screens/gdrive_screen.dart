import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/cloud_keys.dart';
import '../models/video_item.dart';
import '../services/gdrive_client.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import '../widgets/tv_overscan.dart';
import '../widgets/tv_tile.dart';
import 'tmd_details_screen.dart';

/// Google Drive browser: signed-in accounts → folders → videos.
/// Playback streams `https://www.googleapis.com/drive/v3/files/{id}?alt=media`
/// with a fresh `Authorization: Bearer …` header per open (same httpHeaders
/// contract as WebDAV/SMB).
class GDriveScreen extends StatefulWidget {
  const GDriveScreen({super.key});

  @override
  State<GDriveScreen> createState() => _GDriveScreenState();
}

class _GDriveScreenState extends State<GDriveScreen> {
  static final GDriveClient _gdrive = GDriveClient.instance;

  List<GDriveAccount> _accounts = const [];
  GDriveAccount? _active;
  // Navigation stack of folder ids/names. Root = 'root'.
  final List<GDriveEntry> _crumbs = [];
  String get _folderId => _crumbs.isEmpty ? 'root' : _crumbs.last.id;
  String get _folderName => _crumbs.isEmpty ? 'Google Drive' : _crumbs.last.name;

  List<GDriveEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  bool _signingIn = false;

  bool get _atAccountList => _active == null;

  @override
  void initState() {
    super.initState();
    TmdService.instance.addListener(_onMetadataChanged);
    _loadAccounts();
  }

  @override
  void dispose() {
    TmdService.instance.removeListener(_onMetadataChanged);
    super.dispose();
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final accounts = await _gdrive.listAccounts();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  Future<void> _signIn() async {
    if (gdriveClientId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google Drive not configured (GDRIVE_CLIENT_ID)')),
      );
      return;
    }
    setState(() => _signingIn = true);
    try {
      final account = await _gdrive.signIn(
        clientId: gdriveClientId,
        clientSecret: gdriveClientSecret,
      );
      if (!mounted) return;
      setState(() => _signingIn = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Signed in as ${account.email}')),
      );
      await _loadAccounts();
      // Auto-open the new account.
      await _openAccount(account);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _signingIn = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Sign-in failed')),
      );
    }
  }

  Future<void> _openAccount(GDriveAccount account) async {
    setState(() {
      _active = account;
      _crumbs.clear();
      _loading = true;
      _error = null;
    });
    await _loadDirectory();
  }

  Future<void> _loadDirectory() async {
    final account = _active;
    if (account == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _gdrive.listDirectory(account.id, _folderId);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      _prefetchTmdbMeta(entries);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  void _prefetchTmdbMeta(List<GDriveEntry> entries) {
    final account = _active;
    if (account == null) return;
    final service = TmdService.instance;
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      service
          .resolve(VideoItem(
            id: 'gdrive_${account.id}_${entry.id}',
            title: entry.name,
            uri: '',
            resumeKey: 'gdrive:${account.id}/${entry.id}',
            duration: Duration.zero,
            sizeBytes: entry.size,
          ))
          .catchError((_) => null);
    }
  }

  Future<void> _openEntry(GDriveEntry entry) async {
    if (entry.isDirectory) {
      setState(() => _crumbs.add(entry));
      await _loadDirectory();
      return;
    }
    final account = _active;
    if (account == null) return;

    String authHeader;
    try {
      authHeader = await _gdrive.authorizationHeader(account.id);
    } on PlatformException {
      authHeader = '';
    }
    if (!mounted) return;

    final video = VideoItem(
      id: 'gdrive_${account.id}_${entry.id}',
      title: entry.name,
      uri: 'https://www.googleapis.com/drive/v3/files/${entry.id}?alt=media',
      resumeKey: 'gdrive:${account.id}/${entry.id}',
      duration: Duration.zero,
      sizeBytes: entry.size,
      httpHeaders: authHeader.isEmpty ? const {} : {'Authorization': authHeader},
    );

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: video),
      ),
    );
  }

  Future<void> _goUp() async {
    if (_active == null) {
      Navigator.of(context).pop();
      return;
    }
    if (_crumbs.isNotEmpty) {
      setState(() => _crumbs.removeLast());
      await _loadDirectory();
    } else {
      setState(() {
        _active = null;
        _entries = const [];
        _loading = false;
      });
      await _loadAccounts();
    }
  }

  Future<void> _bookmarkCurrentFolder() async {
    final account = _active;
    if (account == null || _crumbs.isEmpty) return;
    final folder = _crumbs.last;
    final id = 'gdrive_${account.id}_${folder.id}';
    final lf = LibraryFolder(
      id: id,
      name: folder.name,
      path: 'gdrive:${account.id}/${folder.id}',
      addedAt: DateTime.now(),
      source: LibraryFolderSource.gdrive,
      networkServerId: account.id,
      networkPath: folder.id,
      networkLabel: account.email,
    );
    await LibraryFoldersStore.add(lf);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bookmarked ${folder.name} to Home (GDrive)')),
      );
    }
  }

  Future<void> _signOut(GDriveAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text('Remove ${account.email} from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _gdrive.signOut(account.id);
    if (!mounted) return;
    if (_active?.id == account.id) {
      setState(() {
        _active = null;
        _crumbs.clear();
      });
    }
    _loadAccounts();
  }

  @override
  Widget build(BuildContext context) {
    final account = _active;
    final title = account == null ? 'Google Drive' : _folderName;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: account != null || _accounts.isNotEmpty
            ? IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_back),
                onPressed: _goUp,
              )
            : null,
        actions: [
          if (account != null && _crumbs.isNotEmpty)
            IconButton(
              tooltip: 'Bookmark this folder to Home',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _bookmarkCurrentFolder,
            ),
          if (account != null)
            IconButton(
              tooltip: 'Accounts',
              icon: const Icon(Icons.switch_account_outlined),
              onPressed: () => setState(() {
                _active = null;
                _crumbs.clear();
                _loading = false;
              }),
            ),
        ],
      ),
      floatingActionButton: _atAccountList
          ? FloatingActionButton.extended(
              onPressed: _signingIn ? null : _signIn,
              icon: _signingIn
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(_signingIn ? 'Signing in…' : 'Add account'),
            )
          : null,
      body: TvOverscan(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                'Error: $_error',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _atAccountList ? _loadAccounts : _loadDirectory,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_atAccountList) return _accountList(context);
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nothing here',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        final meta = entry.isDirectory || _active == null
            ? null
            : TmdService.instance.metaFor('gdrive:${_active!.id}/${entry.id}');
        return _GDriveTile(entry: entry, tmdbMeta: meta, onTap: () => _openEntry(entry));
      },
    );
  }

  Widget _accountList(BuildContext context) {
    if (_accounts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 48, color: Colors.white38),
            SizedBox(height: 12),
            Text('No accounts yet', style: TextStyle(color: Colors.white54)),
            SizedBox(height: 8),
            Text('Tap Add account to sign in', style: TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadAccounts,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const _SectionHeader('Signed in'),
          for (final account in _accounts)
            TvTile(
              leading: const Icon(Icons.account_circle),
              title: Text(account.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(account.email, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'signout') _signOut(account);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'signout', child: Text('Sign out')),
                ],
              ),
              onTap: () => _openAccount(account),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _GDriveTile extends StatelessWidget {
  const _GDriveTile({
    required this.entry,
    required this.tmdbMeta,
    required this.onTap,
  });

  final GDriveEntry entry;
  final TmdMeta? tmdbMeta;
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
    final icon = entry.isDirectory ? Icons.folder : Icons.play_circle_outline;
    final color = entry.isDirectory ? colorScheme.primary : colorScheme.secondary;
    final subtitle = entry.isDirectory ? null : _sizeLabel(entry.size);
    final posterUrl = posterUrlOf(tmdbMeta);
    return TvTile(
      leading: posterUrl != null ? _Poster(posterUrl: posterUrl) : Icon(icon, color: color),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.posterUrl});

  final String posterUrl;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        posterUrl,
        width: 48,
        height: 72,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          Icons.play_circle_outline,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}
