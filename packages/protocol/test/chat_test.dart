import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('chat is bounded, rejects controls, and rates use monotonic time', () {
    final host = RoomSocialHost();
    expect(
      () => host.chat('p1', 'Player', 'hello\nworld', Duration.zero),
      throwsFormatException,
    );
    expect(
      () => host.chat('p1', 'Player', 'a' * 281, Duration.zero),
      throwsFormatException,
    );
    for (var i = 0; i < 4; i++) {
      host.chat('p1', 'Player', 'Hi', Duration.zero);
    }
    expect(
      () => host.chat('p1', 'Player', 'Hi', Duration.zero),
      throwsFormatException,
    );
    host.chat('p1', 'Player', 'After waiting', const Duration(seconds: 10));
    for (var i = 0; i < 150; i++) {
      host.system('p1', 'Player', 'joined');
    }
    expect(host.history.length, chatHistoryLimit);
  });
  test('replay, duplicate frames, local mute, and bubble/ping expiry', () {
    var now = Duration.zero;
    final sent = <Map<String, dynamic>>[];
    final client = RoomSocialClient(sent.add, clock: () => now);
    final host = RoomSocialHost();
    final chat = host.chat('p1', 'Player', 'hello', now);
    final state = {
      'type': 'social',
      'leaderId': 'p1',
      'locked': false,
      'members': <dynamic>[],
      'history': host.history,
    };
    client.receive(state);
    expect(client.bubbles, isEmpty);
    client.receive(chat);
    expect(client.messages.length, 1);
    expect(client.bubbles, isEmpty);
    final live = host.chat('p1', 'Player', 'live', now);
    client.receive(live);
    client.receive(live);
    expect(client.messages.length, 2);
    expect(client.bubbles.single.text, 'live');
    client.receive(
      host.ping('p1', 'Player', 'help', const PingLocation(1, 2, 3, 4), now),
    );
    expect(client.pings.single.location.epoch, 4);
    client.mute('p1', true);
    expect(client.messages, isEmpty);
    expect(client.bubbles, isEmpty);
    expect(client.pings, isEmpty);
    client.mute('p1', false);
    expect(client.sendChat(' <b>plain text</b> '), isTrue);
    expect(sent.single['text'], '<b>plain text</b>');
    now += const Duration(seconds: 8);
    expect(client.pings, isEmpty);
    expect(client.bubbles.length, 1);
    now += const Duration(seconds: 2);
    expect(client.bubbles, isEmpty);
    expect(client.messages.length, 2);
    client.receive(state);
    expect(client.messages.length, 1);
  });
}
