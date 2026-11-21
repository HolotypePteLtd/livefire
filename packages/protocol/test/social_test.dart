import 'dart:async';
import 'dart:convert';
import 'package:client/client.dart';
import 'package:test/test.dart';
import 'room_test.dart' show CounterAuthority, until;

class SocialAuthority extends CounterAuthority implements RoomSocialAuthority {
  @override
  int get capacity => 8;
  @override
  String? get roomLeaderId => counters.keys.firstOrNull;
  @override
  PingLocation? pingLocation(String id, String kind) =>
      const PingLocation(1, 2, 3, 7);
}

class SocialClient extends RoomClient<RoomSnapshot> {
  SocialClient(String name, Future<GameConnection> Function() connector)
    : super(
        uri: Uri.parse('memory://social'),
        name: name,
        protocolVersion: 71,
        connector: connector,
      );
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

void main() {
  test(
    'reliable chat stamps sender, rates separately, pings use authority positions',
    () async {
      final hub = RoomHub(SocialAuthority(), protocolVersion: 71);
      final clients = <SocialClient>[];
      addTearDown(() async {
        for (final c in clients) {
          await c.close();
        }
        await hub.close();
      });
      Future<SocialClient> join(String name) async {
        final c = SocialClient(name, () async {
          final pair = MemoryTransportPair();
          unawaited(hub.runTransport(pair.b));
          return pair.a;
        });
        clients.add(c);
        await c.connect();
        await until(() => c.social.available);
        return c;
      }

      final host = await join('Host'), guest = await join('Guest');
      guest.sendControl({
        'type': 'chat',
        'text': 'hello',
        'playerId': host.id,
        'playerName': 'Forged',
      });
      await until(() => host.social.messages.any((m) => m.text == 'hello'));
      final message = host.social.messages.last;
      expect(message.playerId, guest.id);
      expect(message.playerName, 'Guest');
      guest.sendControl({
        'type': 'ping',
        'kind': 'help',
        'x': 999,
        'epoch': -1,
      });
      await until(() => host.social.pings.isNotEmpty);
      expect(host.social.pings.single.location.x, 1);
      expect(host.social.pings.single.location.epoch, 7);
      for (var i = 0; i < 4; i++) {
        guest.social.sendChat('burst $i');
      }
      await until(() => guest.social.notice != null);
      expect(guest.connected, isTrue);
      expect(
        host.social.messages.where((m) => m.text.startsWith('burst')).length,
        3,
      );
      guest.social.moderate('kick', playerId: host.id);
      await until(() => guest.social.notice!.contains('Only the host'));
      expect(host.connected, isTrue);
      host.social.moderate('lock', locked: true);
      await until(() => guest.social.locked);
      final denied = SocialClient('Late', () async {
        final pair = MemoryTransportPair();
        unawaited(hub.runTransport(pair.b));
        return pair.a;
      });
      clients.add(denied);
      await expectLater(denied.connect(), throwsStateError);
      final token = guest.resumeToken;
      await guest.interruptConnection();
      await until(() => guest.connected);
      expect(guest.resumeToken, token);
      expect(guest.social.messages.where((m) => m.text == 'hello').length, 1);
      host.social.moderate('kick', playerId: guest.id);
      await until(() => guest.error != null);
      expect(guest.resumeToken, isNull);
      expect(guest.reconnecting, isFalse);
      expect(hub.peerCount, 1);
    },
  );
  test('verified identity binds resume and room-lifetime bans', () async {
    final hub = RoomHub(SocialAuthority(), protocolVersion: 71);
    addTearDown(hub.close);
    Future<(MemoryTransport, List<Map<String, dynamic>>, HubPeer?)> join(
      String name,
      String identity, {
      String? resume,
    }) async {
      final pair = MemoryTransportPair();
      final frames = <Map<String, dynamic>>[];
      pair.a.messages.listen((m) {
        if (m is String) frames.add(jsonDecode(m) as Map<String, dynamic>);
      });
      final attached = hub.runTransport(pair.b, identity: identity);
      pair.a.send(
        jsonEncode({
          'type': 'join',
          'protocol': 71,
          'name': name,
          'resume': resume,
        }),
      );
      final peer = await attached;
      await Future<void>.delayed(Duration.zero);
      return (pair.a, frames, peer);
    }

    final host = await join('Host', 'did:plc:host');
    final guest = await join('Guest', 'did:plc:guest');
    final impostor = await join(
      'Forged',
      'did:plc:other',
      resume: guest.$3!.token,
    );
    expect(impostor.$3, isNull);
    expect(impostor.$2.last['type'], 'error');
    host.$1.send(
      jsonEncode({
        'type': 'moderate',
        'action': 'ban',
        'playerId': guest.$3!.id,
      }),
    );
    await until(() => hub.peerCount == 1);
    final banned = await join('Again', 'did:plc:guest');
    expect(banned.$3, isNull);
    expect(banned.$2.last['message'], contains('banned'));
  });
}
