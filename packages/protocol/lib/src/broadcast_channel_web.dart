// BroadcastChannel transport — web (JS/Wasm) implementation. See
// `broadcast_channel.dart` for the API contract and the envelope protocol.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import 'connection.dart';

/// Envelope keys kept tiny: the bus sees one JSON string per frame.
const _kVersion = 1;

String _nonce() => math.Random().nextInt(1 << 28).toRadixString(16);

/// Listens on a named [web.BroadcastChannel] bus and exposes each
/// connecting client as a [BroadcastChannelTransport] — the listener half
/// a room hub attaches via its transport-acceptance method
/// (`RoomHub.runTransport`).
///
/// This object owns the bus for the server side: accepted transports share
/// it and never read from it directly — the listener is the single reader
/// and dispatches envelopes into the right transport, exactly one delivery
/// per frame.
final class BroadcastChannelListener {
  BroadcastChannelListener(String channel, {this.serverId = 'server'})
    : _channelName = channel;

  final String _channelName;

  /// The id this listener answers to on the bus.
  final String serverId;
  final _connections = <String, BroadcastChannelTransport>{};
  final _incoming = StreamController<BroadcastChannelTransport>.broadcast();
  web.BroadcastChannel? _bus;
  bool _closed = false;

  /// Transports for clients that completed the bus handshake. Emits after
  /// the client's hello envelope; frame delivery starts immediately after.
  Stream<BroadcastChannelTransport> get onConnection => _incoming.stream;

  /// Opens the channel. Clients that connected before this ran are picked
  /// up by their hello retry.
  Future<void> start() async {
    if (_bus != null || _closed) return;
    final bus = web.BroadcastChannel(_channelName);
    _bus = bus;
    // onmessage (not addEventListener): browsers and Node both provide it,
    // and Node's BroadcastChannel is not an EventTarget.
    bus.onmessage = ((web.MessageEvent e) => _onBus(e.data)).toJS;
  }

  void _onBus(JSAny? data) {
    final bus = _bus;
    if (_closed || bus == null || data == null || !data.isA<JSString>()) {
      return;
    }
    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode((data as JSString).toDart)
          as Map<String, dynamic>;
    } catch (_) {
      return; // Not ours (something else shares the channel name).
    }
    if (envelope['v'] != _kVersion || envelope['to'] != serverId) return;
    final from = envelope['from'];
    if (from is! String) return;

    if (envelope['hello'] == true) {
      final existing = _connections[from];
      if (existing != null) {
        existing._sayHelloAgain();
        return;
      }
      final transport = BroadcastChannelTransport._serverSide(
        bus,
        selfId: serverId,
        peerId: from,
      );
      _connections[from] = transport;
      transport._sayHelloAgain();
      _incoming.add(transport);
      return;
    }
    final transport = _connections[from];
    if (transport == null) return;
    if (envelope['bye'] is num) {
      transport._peerWentAway();
    } else if (envelope['d'] is String) {
      transport._frames.add(envelope['d'] as String);
    }
  }

  /// Closes the bus and every accepted connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final transport in _connections.values) {
      await transport._shutdown(notifyPeer: false);
    }
    _connections.clear();
    _bus?.close();
    _bus = null;
    await _incoming.close();
  }
}

/// One connection over a [web.BroadcastChannel] bus. Clients connect via
/// [connect] (owning their channel); the listener constructs the server
/// side per client, sharing its bus.
final class BroadcastChannelTransport implements GameConnection {
  BroadcastChannelTransport._serverSide(
    this._bus, {
    required this.selfId,
    required this.peerId,
  }) : ownsChannel = false;

  BroadcastChannelTransport._clientSide(
    this._bus, {
    required this.selfId,
    required this.peerId,
  }) : ownsChannel = true {
    _bus.onmessage = ((web.MessageEvent e) => _handle(e.data)).toJS;
  }

  final web.BroadcastChannel _bus;
  final bool ownsChannel;
  final String selfId, peerId;
  final _frames = StreamController<String>.broadcast();
  Completer<void>? _helloAck;
  Timer? _hello;
  bool _closed = false;

  /// Connects to a [BroadcastChannelListener] on [channel]. Retries the
  /// hello until the listener answers (the bus drops messages sent before
  /// both sides subscribe) or [timeout] elapses.
  static Future<BroadcastChannelTransport> connect(
    String channel, {
    String? id,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final selfId = id ?? 'c${_nonce()}${_nonce()}';
    final bus = web.BroadcastChannel(channel);
    final transport = BroadcastChannelTransport._clientSide(
      bus,
      selfId: selfId,
      peerId: 'server',
    );
    final ready = Completer<void>();
    transport._helloAck = ready;
    transport._hello = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) {
        if (!transport._closed) transport._post({'hello': true});
      },
    );
    try {
      await ready.future.timeout(timeout);
    } catch (e) {
      await transport._shutdown(notifyPeer: false);
      rethrow;
    }
    transport._hello?.cancel();
    transport._hello = null;
    return transport;
  }

  @override
  Stream<String> get messages => _frames.stream;

  @override
  bool get open => !_closed && !_frames.isClosed;

  @override
  void send(String message) => _post({'d': message});

  @override
  Future<void> close([int? code, String? reason]) =>
      _shutdown(notifyPeer: true, code: code ?? 1000);

  void _post(Map<String, Object> body) {
    if (_closed) return;
    _bus.postMessage(
      jsonEncode({
        'v': _kVersion,
        'from': selfId,
        'to': peerId,
        ...body,
      }).toJS,
    );
  }

  void _sayHelloAgain() => _post({'hi': true});

  /// Client-side bus reader: only this transport's envelopes pass.
  void _handle(JSAny? data) {
    if (_closed || data == null || !data.isA<JSString>()) return;
    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode((data as JSString).toDart)
          as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (envelope['v'] != _kVersion || envelope['to'] != selfId) return;
    if (envelope['hi'] == true) {
      _helloAck?.complete();
      _helloAck = null;
      return;
    }
    if (envelope['bye'] is num) {
      _peerWentAway();
    } else if (envelope['d'] is String) {
      _frames.add(envelope['d'] as String);
    }
  }

  /// The peer went away: surface loss without echoing a goodbye.
  void _peerWentAway() => _shutdown(notifyPeer: false);

  Future<void> _shutdown({required bool notifyPeer, int code = 1000}) async {
    if (_closed) return;
    _closed = true;
    _hello?.cancel();
    if (notifyPeer) _post({'bye': code});
    if (ownsChannel) _bus.close();
    await _frames.close();
  }
}
