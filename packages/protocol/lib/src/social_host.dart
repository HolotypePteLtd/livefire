import 'dart:collection';
import 'chat.dart';

/// Host-side chat state, independent of room simulation time. Sender identity
/// and ping positions must come from the authenticated room adapter.
class RoomSocialHost {
  final _history = Queue<ChatMessage>();
  final _chatRates = <String, Queue<Duration>>{};
  final _pingRates = <String, Queue<Duration>>{};
  int _nextId = 1;
  List<Map<String, dynamic>> get history =>
      _history.map((m) => m.toJson()).toList();
  Map<String, dynamic> chat(
    String id,
    String name,
    Object? text,
    Duration now,
  ) {
    final clean = cleanChat(text);
    if (clean == null) {
      throw const FormatException('Use 1–280 characters on one line');
    }
    if (!_admit(_chatRates, id, now, 4, const Duration(seconds: 10))) {
      throw const FormatException('Chat is too fast; wait a few seconds');
    }
    return _message(id, name, clean);
  }

  Map<String, dynamic> system(String id, String name, String text) =>
      _message(id, name, text, system: true);
  Map<String, dynamic> _message(
    String id,
    String name,
    String text, {
    bool system = false,
  }) {
    final message = ChatMessage(
      id: _nextId++,
      playerId: id,
      playerName: name,
      text: text,
      system: system,
    );
    _history.add(message);
    if (_history.length > chatHistoryLimit) _history.removeFirst();
    return {'type': 'chat', 'message': message.toJson()};
  }

  Map<String, dynamic> ping(
    String id,
    String name,
    String kind,
    PingLocation location,
    Duration now,
  ) {
    if (!pingKinds.contains(kind)) throw const FormatException('Unknown ping');
    if (!_admit(_pingRates, id, now, 3, const Duration(seconds: 5))) {
      throw const FormatException('Pings are too fast; wait a few seconds');
    }
    return {
      'type': 'ping',
      'ping': RoomPing(_nextId++, id, name, kind, location).toJson(),
    };
  }

  bool _admit(
    Map<String, Queue<Duration>> rates,
    String id,
    Duration now,
    int limit,
    Duration interval,
  ) {
    final queue = rates.putIfAbsent(id, Queue.new);
    while (queue.isNotEmpty && now - queue.first >= interval) {
      queue.removeFirst();
    }
    if (queue.length >= limit) return false;
    queue.add(now);
    return true;
  }

  void removePlayer(String id) {
    _chatRates.remove(id);
    _pingRates.remove(id);
  }
}
