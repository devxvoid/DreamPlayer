import 'package:flutter/services.dart';

const MethodChannel _upnpChannel = MethodChannel('dreamplayer/upnp');

class UpnpServer {
  const UpnpServer({
    required this.id,
    required this.name,
    required this.location,
    required this.controlUrl,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String location;
  final String controlUrl;
  final String baseUrl;

  factory UpnpServer.fromMap(Map<dynamic, dynamic> m) => UpnpServer(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? 'DLNA Server',
        location: m['location'] as String? ?? '',
        controlUrl: m['controlUrl'] as String? ?? '',
        baseUrl: m['baseUrl'] as String? ?? '',
      );
}

class UpnpEntry {
  const UpnpEntry({
    required this.name,
    required this.id,
    required this.isDirectory,
    this.url,
    this.size = 0,
    this.duration,
  });

  final String name;
  final String id;
  final bool isDirectory;
  final String? url;
  final int size;
  final String? duration;

  factory UpnpEntry.fromMap(Map<dynamic, dynamic> m) => UpnpEntry(
        name: m['name'] as String? ?? '',
        id: m['id'] as String? ?? '',
        isDirectory: m['isDirectory'] == true,
        url: m['url'] as String?,
        size: m['size'] is num ? (m['size'] as num).toInt() : 0,
        duration: m['duration'] as String?,
      );

  bool get isVideo => !isDirectory && url != null && url!.isNotEmpty;
}

class UpnpClient {
  UpnpClient._();
  static final UpnpClient instance = UpnpClient._();

  Future<List<UpnpServer>> discover() async {
    try {
      final raw = await _upnpChannel.invokeMethod<List<dynamic>>('discover');
      if (raw == null) return const [];
      return raw.map((e) => UpnpServer.fromMap(e as Map<dynamic, dynamic>)).toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      rethrow;
    }
  }

  Future<List<UpnpEntry>> browse(String serverId, String objectId) async {
    final raw = await _upnpChannel.invokeMethod<List<dynamic>>('browse', {
      'serverId': serverId,
      'objectId': objectId,
    });
    if (raw == null) return const [];
    return raw.map((e) => UpnpEntry.fromMap(e as Map<dynamic, dynamic>)).toList();
  }
}
