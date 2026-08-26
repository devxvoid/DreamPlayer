import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/opensubtitles_client.dart';

/// Bottom sheet for OpenSubtitles search & download (anonymous 5/day, login 20/day).
class OpensubtitlesSheet extends StatefulWidget {
  const OpensubtitlesSheet({super.key, required this.initialQuery, this.filePath});

  /// Prefilled search term (video title / parsed name).
  final String initialQuery;
  /// Local file path for hash-based search (optional).
  final String? filePath;

  @override
  State<OpensubtitlesSheet> createState() => _OpensubtitlesSheetState();
}

class _OpensubtitlesSheetState extends State<OpensubtitlesSheet> {
  late final TextEditingController _queryCtrl;
  final _langCtrl = TextEditingController(text: 'en');
  bool _searching = false;
  bool _downloading = false;
  String? _error;
  List<OpensubtitlesResult> _results = const [];
  String? _hash;
  bool _hashSearching = false;

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController(text: widget.initialQuery);
    _maybeHash();
  }

  Future<void> _maybeHash() async {
    final p = widget.filePath;
    if (p == null || p.isEmpty) return;
    setState(() => _hashSearching = true);
    final h = await opensubtitlesHashForFile(p);
    if (mounted) setState(() { _hash = h; _hashSearching = false; });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _langCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _queryCtrl.text.trim();
    final langs = _langCtrl.text.trim().isEmpty ? 'en' : _langCtrl.text.trim();
    if (q.isEmpty && _hash == null) {
      setState(() => _error = 'Enter a search term');
      return;
    }
    if (!OpensubtitlesClient.instance.hasApiKey) {
      setState(() => _error = 'Missing OPENSUBTITLES_API_KEY — add it to .env and rebuild');
      return;
    }
    setState(() { _searching = true; _error = null; _results = const []; });
    try {
      final res = await OpensubtitlesClient.instance.search(
        query: q,
        languages: langs,
        movieHash: _hash,
      );
      if (!mounted) return;
      setState(() { _results = res; _searching = false; if (res.isEmpty) _error = 'No results'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _searching = false; _error = e.toString(); });
    }
  }

  Future<void> _download(OpensubtitlesResult r) async {
    setState(() { _downloading = true; _error = null; });
    try {
      final info = await OpensubtitlesClient.instance.requestDownload(r.fileId);
      final bytes = await OpensubtitlesClient.instance.fetchBytes(info.link);
      final dir = await getTemporaryDirectory();
      final subDir = Directory('${dir.path}/opensubs');
      if (!await subDir.exists()) await subDir.create(recursive: true);
      // Sanitize fileName
      final safeName = info.fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
      final file = File('${subDir.path}/$safeName');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      final msg = e.toString();
      final isQuota = msg.toLowerCase().contains('limit') || msg.toLowerCase().contains('quota') || msg.contains('401');
      if (!mounted) return;
      setState(() { _downloading = false; _error = msg; });
      if (isQuota) {
        // Offer login
        final loggedIn = await _showLoginDialog();
        if (loggedIn == true && mounted) {
          // Retry once with new token
          try {
            setState(() => _downloading = true);
            final info = await OpensubtitlesClient.instance.requestDownload(r.fileId);
            final bytes = await OpensubtitlesClient.instance.fetchBytes(info.link);
            final dir = await getTemporaryDirectory();
            final subDir = Directory('${dir.path}/opensubs');
            if (!await subDir.exists()) await subDir.create(recursive: true);
            final safeName = info.fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
            final file = File('${subDir.path}/$safeName');
            await file.writeAsBytes(bytes, flush: true);
            if (!mounted) return;
            Navigator.of(context).pop(file.path);
          } catch (e2) {
            if (mounted) setState(() { _downloading = false; _error = e2.toString(); });
          }
        }
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<bool?> _showLoginDialog() async {
    final uCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    String? err;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text('Sign in to OpenSubtitles', style: TextStyle(color: Colors.white)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: uCtrl, decoration: const InputDecoration(labelText: 'Username', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 8),
          TextField(controller: pCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Password', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
          const SizedBox(height: 8),
          const Text('Anonymous = 5/day, free account = 20/day', style: TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () async {
            try {
              await OpensubtitlesClient.instance.login(username: uCtrl.text.trim(), password: pCtrl.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              setDlg(() => err = e.toString());
            }
          }, child: const Text('Sign in')),
        ],
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.fromLTRB(20, 16, 20, 8), child: Text('Search OpenSubtitles', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
              Expanded(child: TextField(controller: _queryCtrl, decoration: const InputDecoration(hintText: 'Movie / episode name', hintStyle: TextStyle(color: Colors.white38)), style: const TextStyle(color: Colors.white), onSubmitted: (_) => _search())),
              const SizedBox(width: 8),
              SizedBox(width: 80, child: TextField(controller: _langCtrl, decoration: const InputDecoration(hintText: 'en', hintStyle: TextStyle(color: Colors.white38)), style: const TextStyle(color: Colors.white))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _searching ? null : _search, child: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Search')),
            ])),
            if (_hash != null) Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 0), child: Text('Hash match enabled', style: TextStyle(color: Colors.green.shade300, fontSize: 11))),
            if (_hashSearching) const Padding(padding: EdgeInsets.fromLTRB(20, 4, 20, 0), child: Text('Computing file hash…', style: TextStyle(color: Colors.white38, fontSize: 11))),
            if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
            const Divider(color: Colors.white12, height: 16),
            if (_downloading) const Padding(padding: EdgeInsets.all(16), child: Row(children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 8), Text('Downloading…', style: TextStyle(color: Colors.white70))])),
            Flexible(child: ListView.builder(shrinkWrap: true, itemCount: _results.length, itemBuilder: (ctx, i) {
              final r = _results[i];
              final lang = r.language.isEmpty ? '?' : r.language.toUpperCase();
              return ListTile(
                leading: CircleAvatar(backgroundColor: Colors.white12, child: Text(lang, style: const TextStyle(color: Colors.white, fontSize: 11))),
                title: Text(r.fileName.isEmpty ? (r.release ?? 'Subtitle ${r.fileId}') : r.fileName, style: const TextStyle(color: Colors.white, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${r.downloads} downloads · ★ ${r.ratings.toStringAsFixed(1)}${r.release != null ? ' · ${r.release}' : ''}', style: const TextStyle(color: Colors.white54, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: _downloading ? null : () => _download(r),
              );
            })),
          ]),
        ),
      ),
    );
  }
}
