import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:multicast_dns/multicast_dns.dart';

import '../models/video_item.dart';

/// A Cast receiver discovered on the LAN.
class CastDevice {
  const CastDevice({
    required this.name,
    required this.host,
    required this.port,
  });

  /// Friendly name (mDNS instance label).
  final String name;
  final String host;
  final int port;

  String get id => '$host:$port';
}

/// Live state of the media playing on the cast receiver.
class CastMediaStatus {
  const CastMediaStatus({
    this.playing = false,
    this.buffering = false,
    this.ended = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  final bool playing;
  final bool buffering;
  final bool ended;
  final Duration position;
  final Duration duration;
}

/// One framed CASTV2 message from the receiver.
class _CastFrame {
  _CastFrame({
    required this.namespace,
    required this.sourceId,
    required this.destinationId,
    required this.payloadJson,
  });

  final String namespace;
  final String sourceId;
  final String destinationId;
  final String payloadJson;

  Map<String, dynamic> get payload {
    try {
      return jsonDecode(payloadJson) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }
}

/// TLS connection to a receiver speaking the CASTV2 protocol: protobuf
/// messages length-prefixed with 4 big-endian bytes.
class _CastConnection {
  _CastConnection._(this._socket) {
    _socket.listen(_onData, onError: (Object e) {
      _messages.addError(e);
    }, onDone: () {
      if (!_messages.isClosed) _messages.close();
    });
  }

  static Future<_CastConnection> connect(
    String host,
    int port,
  ) async {
    final socket = await SecureSocket.connect(host, port,
        timeout: const Duration(seconds: 6),
        onBadCertificate: (_) => true);
    return _CastConnection._(socket);
  }

  final SecureSocket _socket;
  Uint8List _pending = Uint8List(0);

  final _messages = StreamController<_CastFrame>.broadcast();
  Stream<_CastFrame> get frames => _messages.stream;

  void _onData(Uint8List chunk) {
    // Accumulate and drain complete frames.
    final merged = Uint8List(_pending.length + chunk.length);
    merged.setAll(0, _pending);
    merged.setAll(_pending.length, chunk);
    var offset = 0;
    while (merged.length - offset >= 4) {
      final bd = ByteData.sublistView(merged, offset, offset + 4);
      final frameLen = bd.getUint32(0);
      if (merged.length - offset - 4 < frameLen) break;
      final frameBytes =
          Uint8List.sublistView(merged, offset + 4, offset + 4 + frameLen);
      final frame = _decode(frameBytes);
      if (frame != null && !_messages.isClosed) _messages.add(frame);
      offset += 4 + frameLen;
    }
    _pending = Uint8List.sublistView(merged, offset);
  }

  void send({
    required String namespace,
    required String destinationId,
    required Map<String, dynamic> payload,
    String sourceId = 'sender-0',
  }) {
    try {
      final body = _encode(namespace, sourceId, destinationId,
          jsonEncode(payload));
      final header = ByteData(4)..setUint32(0, body.length);
      _socket.add(header.buffer.asUint8List());
      _socket.add(body);
    } catch (e) {
      debugPrint('cast: send failed ($namespace): $e');
    }
  }

  Future<void> close() async {
    if (!_messages.isClosed) await _messages.close();
    try {
      await _socket.close();
    } catch (_) {}
    try {
      _socket.destroy();
    } catch (_) {}
  }

  // -- CASTV2 protobuf (CastChannel) ---------------------------------------

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  static void _writeString(BytesBuilder b, int field, String s) {
    final bytes = utf8.encode(s);
    b.add([(field << 3) | 2, ..._varint(bytes.length)]);
    b.add(bytes);
  }

  static Uint8List _encode(
      String namespace, String sourceId, String destinationId, String payload) {
    final b = BytesBuilder();
    b.add([0x08, 0x00]); // protocol_version = CASTV2_1_0
    _writeString(b, 2, sourceId);
    _writeString(b, 3, destinationId);
    _writeString(b, 4, namespace);
    b.add([0x28, 0x00]); // payload_type = STRING
    _writeString(b, 6, payload);
    return b.toBytes();
  }

  /// Decodes one CastChannel message; returns null for malformed input.
  static _CastFrame? _decode(Uint8List data) {
    String? ns, src, dst, payload;
    var i = 0;
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (i < data.length) {
        final byte = data[i++];
        result |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) break;
        shift += 7;
      }
      return result;
    }

    while (i < data.length) {
      final tag = data[i++];
      final field = tag >> 3;
      final wire = tag & 7;
      switch (wire) {
        case 0:
          readVarint();
          break;
        case 1:
          i += 8;
          break;
        case 2:
          final len = readVarint();
          if (i + len > data.length) return null;
          final value = utf8.decode(data.sublist(i, i + len), allowMalformed: true);
          switch (field) {
            case 2:
              src = value;
              break;
            case 3:
              dst = value;
              break;
            case 4:
              ns = value;
              break;
            case 6:
              payload = value;
              break;
          }
          i += len;
          break;
        case 5:
          i += 4;
          break;
        default:
          return null;
      }
    }
    if (ns == null || payload == null) return null;
    return _CastFrame(
      namespace: ns,
      sourceId: src ?? '',
      destinationId: dst ?? '',
      payloadJson: payload,
    );
  }
}

/// Google Cast sender for DreamPlayer: discovers Chromecast / Android TV /
/// Cast-enabled receivers on the LAN and hands them a playable HTTP(S) URL
/// (the receiver fetches and decodes the file itself).
///
/// Phase-1 scope: sources whose URL is directly reachable by the TV —
/// Jellyfin direct-play URLs (token in query) and plain http(s) streams.
/// Sources needing per-request headers (WebDAV Basic auth) or loopback
/// proxies are not castable yet.
class CastService {
  CastService._();
  static final CastService instance = CastService._();

  /// Google's Default Media Receiver — plays mp4/mkv/hls URLs with stock
  /// transport controls.
  static const String _receiverAppId = 'CC1AD845';
  static const String _nsConnection =
      'urn:x-cast:com.google.cast.tp.connection';
  static const String _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const String _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const String _nsMedia = 'urn:x-cast:com.google.cast.media';

  _CastConnection? _conn;
  Timer? _pollTimer;
  int _requestId = 0;

  String? _deviceName;
  String? _transportId;
  String? _appSessionId;
  bool get isCasting => _conn != null;
  String? get connectedDeviceName => _deviceName;

  final _statusController = StreamController<CastMediaStatus>.broadcast();
  Stream<CastMediaStatus> get statusStream => _statusController.stream;

  final _errors = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errors.stream;

  CastMediaStatus _last = const CastMediaStatus();
  CastMediaStatus get lastStatus => _last;

  StreamSubscription<_CastFrame>? _frameSub;

  // -------------------------------------------------------------------------
  // Source eligibility + URL typing (pure, unit-tested)
  // -------------------------------------------------------------------------

  /// True when [item] points at a URL the receiver can fetch itself: an
  /// http(s) stream that needs no request headers, isn't a loopback proxy,
  /// and isn't self-signed-only.
  static bool isSourceCastable(VideoItem item) {
    if (item.httpHeaders.isNotEmpty) return false;
    if (item.allowSelfSigned) {
      // The receiver cannot skip TLS verification; only allow it when the
      // server has a real certificate anyway (we can't know), so v1 keeps
      // self-signed servers uncastable.
      return false;
    }
    final uri = item.uri ?? item.path ?? '';
    if (uri.isEmpty) return false;
    final u = Uri.tryParse(uri);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return false;
    if (u.host == '127.0.0.1' || u.host == 'localhost') return false;
    return true;
  }

  /// MIME type for the receiver based on the URL/file name.
  static String guessContentType(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    bool endsWith(List<String> exts) {
      for (final e in exts) {
        if (path.endsWith('.$e')) return true;
      }
      return false;
    }

    if (endsWith(['m3u8'])) return 'application/x-mpegurl';
    if (endsWith(['mpd'])) return 'application/dash+xml';
    if (endsWith(['mkv', 'webm'])) return 'video/x-matroska';
    if (endsWith(['ts', 'm2ts', 'mts'])) return 'video/mp2t';
    if (endsWith(['mov'])) return 'video/quicktime';
    if (endsWith(['avi'])) return 'video/x-msvideo';
    return 'video/mp4';
  }

  /// Maps a cast failure to a user-readable message.
  static String friendlyError(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '');
    debugPrint('cast: $e');
    return text;
  }

  // -------------------------------------------------------------------------
  // Discovery (mDNS _googlecast._tcp — Android needs the MulticastLock held,
  // same as Jellyfin discovery).
  // -------------------------------------------------------------------------

  static final MethodChannel _multicastChannel =
      MethodChannel('dreamplayer/multicast');

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

  /// Scans the LAN for Cast devices (~5 s). Empty on failure — discovery is
  /// best-effort; manual retry is the fallback.
  Future<List<CastDevice>> discover() async {
    final found = <String, CastDevice>{};
    final resolver = MDnsClient();
    var lockHeld = false;
    try {
      lockHeld = await _multicastAcquired();
      await resolver.start().timeout(const Duration(seconds: 3));
      await for (final ptr in resolver.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_googlecast._tcp'),
        timeout: const Duration(seconds: 4),
      )) {
        final instance = ptr.domainName;
        if (found.containsKey(instance)) continue;
        await for (final srv in resolver.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(instance),
          timeout: const Duration(seconds: 2),
        )) {
          final target = srv.target.replaceAll(RegExp(r'\.$'), '');
          var host = target;
          if (InternetAddress.tryParse(target) == null) {
            try {
              await for (final ip
                  in resolver.lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
                timeout: const Duration(seconds: 2),
              )) {
                host = ip.address.address;
                break;
              }
            } catch (_) {}
          }
          if (host.isEmpty) continue;
          // Instance label before the service suffix is the friendly name.
          final name = instance.split('.').first.replaceAll('_', ' ').trim();
          found[instance] = CastDevice(
            name: name.isEmpty ? host : name,
            host: host,
            port: srv.port,
          );
          break;
        }
      }
    } catch (e) {
      debugPrint('cast: discovery failed $e');
    } finally {
      if (lockHeld) await _multicastReleased();
      try {
        resolver.stop();
      } catch (_) {}
    }
    final list = found.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    debugPrint('cast: discovery found ${list.length} device(s)');
    return list;
  }

  // -------------------------------------------------------------------------
  // Session lifecycle
  // -------------------------------------------------------------------------

  /// Connects to [device], launches the Default Media Receiver and loads
  /// [url]. Throws a user-readable message on any failure.
  Future<void> connectAndLoad({
    required CastDevice device,
    required String url,
    required String title,
    Duration startAt = Duration.zero,
  }) async {
    await disconnect(stopMedia: false);
    _last = const CastMediaStatus();
    _transportId = null;
    _appSessionId = null;

    final _CastConnection conn;
    try {
      conn = await _CastConnection.connect(device.host, device.port);
    } catch (_) {
      throw Exception('Could not reach ${device.name}');
    }

    final ready = Completer<void>();
    _frameSub = conn.frames.listen((frame) {
      final payload = frame.payload;
      switch (payload['type']) {
        case 'PING':
          conn.send(
              namespace: _nsHeartbeat,
              destinationId: frame.sourceId,
              payload: {'type': 'PONG'});
          return;
        case 'CLOSE':
          if (!ready.isCompleted) ready.completeError('closed by receiver');
          return;
        case 'RECEIVER_STATUS':
          final apps = payload['status']?['applications'];
          if (apps is List && apps.isNotEmpty) {
            final app = apps.first as Map?;
            _transportId = app?['transportId'] as String? ?? _transportId;
            if (app?['appId'] == _receiverAppId && !ready.isCompleted) {
              _appSessionId = app?['sessionId'] as String?;
              ready.complete();
            }
          }
          break;
        default:
          break;
      }
      if (ready.isCompleted) _handleMessage(payload);
    }, onError: (Object e) {
      if (!ready.isCompleted) ready.completeError(e);
    });

    // Virtual connection to the receiver's virtual connection manager.
    conn.send(
        namespace: _nsConnection,
        destinationId: 'receiver-0',
        payload: {'type': 'CONNECT'});
    // Ask the receiver to launch DMR (idempotent if already running there).
    conn.send(
        namespace: _nsReceiver,
        destinationId: 'receiver-0',
        payload: {'type': 'LAUNCH', 'appId': _receiverAppId});

    try {
      await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      await _teardown(conn);
      throw Exception('${device.name} did not accept the cast');
    }

    _conn = conn;
    _deviceName = device.name;

    conn.send(
        namespace: _nsMedia,
        destinationId: _transportId ?? 'receiver-0',
        payload: {
          'type': 'LOAD',
          'requestId': _nextId(),
          'autoplay': true,
          'currentTime': startAt.inMilliseconds / 1000.0,
          'media': {
            'contentId': url,
            'streamType': 'BUFFERED',
            'contentType': guessContentType(url),
            'metadata': {'metadataType': 0, 'title': title},
          },
        });

    // Track position while casting.
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _mediaSend({'type': 'GET_STATUS'});
    });
  }

  void _handleMessage(Map<String, dynamic> payload) {
    if (payload['type'] == 'MEDIA_STATUS') {
      final list = payload['status'];
      if (list is List && list.isNotEmpty) {
        final s = list.last;
        if (s is Map) {
          _last = _parseMediaStatus(s);
          if (!_statusController.isClosed) _statusController.add(_last);
        }
      }
    } else if (payload['type'] == 'LOAD_FAILED') {
      if (!_errors.isClosed) {
        _errors.add('The TV could not play this file (unsupported format?)');
      }
    }
  }

  CastMediaStatus _parseMediaStatus(Map<dynamic, dynamic> s) {
    final playerState = s['playerState'] as String? ?? 'IDLE';
    final idleReason = s['idleReason'] as String?;
    final media = s['media'] as Map?;
    return CastMediaStatus(
      playing: playerState == 'PLAYING',
      buffering: playerState == 'BUFFERING',
      ended: playerState == 'IDLE' && idleReason == 'FINISHED',
      position: Duration(
          milliseconds: (((s['currentTime'] as num?) ?? 0) * 1000).round()),
      duration: Duration(
          milliseconds: (((media?['duration'] as num?) ?? 0) * 1000).round()),
    );
  }

  // -------------------------------------------------------------------------
  // Transport controls
  // -------------------------------------------------------------------------

  Future<void> play() async => _mediaSend({'type': 'PLAY'});
  Future<void> pause() async => _mediaSend({'type': 'PAUSE'});

  Future<void> seekTo(Duration position) async => _mediaSend(
      {'type': 'SEEK', 'currentTime': position.inMilliseconds / 1000.0});

  Future<void> togglePlayPause() async => _last.playing ? pause() : play();

  /// Stops media playback on the receiver without closing the connection.
  Future<void> stopMedia() async => _mediaSend({'type': 'STOP'});

  /// Disconnects. When [stopMedia] the running app session on the receiver is
  /// stopped too (so the TV returns to its backdrop); pass false when the
  /// user wants playback to continue on the TV after leaving.
  Future<void> disconnect({bool stopMedia = true}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final conn = _conn;
    final sub = _frameSub;
    _conn = null;
    _frameSub = null;
    _deviceName = null;
    if (stopMedia && _appSessionId != null && conn != null) {
      try {
        conn.send(
            namespace: _nsReceiver,
            destinationId: 'receiver-0',
            payload: {'type': 'STOP', 'sessionId': _appSessionId});
        await Future.delayed(const Duration(milliseconds: 150));
      } catch (_) {}
    }
    _appSessionId = null;
    _transportId = null;
    await sub?.cancel();
    if (conn != null) await conn.close();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  int _nextId() => ++_requestId;

  Future<void> _mediaSend(Map<String, dynamic> body) async {
    final conn = _conn;
    if (conn == null) return;
    body['requestId'] = _nextId();
    conn.send(
        namespace: _nsMedia,
        destinationId: _transportId ?? 'receiver-0',
        payload: body);
  }

  Future<void> _teardown(_CastConnection conn) async {
    try {
      await conn.close();
    } catch (_) {}
  }
}
