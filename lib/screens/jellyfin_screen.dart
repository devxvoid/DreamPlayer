import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import 'tmd_details_screen.dart';

/// Jellyfin / Emby browser: saved + discovered servers -> libraries -> folders
/// -> play. Playback streams the direct-play URL (token as `api_key` query
/// param) through the existing HTTP data sources on both platforms.
class JellyfinScreen extends StatefulWidget {
  const JellyfinScreen({super.key});

  @override
  State<JellyfinScreen> createState() => _JellyfinScreenState();
}

/// One level of the browse breadcrumb: the folder's display title and the
/// parent id used to load its children (empty stack = top-level libraries).
class _Crumb {
  const _Crumb(this.title, this.parentId);

  final String title;
  final String parentId;
}

class _JellyfinScreenState extends State<JellyfinScreen> {
  final JellyfinClient _client = JellyfinClient();

  List<JellyfinServer> _servers = const [];
  List<JellyfinServer> _discovered = const [];
  bool _scanning = false;

  JellyfinServer? _browsing;
  List<_Crumb> _crumbs = const [];
  List<JellyfinItem> _items = const [];
  bool _loading = true;
  String? _error;

  bool get _atBrowseRoot => _browsing == null;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final servers = await _client.loadServers();
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _loading = false;
    });
  }

  Future<void> _scanNetwork() async {
    setState(() {
      _scanning = true;
      _discovered = const [];
    });
    final found = await _client.discoverServers();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _discovered = found;
    });
  }

  // ---------------------------------------------------------------------------
  // Browsing
  // ---------------------------------------------------------------------------

  Future<void> _openServer(JellyfinServer server) async {
    if (!server.isAuthenticated) {
      final loggedIn = await _login(server);
      if (!mounted || loggedIn == null) return;
      server = loggedIn;
    }
    setState(() {
      _browsing = server;
      _crumbs = const [];
      _loading = true;
      _error = null;
    });
    await _loadLevel();
  }

  Future<void> _loadLevel() async {
    final server = _browsing;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = _crumbs.isEmpty
          ? await _client.getLibraries(server)
          : await _client.getItems(server, _crumbs.last.parentId);
      if (!mounted) return;
      // Folders first, then playables, each sorted by name.
      final folders = items.where((i) => i.isFolder).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final playables = items.where((i) => i.isPlayable).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _items = [...folders, ...playables];
        _loading = false;
      });
    } on JellyfinException catch (e) {
      if (!mounted) return;
      if (e.message.contains('Session expired')) {
        await _handleSessionExpired();
      } else {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = JellyfinClient.friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _handleSessionExpired() async {
    final server = _browsing;
    if (server == null) return;
    // Drop the dead token so the login dialog starts clean.
    final updated = server.copyWith(token: null, userId: null);
    await _replaceServer(updated);
    if (!mounted) return;
    final loggedIn = await _login(updated);
    if (!mounted || loggedIn == null) return;
    setState(() => _browsing = loggedIn);
    await _loadLevel();
  }

  Future<void> _openItem(JellyfinItem item) async {
    if (item.isFolder) {
      setState(() {
        _crumbs = [..._crumbs, _Crumb(item.name, item.id)];
        _loading = true;
      });
      await _loadLevel();
      return;
    }
    final server = _browsing;
    if (server == null || !item.isPlayable) return;
    final playables = _items.where((i) => i.isPlayable).toList();
    final playlist = [
      for (final playable in playables)
        VideoItem(
          id: 'jellyfin_${server.urlHost}_${playable.id}',
          title: playable.name,
          uri: _client.streamUrl(server, playable),
          resumeKey: _client.resumeKey(server, playable),
          duration: playable.duration,
          resolution: playable.resolution,
          allowSelfSigned: server.allowSelfSigned,
          jellyfinServerId: server.urlHost,
          jellyfinItemId: playable.id,
        ),
    ];
    final playIndex = playlist.indexWhere((video) => video.title == item.name);
    if (playIndex < 0 || playlist.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdDetailsScreen(video: playlist[playIndex]),
      ),
    );
  }

  Future<void> _goUp() async {
    if (_browsing == null) {
      Navigator.of(context).pop();
      return;
    }
    if (_crumbs.isNotEmpty) {
      setState(() {
        _crumbs = _crumbs.sublist(0, _crumbs.length - 1);
        _loading = true;
      });
      await _loadLevel();
    } else {
      setState(() {
        _browsing = null;
        _crumbs = const [];
        _loading = false;
      });
      await _loadServers();
    }
  }

  /// Adds the currently browsed folder (a TV-show/library folder) to the home
  /// library. The server URL + item id are persisted; the token is never — the
  /// entry is re-matched against the saved servers each time it's opened, so it
  /// keeps working across logins.
  Future<void> _addToLibrary(JellyfinItem item) async {
    final server = _browsing;
    if (server == null) return;
    final folder = LibraryFolder(
      id: 'jellyfin_folder_${server.urlHost}_${item.id}',
      name: item.name,
      path: 'jellyfin:${item.id}',
      addedAt: DateTime.now(),
      source: LibraryFolderSource.jellyfin,
      jellyfinServerUrl: server.url,
      jellyfinItemId: item.id,
    );
    await LibraryFoldersStore.add(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${item.name}" added to your library')),
    );
    // Fetch the series' own info from the server in the background so the home
    // card + details screen have the main poster/title/year/overview instantly.
    // Plain folders have no poster (Jellyfin answers with a random child
    // image), so the nearest Series ancestor's info is used instead.
    if (server.isAuthenticated) {
      try {
        final info = await _client.getPrimaryPosterInfo(server, item.id);
        if (info != null) {
          await _client.saveFolderMeta(folder.id, info);
        }
      } catch (_) {
        // Best-effort; the card falls back to the folder name / TMDB lookup.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Auth + server persistence
  // ---------------------------------------------------------------------------

  /// Prompts for username/password, authenticates, persists, returns the
  /// signed-in server (null if cancelled).
  Future<JellyfinServer?> _login(JellyfinServer server) async {
    final result = await showDialog<({String username, String password})>(
      context: context,
      builder: (_) => _LoginDialog(
        serverName: server.name,
        url: server.url,
        username: server.username,
        allowSelfSigned: server.allowSelfSigned,
      ),
    );
    if (result == null) return null;
    try {
      final authed = await _client.authenticate(
        server,
        username: result.username,
        password: result.password,
      );
      await _replaceServer(authed);
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Signed in to ${authed.name}')),
      );
      return authed;
    } on Exception catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(JellyfinClient.friendlyError(e))),
      );
      return null;
    }
  }

  Future<void> _replaceServer(JellyfinServer updated) async {
    final index = _servers.indexWhere((s) => s.url == updated.url);
    final servers = [..._servers];
    if (index >= 0) {
      servers[index] = updated;
    } else {
      servers.add(updated);
    }
    setState(() => _servers = servers);
    await _client.saveServers(servers);
  }

  Future<void> _deleteServer(JellyfinServer server) async {
    final servers = _servers.where((s) => s.url != server.url).toList();
    setState(() => _servers = servers);
    await _client.saveServers(servers);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Removed ${server.name}')));
  }

  void _addServer() => _showServerDialog();

  void _editServer(JellyfinServer server) => _showServerDialog(existing: server);

  void _showServerDialog({JellyfinServer? existing}) {
    showDialog<void>(
      context: context,
      builder: (_) => _ServerFormDialog(existing: existing, onSave: _loadServers),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final browsing = _browsing;
    return Scaffold(
      appBar: AppBar(
        title: Text(browsing == null ? 'Jellyfin' : _breadcrumbTitle(browsing)),
        leading: browsing != null
            ? IconButton(
                tooltip: 'Up',
                icon: const Icon(Icons.arrow_back),
                onPressed: _goUp,
              )
            : null,
        actions: [
          if (browsing != null)
            IconButton(
              tooltip: 'Server list',
              icon: const Icon(Icons.dns_outlined),
              onPressed: () => setState(() {
                _browsing = null;
                _crumbs = const [];
                _loading = false;
              }),
            )
          else
            IconButton(
              tooltip: 'Scan local network',
              icon: const Icon(Icons.wifi_find),
              onPressed: _scanning ? null : _scanNetwork,
            ),
        ],
      ),
      floatingActionButton: browsing == null
          ? FloatingActionButton.extended(
              onPressed: _addServer,
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            )
          : null,
      body: _body(context),
    );
  }

  String _breadcrumbTitle(JellyfinServer server) {
    if (_crumbs.isEmpty) return server.name;
    return '${server.name} / ${_crumbs.last.title}';
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
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
                  onPressed: _atBrowseRoot ? _loadServers : _goUp,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_browsing == null) return _serverList(context);
    if (_items.isEmpty) {
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
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return _JellyfinTile(
          item: item,
          onTap: () => _openItem(item),
          onAddToLibrary:
              item.isFolder ? () => _addToLibrary(item) : null,
        );
      },
    );
  }

  Widget _serverList(BuildContext context) {
    final theme = Theme.of(context);
    if (_servers.isEmpty && _discovered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.live_tv_outlined, size: 64),
                const SizedBox(height: 16),
                Text(
                  'Add your Jellyfin or Emby server to browse and play your '
                  'media library',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _addServer,
                  icon: const Icon(Icons.add),
                  label: const Text('Add server'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _scanning ? null : _scanNetwork,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find),
                  label: Text(
                    _scanning ? 'Scanning\u2026' : 'Scan local network',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadServers,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const _SectionHeader('Saved servers'),
          for (final server in _servers)
            ListTile(
              leading: const Icon(Icons.live_tv),
              title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                server.isAuthenticated
                    ? '${server.url} · Signed in as ${server.username}'
                    : '${server.url} · Not signed in',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'edit') {
                    _editServer(server);
                  } else if (action == 'delete') {
                    _deleteServer(server);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
              onTap: () => _openServer(server),
            ),
          if (_servers.isNotEmpty || _discovered.isNotEmpty)
            _SectionHeader('On this network'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.wifi_find, size: 20),
            title: Text(_scanning ? 'Scanning\u2026' : 'Scan local network'),
            trailing: _scanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _scanning ? null : _scanNetwork,
          ),
          for (final server in _discovered)
            ListTile(
              leading: const Icon(Icons.radar),
              title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _openServer(server),
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

class _JellyfinTile extends StatelessWidget {
  const _JellyfinTile({
    required this.item,
    required this.onTap,
    this.onAddToLibrary,
  });

  final JellyfinItem item;
  final VoidCallback onTap;

  /// Shown on folders as a "add to library" shortcut (replaces the plain
  /// chevron so both actions stay reachable).
  final VoidCallback? onAddToLibrary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = item.isFolder ? Icons.folder : Icons.play_circle_outline;
    final color = item.isFolder ? colorScheme.primary : colorScheme.secondary;
    final subtitle = item.isFolder ? null : item.durationLabel;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: item.isFolder
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onAddToLibrary != null)
                  IconButton(
                    tooltip: 'Add to library',
                    icon: const Icon(Icons.library_add_outlined),
                    onPressed: onAddToLibrary,
                  ),
                const Icon(Icons.chevron_right),
              ],
            )
          : null,
      onTap: onTap,
    );
  }
}

/// Add/edit server dialog. Test validates connectivity; Save persists and (when
/// credentials are supplied) authenticates immediately.
class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({this.existing, this.onSave});

  final JellyfinServer? existing;
  final VoidCallback? onSave;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  final JellyfinClient _client = JellyfinClient();

  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _allowSelfSigned;
  bool _testing = false;
  String? _resultMessage;
  bool? _resultSuccess;

  JellyfinServer? get _existing => widget.existing;

  @override
  void initState() {
    super.initState();
    final s = _existing;
    _name = TextEditingController(text: s?.name ?? '');
    _url = TextEditingController(text: s?.url ?? '');
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: '');
    _allowSelfSigned = s?.allowSelfSigned ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validate() {
    if (JellyfinClient.normalizeUrl(_url.text).isEmpty) {
      return 'Server URL is required';
    }
    return null;
  }

  Future<void> _test() async {
    final error = _validate();
    if (error != null) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = error;
      });
      return;
    }
    setState(() {
      _testing = true;
      _resultMessage = null;
      _resultSuccess = null;
    });
    try {
      final info = await _client.testConnection(
        _url.text,
        allowSelfSigned: _allowSelfSigned,
      );
      if (!mounted) return;
      // Auto-fill the display name from the server when left blank.
      if (_name.text.trim().isEmpty) _name.text = info.serverName;
      setState(() {
        _testing = false;
        _resultSuccess = true;
        _resultMessage =
            'Connected — ${info.serverName} (${info.version})';
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultSuccess = false;
        _resultMessage = JellyfinClient.friendlyError(e);
      });
    }
  }

  Future<void> _save() async {
    final error = _validate();
    if (error != null) {
      setState(() {
        _resultSuccess = false;
        _resultMessage = error;
      });
      return;
    }
    setState(() {
      _testing = true;
      _resultMessage = null;
      _resultSuccess = null;
    });
    try {
      final info = await _client.testConnection(
        _url.text,
        allowSelfSigned: _allowSelfSigned,
      );
      var server = JellyfinServer(
        name: _name.text.trim().isEmpty ? info.serverName : _name.text.trim(),
        url: JellyfinClient.normalizeUrl(_url.text),
        username: _username.text.trim(),
        token: _existing?.token,
        userId: _existing?.userId,
        allowSelfSigned: _allowSelfSigned,
      );
      // Re-auth when a password was entered (or when none exists yet).
      final password = _password.text;
      if (password.isNotEmpty || server.token == null) {
        if (password.isEmpty) {
          throw const JellyfinException('Enter a password to sign in.');
        }
        server = await _client.authenticate(
          server,
          username: _username.text.trim(),
          password: password,
        );
      }
      final servers = await _client.loadServers();
      final index = servers.indexWhere((s) => s.url == server.url);
      final updated = [...servers];
      if (index >= 0) {
        updated[index] = server;
      } else {
        updated.add(server);
      }
      await _client.saveServers(updated);
      widget.onSave?.call();
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultSuccess = false;
        _resultMessage = JellyfinClient.friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_existing == null ? 'Add server' : 'Edit server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Server name (optional)',
                      hintText: 'e.g. Home Jellyfin',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.16:8096',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'admin',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      hintText: _existing?.token != null
                          ? '(unchanged)'
                          : 'Your password',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Accept self-signed certificate'),
                    subtitle: const Text(
                      'For HTTPS servers without a trusted certificate (NAS, '
                      'etc.)',
                    ),
                    value: _allowSelfSigned,
                    onChanged: (v) => setState(() => _allowSelfSigned = v),
                  ),
                ],
              ),
            ),
          ),
          if (_resultMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _resultSuccess == true
                        ? Icons.check_circle
                        : Icons.error_outline,
                    size: 18,
                    color: _resultSuccess == true
                        ? const Color(0xFF4CAF50)
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _resultMessage!,
                      style: TextStyle(
                        color: _resultSuccess == true
                            ? const Color(0xFF4CAF50)
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : _test,
          child: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Test'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _testing ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

/// Username + password prompt for a server with no (or expired) token.
class _LoginDialog extends StatefulWidget {
  const _LoginDialog({
    required this.serverName,
    required this.url,
    this.username = '',
    required this.allowSelfSigned,
  });

  final String serverName;
  final String url;
  final String username;
  final bool allowSelfSigned;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late final TextEditingController _username;
  late final TextEditingController _password;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.username);
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() {
        _busy = false;
        _error = 'Enter your username.';
      });
      return;
    }
    if (_password.text.isEmpty) {
      setState(() {
        _busy = false;
        _error = 'Enter your password.';
      });
      return;
    }
    Navigator.of(context).pop((username: username, password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Sign in — ${widget.serverName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.url, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _username,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'admin',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Sign in'),
        ),
      ],
    );
  }
}
