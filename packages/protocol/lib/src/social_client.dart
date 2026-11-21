import 'chat.dart';

/// The transport provides a reliable send callback and calls [receive]. A UI
/// reads this model after its room client's normal change notification.
class RoomSocialClient {
  RoomSocialClient(this._send, {Duration Function()? clock})
    : _now = clock ?? _monotonicClock();
  final void Function(Map<String, dynamic>) _send;
  final Duration Function() _now;
  bool available = false, locked = false;
  String? leaderId, notice;
  List<RoomMember> members = const [];
  final _history = <ChatMessage>[];
  final _bubbles = <String, (ChatMessage, Duration)>{};
  final _pings = <(RoomPing, Duration)>[];
  final _muted = <String>{};
  List<ChatMessage> get messages => List.unmodifiable(
    _history.where((m) => m.system || !_muted.contains(m.playerId)),
  );
  List<ChatMessage> get bubbles => List.unmodifiable(
    _bubbles.values
        .where(
          (entry) => _now() < entry.$2 && !_muted.contains(entry.$1.playerId),
        )
        .map((entry) => entry.$1),
  );
  List<RoomPing> get pings => List.unmodifiable(
    _pings
        .where(
          (entry) => _now() < entry.$2 && !_muted.contains(entry.$1.playerId),
        )
        .map((entry) => entry.$1),
  );
  bool isMuted(String id) => _muted.contains(id);
  void mute(String id, bool muted) {
    if (muted) {
      _muted.add(id);
    } else {
      _muted.remove(id);
    }
  }

  bool sendChat(String text) {
    final clean = cleanChat(text);
    if (!available || clean == null) return false;
    _send({'type': 'chat', 'text': clean});
    return true;
  }

  void ping(String kind) {
    if (available && pingKinds.contains(kind)) {
      _send({'type': 'ping', 'kind': kind});
    }
  }

  void moderate(String action, {String? playerId, bool? locked}) {
    if (available) {
      _send({
        'type': 'moderate',
        'action': action,
        'playerId': ?playerId,
        'locked': ?locked,
      });
    }
  }

  /// Returns true only for a social frame. History is replaced on resume;
  /// replaying it does not create speech bubbles or duplicate messages.
  bool receive(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'social':
        available = true;
        locked = frame['locked'] == true;
        leaderId = frame['leaderId'] as String?;
        members = List.unmodifiable(
          (frame['members'] as List)
              .take(256)
              .map(
                (m) => RoomMember.fromJson(Map<String, dynamic>.from(m as Map)),
              ),
        );
        if (frame['history'] case final List history) {
          _history.clear();
          _bubbles.clear();
          _pings.clear();
          for (final m in history.skip(
            (history.length - chatHistoryLimit).clamp(0, history.length),
          )) {
            _append(ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)));
          }
        }
      case 'chat':
        final message = ChatMessage.fromJson(
          frame['message'] as Map<String, dynamic>,
        );
        if (!_append(message)) return true;
        if (!message.system) {
          _bubbles.remove(message.playerId);
          if (_bubbles.length >= 128) _bubbles.remove(_bubbles.keys.first);
          _bubbles[message.playerId] = (message, _now() + chatBubbleLifetime);
        }
      case 'ping':
        final ping = RoomPing.fromJson(frame['ping'] as Map<String, dynamic>);
        if (_pings.any((p) => p.$1.id == ping.id)) return true;
        _pings.add((ping, _now() + pingLifetime));
        if (_pings.length > 32) _pings.removeAt(0);
      case 'socialNotice':
        notice = frame['message'] as String;
      default:
        return false;
    }
    return true;
  }

  bool _append(ChatMessage message) {
    if (_history.any((m) => m.id == message.id)) return false;
    _history.add(message);
    if (_history.length > chatHistoryLimit) _history.removeAt(0);
    return true;
  }

  void disconnect() {
    available = false;
  }
}

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
