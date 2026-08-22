import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'cast_service.dart';

/// A UPnP/DLNA MediaRenderer discovered via SSDP.
class DlnaDevice {
  const DlnaDevice({
    required this.name,
    required this.locationUrl,
    required this.controlUrl,
    required this.host,
  });

  final String name;
  final String locationUrl;
  final String controlUrl;
  final String host;

  String get id => '$host:$controlUrl';
}

/// DLNA/UPnP AVTransport sender — SSDP discovery + SOAP control for
/// renderers like Fire TV (via 3rd-party DLNA apps), Samsung/LG TVs, etc.
/// The TV fetches the URL itself (like Google Cast).
class DlnaService {
  DlnaService._();
  static final DlnaService instance = DlnaService._();

  static final MethodChannel _multicastChannel =
      MethodChannel('dreamplayer/multicast');

  String? _deviceName;
  String? _controlUrl;
  Timer? _pollTimer;
  CastMediaStatus _last = const CastMediaStatus();
  final _statusController = StreamController<CastMediaStatus>.broadcast();
  final _errors = StreamController<String>.broadcast();

  bool get isCasting => _pollTimer != null;
  String? get connectedDeviceName => _deviceName;
  Stream<CastMediaStatus> get statusStream => _statusController.stream;
  Stream<String> get errorStream => _errors.stream;
  CastMediaStatus get lastStatus => _last;

  static Future<bool> _multicastAcquired() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _multicastChannel.invokeMethod<void>('acquire');
        return true;
      } catch (_) {}
    }
    return false;
  }

  static Future<void> _multicastReleased() async {
    try {
      await _multicastChannel.invokeMethod<void>('release');
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Discovery (SSDP)
  // ---------------------------------------------------------------------------

  /// Scans for MediaRenderer devices (~5s). Best-effort; empty on failure.
  Future<List<DlnaDevice>> discover() async {
    final locations = <String>{};
    RawDatagramSocket? socket;
    var lockHeld = false;
    try {
      lockHeld = await _multicastAcquired();
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.readEventsEnabled = true;

      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket!.receive();
          if (dg == null) return;
          final msg = utf8.decode(dg.data, allowMalformed: true);
          final loc = _extractLocation(msg);
          if (loc != null && loc.isNotEmpty) locations.add(loc);
        }
      });

      const stValues = [
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'urn:schemas-upnp-org:service:AVTransport:1',
      ];
      for (final st in stValues) {
        final packet = _buildMSearch(st);
        socket.send(packet, InternetAddress('239.255.255.250'), 1900);
      }
      // Resend once for flaky networks.
      await Future.delayed(const Duration(milliseconds: 300));
      for (final st in stValues) {
        final packet = _buildMSearch(st);
        socket.send(packet, InternetAddress('239.255.255.250'), 1900);
      }

      await Future.delayed(const Duration(seconds: 4));
      await sub.cancel();
      socket.close();
      socket = null;
    } catch (e) {
      debugPrint('dlna: discovery socket failed $e');
      try {
        socket?.close();
      } catch (_) {}
    } finally {
      if (lockHeld) await _multicastReleased();
    }

    debugPrint('dlna: found ${locations.length} location(s)');
    final devices = <DlnaDevice>[];
    final seenControl = <String>{};
    for (final loc in locations) {
      try {
        final d = await _resolveDevice(loc).timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('resolve timeout'),
        );
        if (d != null && seenControl.add(d.controlUrl)) devices.add(d);
      } catch (e) {
        debugPrint('dlna: resolve $loc failed $e');
      }
    }
    devices.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    debugPrint('dlna: resolved ${devices.length} renderer(s)');
    return devices;
  }

  static String? _extractLocation(String msg) {
    for (final line in msg.split('\r\n')) {
      final idx = line.indexOf(':');
      if (idx < 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'location') {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }

  static Uint8List _buildMSearch(String st) {
    final msg = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: $st\r\n\r\n';
    return Uint8List.fromList(utf8.encode(msg));
  }

  Future<DlnaDevice?> _resolveDevice(String locationUrl) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.getUrl(Uri.parse(locationUrl));
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final xml = await res.transform(utf8.decoder).join();
      final name = _extractFriendlyName(xml) ?? Uri.parse(locationUrl).host;
      final control = _extractAvTransportControlUrl(xml, locationUrl);
      if (control == null || control.isEmpty) return null;
      final host = Uri.parse(locationUrl).host;
      return DlnaDevice(
        name: name,
        locationUrl: locationUrl,
        controlUrl: control,
        host: host,
      );
    } finally {
      client.close(force: true);
    }
  }

  static String? _extractFriendlyName(String xml) {
    final m = RegExp(r'<friendlyName>(.*?)</friendlyName>', dotAll: true)
        .firstMatch(xml);
    return m?.group(1)?.trim();
  }

  /// Extracts the AVTransport controlURL, resolving relative URLs against
  /// [baseLocationUrl].
  static String? _extractAvTransportControlUrl(
      String xml, String baseLocationUrl) {
    final serviceRegex = RegExp(r'<service>(.*?)</service>', dotAll: true);
    for (final m in serviceRegex.allMatches(xml)) {
      final block = m.group(1)!;
      if (!block.contains('AVTransport')) continue;
      final ctrl = RegExp(r'<controlURL>(.*?)</controlURL>', dotAll: true)
          .firstMatch(block)
          ?.group(1)
          ?.trim();
      if (ctrl == null || ctrl.isEmpty) continue;
      if (ctrl.startsWith('http://') || ctrl.startsWith('https://')) {
        return ctrl;
      }
      // Relative — resolve against location URL.
      try {
        return Uri.parse(baseLocationUrl).resolve(ctrl).toString();
      } catch (_) {
        return ctrl;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // SOAP helpers
  // ---------------------------------------------------------------------------

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _buildDidl(String title, String url) {
    final t = _escapeXml(title);
    final u = _escapeXml(url);
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>$t</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:video/mp4:*">$u</res>'
        '</item></DIDL-Lite>';
  }

  static String _formatTime(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  /// Parses UPnP time strings like "1:02:03", "00:04:12", "NOT_IMPLEMENTED".
  static Duration parseUpnpTime(String s) {
    final t = s.trim();
    if (t.isEmpty ||
        t.toUpperCase() == 'NOT_IMPLEMENTED' ||
        t == '00:00:00') {
      return Duration.zero;
    }
    final parts = t.split(':');
    if (parts.length != 3) return Duration.zero;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final secStr = parts[2].split('.').first;
    final sec = int.tryParse(secStr) ?? 0;
    return Duration(hours: h, minutes: m, seconds: sec);
  }

  Future<String> _soap(
    String controlUrl,
    String action,
    Map<String, String> args,
  ) async {
    final body = StringBuffer()
      ..writeln('<?xml version="1.0"?>')
      ..writeln(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..writeln('<s:Body>')
      ..writeln('<u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">');
    for (final e in args.entries) {
      body.writeln('<${e.key}>${_escapeXml(e.value)}</${e.key}>');
    }
    body
      ..writeln('</u:$action>')
      ..writeln('</s:Body>')
      ..writeln('</s:Envelope>');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(Uri.parse(controlUrl));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION',
          '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
      req.write(body.toString());
      final res = await req.close().timeout(const Duration(seconds: 6));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('DLNA $action failed (${res.statusCode})');
      }
      if (text.contains('<s:Fault>') || text.contains('<UPnPError>')) {
        final code = RegExp(r'<errorCode>(.*?)</errorCode>')
                .firstMatch(text)
                ?.group(1) ??
            '';
        throw Exception('DLNA $action error $code');
      }
      return text;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle (mirrors CastService)
  // ---------------------------------------------------------------------------

  Future<void> connectAndLoad({
    required DlnaDevice device,
    required String url,
    required String title,
    Duration startAt = Duration.zero,
  }) async {
    await disconnect(stopMedia: false);
    _last = const CastMediaStatus();
    _deviceName = device.name;
    _controlUrl = device.controlUrl;

    final didl = _buildDidl(title, url);
    try {
      await _soap(device.controlUrl, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url,
        'CurrentURIMetaData': didl,
      });
      await _soap(device.controlUrl, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });
      if (startAt > Duration.zero) {
        await Future.delayed(const Duration(milliseconds: 400));
        await _soap(device.controlUrl, 'Seek', {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': _formatTime(startAt),
        });
      }
    } catch (e) {
      await disconnect(stopMedia: false);
      throw Exception(_friendlyError(e));
    }

    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      await _poll();
    });
    await _poll();
  }

  Future<void> _poll() async {
    final ctrl = _controlUrl;
    if (ctrl == null) return;
    try {
      final posXml = await _soap(ctrl, 'GetPositionInfo', {'InstanceID': '0'});
      final transXml =
          await _soap(ctrl, 'GetTransportInfo', {'InstanceID': '0'});

      final relTime = RegExp(r'<RelTime>(.*?)</RelTime>')
              .firstMatch(posXml)
              ?.group(1) ??
          '';
      final trackDur = RegExp(r'<TrackDuration>(.*?)</TrackDuration>')
              .firstMatch(posXml)
              ?.group(1) ??
          '';
      final state = RegExp(r'<CurrentTransportState>(.*?)</CurrentTransportState>')
              .firstMatch(transXml)
              ?.group(1) ??
          'STOPPED';

      final pos = parseUpnpTime(relTime);
      final dur = parseUpnpTime(trackDur);
      final playing = state == 'PLAYING';
      final buffering = state == 'TRANSITIONING';
      final ended = state == 'STOPPED' &&
          dur > Duration.zero &&
          pos >= dur - const Duration(seconds: 1);

      _last = CastMediaStatus(
        playing: playing,
        buffering: buffering,
        ended: ended,
        position: pos,
        duration: dur,
      );
      if (!_statusController.isClosed) _statusController.add(_last);
    } catch (e) {
      debugPrint('dlna: poll failed $e');
    }
  }

  Future<void> play() async {
    final c = _controlUrl;
    if (c == null) return;
    try {
      await _soap(c, 'Play', {'InstanceID': '0', 'Speed': '1'});
    } catch (e) {
      debugPrint('dlna: play failed $e');
    }
  }

  Future<void> pause() async {
    final c = _controlUrl;
    if (c == null) return;
    try {
      await _soap(c, 'Pause', {'InstanceID': '0'});
    } catch (e) {
      debugPrint('dlna: pause failed $e');
    }
  }

  Future<void> seekTo(Duration position) async {
    final c = _controlUrl;
    if (c == null) return;
    try {
      await _soap(c, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': _formatTime(position),
      });
    } catch (e) {
      debugPrint('dlna: seek failed $e');
    }
  }

  Future<void> togglePlayPause() async =>
      _last.playing ? pause() : play();

  Future<void> stopMedia() async {
    final c = _controlUrl;
    if (c == null) return;
    try {
      await _soap(c, 'Stop', {'InstanceID': '0'});
    } catch (_) {}
  }

  Future<void> disconnect({bool stopMedia = true}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final c = _controlUrl;
    _controlUrl = null;
    _deviceName = null;
    if (stopMedia && c != null) {
      try {
        await _soap(c, 'Stop', {'InstanceID': '0'})
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  static String _friendlyError(Object e) {
    final t = e.toString().replaceFirst('Exception: ', '');
    if (t.contains('DLNA')) return t;
    return 'DLNA failed — $t';
  }

  static String friendlyError(Object e) => _friendlyError(e);
}
