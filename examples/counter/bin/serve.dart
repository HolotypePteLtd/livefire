// A standalone counter room server for cross-language integration
// tests (e.g. sdk/typescript): the demo authority from bin/counter.dart
// behind a real RoomServer on a fixed port. Run:
//   dart run bin/serve.dart [port]
// Prints the room URI on stdout, then exits cleanly when stdin closes
// (the test parent shuts it down without signals).
import 'dart:async';
import 'dart:io';

import 'package:server_sdk/server_sdk.dart';

import 'counter.dart';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 18790 : int.parse(args.first);
  final server = RoomServer(
    CounterAuthority(),
    protocolVersion: 1,
    simulationHz: 60,
    snapshotHz: 15,
    roomKey: 'demo-room',
  );
  await server.start(port: port, address: InternetAddress.loopbackIPv4);
  print('[serve] ${server.localUri}');
  await stdin.first;
  await server.close();
  print('[serve] closed');
}
