import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import '../services/file_browser.dart';
import 'player_screen.dart';

/// In-app file browser (CX-Explorer style): browse the device's storage and
/// play any video without importing it into the library.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen>
    with WidgetsBindingObserver {
  static final FileBrowserService _service = FileBrowserService.instance;

  List<FileEntry> _roots = const [];
  String? _currentPath;
  List<FileEntry> _entries = const [];
  bool _loading = true;
  bool _hasAccess = true;
  String? _error;

  bool get _atRoot => _currentPath == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_hasAccess) {
      _init();
    }
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hasAccess = await _service.hasAllFilesAccess();
      if (!hasAccess) {
        if (mounted) {
          setState(() {
            _hasAccess = false;
            _loading = false;
          });
        }
        return;
      }
      _hasAccess = true;
      if (_currentPath == null) {
        await _loadRoots();
      } else {
        await _load(_currentPath!);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message ?? 'Something went wrong';
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadRoots() async {
    final roots = await _service.storageRoots();
    if (!mounted) return;
    setState(() {
      _roots = roots;
      _entries = roots;
      _loading = false;
    });
  }

  Future<void> _load(String path) async {
    final entries = await _service.listDirectory(path);
    if (!mounted) return;
    setState(() {
      _currentPath = path;
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _openEntry(FileEntry entry) async {
    if (entry.isDirectory) {
      setState(() => _loading = true);
      await _load(entry.path);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(video: VideoItem(
            id: 'file_${DateTime.now().microsecondsSinceEpoch}',
            title: entry.name,
            path: entry.path,
            duration: Duration.zero,
            sizeBytes: entry.size,
          )),
        ),
      );
    }
  }

  Future<void> _goUp() async {
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    final rootPaths = _roots.map((r) => r.path).toSet();
    final parent = _parentOf(_currentPath);
    if (rootPaths.contains(_currentPath) ||
        parent == null ||
        rootPaths.contains(parent)) {
      setState(() {
        _currentPath = null;
        _entries = _roots;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    await _load(parent);
  }

  static String? _parentOf(String? path) {
    if (path == null) return null;
    final index = path.lastIndexOf('/');
    if (index <= 0) return null;
    return path.substring(0, index);
  }

  void _grantAccess() {
    _service.openAllFilesAccessSettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_atRoot
            ? 'Browse files'
            : (_currentPath?.split('/').lastOrNull ?? 'Files')),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Text('Error: $_error',
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    if (!_hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                'All files access is needed to browse your storage',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _grantAccess,
                child: const Text('Grant access'),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('No videos or folders here'));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _FileTile(
          entry: entry,
          onTap: () => _openEntry(entry),
        );
      },
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.onTap,
  });

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
      trailing: entry.isDirectory
          ? const Icon(Icons.chevron_right)
          : null,
      onTap: onTap,
    );
  }
}
