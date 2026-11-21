import 'room_social.dart';

/// Game-specific validation and simulation behind the authoritative room host.
/// Networking never imports physics, character models, UI or a course format.
abstract interface class RoomAuthority {
  int get capacity;
  int get tick;
  double get elapsed;
  void update(double seconds);
  Object? validateJoin(Map<String, dynamic> message);
  void addPlayer(String id, String name, Object? joinData);
  void resume(String id, Object? joinData);
  void disconnect(String id);
  void removePlayer(String id);
  Map<String, dynamic> welcome(String id);
  void command(String id, Map<String, dynamic> message);
  Map<String, dynamic> snapshot();
  void dispose();
}

/// Optional game-specific permissions and ping locations. Coordinates never
/// come from a peer's chat/ping packet.
abstract interface class RoomSocialAuthority {
  String? get roomLeaderId;
  PingLocation? pingLocation(String playerId, String kind);
}
