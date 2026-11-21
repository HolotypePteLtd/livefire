// The Dart VM has no BroadcastChannel; importing this library on a native
// target means the caller asked for a browser transport outside a browser.
import 'dart:async';

import 'connection.dart';

Never _unsupported(String what) => throw UnsupportedError(
      'BroadcastChannel transports are only available in JavaScript '
      'contexts (browsers and workers); $what',
    );

/// VM stub — see `broadcast_channel.dart` for the real API.
final class BroadcastChannelListener {
  BroadcastChannelListener(String channel, {String serverId = 'server'});
  Stream<BroadcastChannelTransport> get onConnection =>
      _unsupported('listen');
  Future<void> start() async => _unsupported('start');
  Future<void> close() async => _unsupported('close');
}

/// VM stub — see `broadcast_channel.dart` for the real API.
final class BroadcastChannelTransport implements GameConnection {
  BroadcastChannelTransport._();
  static Future<BroadcastChannelTransport> connect(
    String channel, {
    String? id,
    Duration timeout = const Duration(seconds: 10),
  }) => _unsupported('connect');

  @override
  Stream<dynamic> get messages => _unsupported('messages');
  @override
  bool get open => false;
  @override
  void send(String message) => _unsupported('send');
  @override
  Future<void> close([int? code, String? reason]) async =>
      _unsupported('close');
}
