// The world demo's room SERVER — compiled to WebAssembly and loaded by
// /world/server/ (server.astro). Runs the real room engine in the iframe:
// a RoomHub over the kinematic world authority, reachable through the
// SDK's BroadcastChannel transport. No DOM beyond a status line.
import 'dart:async';

import 'dart:js_interop';

import 'package:protocol/protocol.dart';
import 'package:web/web.dart' as web;

import 'package:world_demo/kinematic_world.dart';

Future<void> main() async {
  final params = web.URLSearchParams(web.window.location.search.toJS);
  final channel = 'openfire-world-${params.get('c') ?? ''}';
  if (channel.endsWith('-')) {
    _status('missing ?c= session id');
    return;
  }

  final hub = RoomHub(
    KinematicWorldAuthority(),
    protocolVersion: protocolVersion,
    simulationHz: 20,
    snapshotHz: 10,
    roomKey: 'world-demo',
  );
  final listener = BroadcastChannelListener(channel);
  listener.onConnection.listen(
    (transport) => unawaited(hub.runTransport(transport)),
  );
  await listener.start();
  hub.start();
  _status('engine live · 0 players');

  // One status update per second; the engine ticks at 20 Hz.
  var lastTick = -1;
  Timer.periodic(const Duration(seconds: 1), (_) {
    if (hub.isClosed) return;
    final tick = hub.tick;
    final moving = tick != lastTick;
    lastTick = tick;
    _status(
      'engine live · ${hub.peerCount} player(s) · tick $tick'
      '${moving ? '' : ' (paused)'}',
    );
  });

  web.window.addEventListener(
    'beforeunload',
    ((web.Event _) {
      unawaited(_close(listener, hub));
      return null;
    }).toJS,
  );
}

Future<void> _close(
  BroadcastChannelListener listener,
  RoomHub hub,
) async {
  await listener.close();
  await hub.close();
}

void _status(String text) {
  web.document.querySelector('#world-status')?.textContent = text;
}
