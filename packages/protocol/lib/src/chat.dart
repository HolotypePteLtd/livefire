const chatMaxLength = 280;
const chatHistoryLimit = 100;
const chatBubbleLifetime = Duration(seconds: 10);
const pingLifetime = Duration(seconds: 8);
const pingKinds = {'here', 'help', 'ball'};

/// Single-line text; reject hidden controls and bidi overrides as well as
/// oversized input. All UIs render this as text, never markup.
String? cleanChat(Object? value) {
  if (value is! String || value.length > chatMaxLength) return null;
  final text = value.trim();
  if (text.isEmpty ||
      text.contains(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
      )) {
    return null;
  }
  return text;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.playerId,
    required this.playerName,
    required this.text,
    this.system = false,
  });
  final int id;
  final String playerId, playerName, text;
  final bool system;
  Map<String, dynamic> toJson() => {
    'id': id,
    'playerId': playerId,
    'playerName': playerName,
    'text': text,
    'system': system,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final text = cleanChat(json['text']);
    if (text == null) throw const FormatException('Invalid chat text');
    return ChatMessage(
      id: json['id'] as int,
      playerId: json['playerId'] as String,
      playerName: json['playerName'] as String,
      text: text,
      system: json['system'] == true,
    );
  }
}

/// The game supplies authoritative coordinates and an epoch (hole/scene).
class PingLocation {
  const PingLocation(this.x, this.y, this.z, this.epoch);
  final double x, y, z;
  final int epoch;
  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'z': z, 'epoch': epoch};
  factory PingLocation.fromJson(Map<String, dynamic> json) {
    final result = PingLocation(
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
      (json['z'] as num).toDouble(),
      json['epoch'] as int,
    );
    if (!result.x.isFinite || !result.y.isFinite || !result.z.isFinite) {
      throw const FormatException('Invalid ping position');
    }
    return result;
  }
}

class RoomPing {
  const RoomPing(
    this.id,
    this.playerId,
    this.playerName,
    this.kind,
    this.location,
  );
  final int id;
  final String playerId, playerName, kind;
  final PingLocation location;
  Map<String, dynamic> toJson() => {
    'id': id,
    'playerId': playerId,
    'playerName': playerName,
    'kind': kind,
    'location': location.toJson(),
  };
  factory RoomPing.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    if (!pingKinds.contains(kind)) throw const FormatException('Invalid ping');
    return RoomPing(
      json['id'] as int,
      json['playerId'] as String,
      json['playerName'] as String,
      kind,
      PingLocation.fromJson(json['location'] as Map<String, dynamic>),
    );
  }
  String get label => switch (kind) {
    'help' => 'Needs help!',
    'ball' => 'My ball',
    _ => 'Over here!',
  };
}

class RoomMember {
  const RoomMember(
    this.id,
    this.name, {
    required this.connected,
    this.canBan = false,
    this.profile,
  });
  final String id, name;
  final bool connected, canBan;

  /// Optional identity profile attached by the host (e.g. a prefetched
  /// AT Protocol profile: displayName/avatar keyed by DID). Host-supplied
  /// only; clients render it if present. Absent for guests and until the
  /// host's async fetch lands.
  final Map<String, dynamic>? profile;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'connected': connected,
    'canBan': canBan,
    if (profile != null) 'profile': profile,
  };
  factory RoomMember.fromJson(Map<String, dynamic> json) => RoomMember(
    json['id'] as String,
    json['name'] as String,
    connected: json['connected'] == true,
    canBan: json['canBan'] == true,
    profile: json['profile'] is Map
        ? Map<String, dynamic>.from(json['profile'] as Map)
        : null,
  );
}
