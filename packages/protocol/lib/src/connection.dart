/// Reliable control transport. Implementations own platform socket handles.
abstract interface class GameConnection {
  Stream<dynamic> get messages;
  bool get open;
  void send(String message);
  Future<void> close([int? code, String? reason]);
}

/// Optional disposable state lane; reliability belongs to the message protocol.
abstract interface class StateGameConnection {
  void sendState(String message);
}

/// Transports that can carry binary frames. Servers send state snapshots as
/// FlatBuffer bytes whenever the peer transport implements this; JSON text
/// remains the fallback. Binary frames never begin with 0x7B ('{').
abstract interface class BinaryGameConnection implements GameConnection {
  void sendBytes(List<int> bytes);
}

/// Binary-capable state lane (WebRTC unordered channel).
abstract interface class BinaryStateGameConnection implements StateGameConnection {
  void sendStateBytes(List<int> bytes);
}
