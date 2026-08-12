import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/smb_client.dart';
import 'player_screen.dart';

/// SMB / LAN-share browser: saved servers -> shares -> folders -> videos.
/// Playback streams through the native SMB client (local proxy URL on iOS),
/// one `openShare` URL per playlist item, torn down on return.
class SmbScreen extends StatefulWidget {
  const SmbScreen({super.key});

  @override
  State<SmbScreen> createState() => _SmbScreenState();
}

class _SmbScreenState extends State<SmbScreen> {
  static final SmbClient _smb = SmbClient.instance;

  List<SmbServer> _servers = const [];
  SmbServer? _browsing;
  String _share = '';
  String _path = '';
  List<SmbEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// Saved-server reachability dots (`id` -> online?); probed asynchronously.
  final Map<String, bool> _statuses = {};

  /// LAN discovery results shown above the saved-server list.
  List<SmbDiscovered> _discovered = const [];
  bool _scanning = false;

  /// True while opening stream URLs for the folder playlist.
  bool _opening = false;

  bool get _atBrowseRoot => _browsing == null || (_share.isEmpty && _path.isEmpty);

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  @override
  void dispose() {
    final server = _browsing;
    if (server != null) {
      _smb.closeShare(server.id);
    }
    super.dispose();
  }

  Future<void> _loadServers() async {
    setState(() {
      _loading = true;
      _error = null;
      _statuses.clear();
    });
    try {
      final servers = await _smb.listServers();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _loading = false;
      });
      _probeStatuses(servers);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  /// Fires a quick TCP-445 probe per saved server (in parallel) to paint the
  /// online/offline dots.
  Future<void> _probeStatuses(List<SmbServer> servers) async {
    if (servers.isEmpty) return;
    final results = await Future.wait([
      for (final s in servers) _smb.checkServer(s.host, s.port).then((ok) => (s.id, ok)),
    ]);
    if (!mounted) return;
    setState(() {
      for (final (id, ok) in results) {
        _statuses[id] = ok;
      }
    });
  }

  /// LAN scan for reachable SMB hosts (native subnet 445 probe).
  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _discovered = const [];
    });
    try {
      final found = await _smb.discoverServers();
      if (!mounted) return;
      setState(() {
        _discovered = found;
        _scanning = false;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() => _scanning = false);
    }
  }

  Future<void> _openServer(SmbServer server) async {
    setState(() {
      _browsing = server;
      _share = '';
      _path = '';
      _loading = true;
      _error = null;
    });
    try {
      final shares = await _smb.listShares(server.id);
      if (!mounted) return;
      setState(() {
        _entries = shares;
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

  Future<void> _loadDirectory(String path) async {
    final server = _browsing;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _smb.listDirectory(server.id, _share, path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _entries = entries;
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

  Future<void> _openEntry(SmbEntry entry) async {
    if (entry.isDirectory) {
      if (_share.isEmpty) {
        // Tapping a share in the shares list: this entry IS the share. The
        // share name lives in `_share` (a folder path is relative to it), so
        // set it before listing the share's root.
        setState(() {
          _share = entry.path;
          _path = '';
        });
        await _loadDirectory('');
      } else {
        await _loadDirectory(entry.path);
      }
      return;
    }

    final server = _browsing;
    if (server == null || _opening) return;

    // Playlist = every video in this folder, so playback auto-advances to the
    // next episode when one ends (play-next-episode). Open a stream URL per
    // video up-front; the tapped one must succeed, the rest are best-effort.
    final videos = _entries.where((e) => !e.isDirectory).toList();
    final index = videos.indexWhere((e) => e.path == entry.path);
    if (index < 0) return;

    setState(() => _opening = true);
    final urls = <String?>[];
    try {
      for (var i = 0; i < videos.length; i++) {
        try {
          final videoUrl = await _smb.openShare(server.id, _share, videos[i].path);
          String? subtitleUrl;
          final subPath = videos[i].subtitlePath;
          if (subPath != null && subPath.isNotEmpty) {
            try {
              subtitleUrl = await _smb.openShare(server.id, _share, subPath);
            } on PlatformException {
              subtitleUrl = null;
            }
          }
          urls.add(videoUrl);
          _videoSubtitleUrls[videoUrl] = subtitleUrl;
        } on PlatformException {
          urls.add(null);
        }
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }

    if (!mounted) return;
    final target = urls[index];
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${entry.name}')),
      );
      return;
    }

    final playlist = [
      for (var i = 0; i < videos.length; i++)
        if (urls[i] != null)
          VideoItem(
            id: 'smb_${videos[i].path}_${DateTime.now().microsecondsSinceEpoch}',
            title: videos[i].name,
            uri: urls[i],
            // Loopback proxy URLs rotate per session; key resume on the stable
            // remote location instead.
            resumeKey: 'smb_${server.id}/$_share${videos[i].path}',
            subtitleUri: _videoSubtitleUrls[urls[i]],
            duration: Duration.zero,
            sizeBytes: videos[i].size,
          ),
    ];
    final playIndex = playlist.indexWhere(
      (item) => item.uri == urls[index],
    );
    if (playIndex < 0 || playlist.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          video: playlist[playIndex],
          playlist: playlist,
          playlistIndex: playIndex,
        ),
      ),
    );
    // Playback session over: tear down the SMB streams and disconnect.
    _smb.closeShare(server.id);
  }

  /// Stream URL -> paired subtitle URL for the current folder playlist.
  final Map<String, String?> _videoSubtitleUrls = {};

  Future<void> _goUp() async {
    if (_browsing == null) {
      Navigator.of(context).pop();
      return;
    }
    if (_path.isNotEmpty) {
      final slash = _path.lastIndexOf('/');
      await _loadDirectory(slash < 0 ? '' : _path.substring(0, slash));
    } else if (_share.isNotEmpty) {
      setState(() {
        _share = '';
        _path = '';
        _loading = true;
      });
      try {
        final shares = await _smb.listShares(_browsing!.id);
        if (!mounted) return;
        setState(() {
          _entries = shares;
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
    } else {
      setState(() {
        _browsing = null;
        _share = '';
        _path = '';
        _loading = false;
      });
      await _loadServers();
    }
  }

  void _addServer() => _showServerDialog();

  Future<void> _addShare() async {
    final server = _browsing;
    if (server == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add share'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Share name',
            hintText: 'e.g. Videos',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await _smb.addShare(server.id, name);
    if (!mounted) return;
    await _openServer(server);
  }

  void _editServer(SmbServer server) => _showServerDialog(existing: server);

  void _addDiscoveredServer(SmbDiscovered d) => _showServerDialog(
        initialHost: d.host,
        initialName: d.hostname != d.host ? d.hostname : null,
      );

  Future<void> _deleteServer(SmbServer server) async {
    await _smb.deleteServer(server.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Removed ${server.name}')));
    _loadServers();
  }

  void _showServerDialog({
    SmbServer? existing,
    String? initialHost,
    String? initialName,
  }) {
    showDialog<void>(
      context: context,
      builder: (_) => _ServerFormDialog(
        existing: existing,
        initialHost: initialHost,
        initialName: initialName,
        onSave: () => _loadServers(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final browsing = _browsing;
    return Scaffold(
      appBar: AppBar(
        title: Text(browsing == null
            ? 'Network shares'
            : _breadcrumbTitle(browsing)),
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
                _share = '';
                _path = '';
                _loading = false;
              }),
            )
          else ...[
            IconButton(
              tooltip: 'Scan for servers',
              icon: _scanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find),
              onPressed: _scanning ? null : _discover,
            ),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _loadServers,
            ),
          ],
        ],
      ),
      floatingActionButton: browsing == null
          ? FloatingActionButton.extended(
              onPressed: _addServer,
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            )
          : _share.isEmpty
              ? FloatingActionButton.extended(
                  onPressed: _addShare,
                  icon: const Icon(Icons.add),
                  label: const Text('Add share'),
                )
              : null,
      body: _body(context),
    );
  }

  String _breadcrumbTitle(SmbServer server) {
    if (_share.isEmpty) return server.name;
    if (_path.isEmpty) return '${server.name} / $_share';
    final folder = _path.split('/').last;
    return '${server.name} / $_share / $folder';
  }

  Widget _body(BuildContext context) {
    if (_opening) {
      return const Center(child: CircularProgressIndicator());
    }
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
              Text('Error: $_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _atBrowseRoot ? _loadServers : _goUp,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_browsing == null) return _serverList(context);
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _share.isEmpty
                ? 'No shares found. Tap "Add share" and enter the name '
                    'manually if your NAS uses an unusual share name.'
                : 'Nothing here',
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
        return _SmbTile(
          entry: entry,
          onTap: () => _openEntry(entry),
        );
      },
    );
  }

  Widget _serverList(BuildContext context) {
    if (_servers.isEmpty && _discovered.isEmpty && !_scanning) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.dns_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                'Add your NAS or LAN share to play videos from it, or scan '
                'the network to find one',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _addServer,
                icon: const Icon(Icons.add),
                label: const Text('Add server'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _discover,
                icon: const Icon(Icons.wifi_find),
                label: const Text('Scan network'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadServers,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Scanning your network…'),
                ],
              ),
            ),
          if (!_scanning && _discovered.isNotEmpty) ...[
            const _SectionHeader('Detected on this network'),
            for (final d in _discovered)
              ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: Text(
                  d.hostname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  d.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.add_circle_outline),
                onTap: () => _addDiscoveredServer(d),
              ),
          ],
          if (_servers.isNotEmpty) ...[
            const _SectionHeader('Saved servers'),
            for (final server in _servers) _serverTile(server),
          ],
        ],
      ),
    );
  }

  Widget _serverTile(SmbServer server) {
    final status = _statuses[server.id];
    final dot = Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: status == null
            ? Colors.grey.shade600
            : status
                ? Colors.lightGreenAccent
                : Colors.redAccent,
        border: Border.all(color: Colors.black, width: 1.5),
      ),
    );
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.dns),
          Positioned(right: -3, bottom: -3, child: dot),
        ],
      ),
      title: Text(
        server.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        server.subtitle,
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

class _SmbTile extends StatelessWidget {
  const _SmbTile({required this.entry, required this.onTap});

  final SmbEntry entry;
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
    final icon = entry.isDirectory
        ? Icons.folder
        : Icons.play_circle_outline;
    final color = entry.isDirectory ? colorScheme.primary : colorScheme.secondary;
    final subtitle = entry.isDirectory ? null : _sizeLabel(entry.size);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: entry.isDirectory ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }
}

class _ServerFormDialog extends StatefulWidget {
  const _ServerFormDialog({
    this.existing,
    this.initialHost,
    this.initialName,
    this.onSave,
  });

  final SmbServer? existing;
  final String? initialHost;
  final String? initialName;
  final VoidCallback? onSave;

  @override
  State<_ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends State<_ServerFormDialog> {
  static final SmbClient _smb = SmbClient.instance;

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _domain;
  late bool _guest;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? widget.initialName ?? '');
    _host = TextEditingController(text: s?.host ?? widget.initialHost ?? '');
    _port = TextEditingController(
        text: (s?.port ?? 445).toString());
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: '');
    _domain = TextEditingController(text: s?.domain ?? '');
    _guest = s?.anonymous ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final result = await _smb.testConnection(
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 445,
      username: _username.text.trim(),
      password: _password.text,
      domain: _domain.text.trim(),
      anonymous: _guest,
    );
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.ok
            ? 'Connected'
            : 'Failed: ${result.error ?? 'unknown error'}'),
      ),
    );
  }

  Future<void> _save() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Host is required')));
      return;
    }
    try {
      await _smb.saveServer(
        id: widget.existing?.id,
        name: _name.text.trim(),
        host: host,
        port: int.tryParse(_port.text.trim()) ?? 445,
        username: _username.text.trim(),
        password: _password.text,
        domain: _domain.text.trim(),
        anonymous: _guest,
      );
      widget.onSave?.call();
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message ?? 'Save failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add server' : 'Edit server'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
            ),
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: '192.168.1.10 or nas.local',
              ),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Guest (no username/password)'),
              value: _guest,
              onChanged: (v) => setState(() => _guest = v),
            ),
            if (!_guest) ...[
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: widget.existing?.hasPassword ?? false
                      ? '(unchanged)'
                      : null,
                ),
              ),
              TextField(
                controller: _domain,
                decoration: const InputDecoration(labelText: 'Domain (optional)'),
              ),
            ],
          ],
        ),
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
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
