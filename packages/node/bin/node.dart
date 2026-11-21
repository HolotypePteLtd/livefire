import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rooms_node/rooms_node.dart';

/// Rooms node entrypoint: `bin/node.dart --config <node.json>`.
///
/// One process, one port: the control-plane API (`/v1/*`) and the data
/// plane (`/play/<roomKey>`) behind join-token, origin and throttle gates.
/// Behind a reverse proxy (Caddy) for TLS. Fails fast on an invalid
/// config; drains rooms on SIGINT/SIGTERM.
Future<void> main(List<String> args) async {
  String? configPath;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') {
      stdout.writeln('usage: node --config <node.json>');
      return;
    }
    if (arg == '--config') {
      if (i + 1 >= args.length) {
        _fail('--config requires a path');
      }
      configPath = args[++i];
    } else {
      _fail('unknown argument: $arg\nusage: node --config <node.json>');
    }
  }
  if (configPath == null) {
    _fail('missing --config <path>\nusage: node --config <node.json>');
  }
  final file = File(configPath);
  if (!file.existsSync()) {
    _fail('config file not found: $configPath');
  }
  final NodeConfig config;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      _fail('config must be a JSON object');
    }
    config = NodeConfig.fromJson(decoded);
  } on FormatException catch (e) {
    _fail('invalid config: ${e.message}');
  }

  final node = await startNode(config);
  stdout.writeln(
    'rooms-node listening on ${config.listen.address}:${node.port} '
    '(public: ${config.publicBaseUrl}, '
    'physics: ${config.physics ? 'on' : 'off'}, '
    'platform: ${node.platform.mode})',
  );

  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    stdout.writeln('rooms-node: $signal — draining rooms');
    await stopNode(node);
    exit(0);
  }

  ProcessSignal.sigterm
      .watch()
      .listen((signal) => unawaited(shutdown(signal)));
  ProcessSignal.sigint
      .watch()
      .listen((signal) => unawaited(shutdown(signal)));
}

Never _fail(String message) {
  stderr.writeln('rooms-node: $message');
  exit(1);
}
