import 'dart:async';
import 'dart:io';
import 'package:protocol/protocol.dart';
import 'server_socket_connection.dart';

export 'server_socket_connection.dart';

/// Dedicated-process room host: binds an HTTP listener, upgrades `/play/<key>`
/// WebSocket requests, and delegates the entire peer protocol to a
/// [RoomHub]. Player-hosted apps skip this class and drive a RoomHub
/// directly with in-process or WebRTC transports.
class RoomServer {
  RoomServer(
    this.authority, {
    required this.protocolVersion,
    int simulationHz = 120,
    int snapshotHz = 20,
    String? roomKey,
    this.resumeGrace = const Duration(seconds: 15),
    this.wireCodec,
  }) : hub = RoomHub(
          authority,
          protocolVersion: protocolVersion,
          simulationHz: simulationHz,
          snapshotHz: snapshotHz,
          roomKey: roomKey,
          resumeGrace: resumeGrace,
          wireCodec: wireCodec,
        );
  final RoomAuthority authority;
  final int protocolVersion;
  final Duration resumeGrace;
  final WireStateCodec? wireCodec;
  final RoomHub hub;

  final Set<WebSocket> _pending = {};
  HttpServer? _http;
  bool _closed = false;
  int get port => _http!.port;
  Uri get localUri => Uri.parse('ws://127.0.0.1:$port/play/${hub.roomKey}');

  Future<void> start({int port = 8790, InternetAddress? address}) async {
    _http = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _http!.listen(_request);
    hub.start();
  }

  Future<void> _request(HttpRequest request) async {
    if (request.uri.path != '/play/${hub.roomKey}' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    if (_pending.length >= authority.capacity * 2 || _closed) {
      request.response.statusCode = 503;
      await request.response.close();
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } on WebSocketException {
      return;
    }
    _pending.add(socket);
    final connection = ServerWebSocketConnection(socket);
    connection.start();
    final done = hub.runTransport(connection).whenComplete(
      () => _pending.remove(socket),
    );
    // The hub closes the socket on protocol errors and resume-replacement.
    unawaited(done);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await hub.close(); // closes peer transports with 1001
    await _http?.close(force: true);
  }
}
