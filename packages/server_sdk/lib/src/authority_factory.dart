import 'package:protocol/protocol.dart';

import 'join_tokens.dart';

import 'movement_config.dart';
import 'movement_authority.dart';
import 'physics_backend.dart';
import 'relay_authority.dart';
import 'relay_config.dart';

/// A room built by an [AuthorityFactory]: the running hub plus the pinned
/// config it was built from (echoed by the control plane, never re-parsed).
class BuiltRoom {
  BuiltRoom({required this.hub, required this.config});

  final RoomHub hub;

  /// The config exactly as submitted, already validated by [build].
  final Map<String, dynamic> config;

  int get capacity => hub.authority.capacity;
}

/// Builds rooms for one room template. The factory is where a submitted
/// config is validated against `docs/room_templates.md` **before** the room
/// is provisioned; [build] throws [FormatException] on an invalid config.
///
/// The supervisor stays template-agnostic: nodes register one factory per
/// template they run (`relay`, `physics`, …), which is also where physics
/// engines are injected — `server_sdk` itself stays engine-free.
abstract interface class AuthorityFactory {
  /// The template name this factory builds (`"relay"`, `"physics"`).
  String get template;

  /// Validate [config] and build a room from it. [creatorToken] is the
  /// leader-claim secret minted by the control plane with the room;
  /// [roomKey] is the key the room will be registered under (used to bind
  /// signed creator claims to this room).
  BuiltRoom build(Map<String, dynamic> config,
      {required String creatorToken, String? roomKey});
}

/// `relay` rooms: client-authoritative rows under server quotas. Host rates
/// follow the documented relay defaults (20 Hz simulation / 10 Hz snapshots
/// for density); the relay config schema has no tick section.
class RelayAuthorityFactory implements AuthorityFactory {
  const RelayAuthorityFactory({
    this.resumeGrace = const Duration(seconds: 15),
    this.creatorVerify,
    this.profileLookup,
  });

  /// Disconnect grace before a peer is removed (tests shrink it).
  final Duration resumeGrace;

  /// SEAM(join-token): when set, rooms verify signed creator claims
  /// (`ct_…`, `cr: true`, optionally DID-bearing) instead of comparing the
  /// opaque [creatorToken] string. The node wires this to its
  /// control-plane token verifier.
  final TokenCheck Function(String roomKey, String token)? creatorVerify;

  /// Roster profile lookup `(roomKey, peerId) → profile` (the node keys
  /// peer ids to DIDs as they attach; profiles come from its cache).
  final Map<String, dynamic>? Function(String roomKey, String peerId)?
      profileLookup;

  @override
  String get template => 'relay';

  @override
  BuiltRoom build(Map<String, dynamic> config,
      {required String creatorToken, String? roomKey}) {
    final parsed = RelayRoomConfig.fromJson(config);
    final verify = creatorVerify;
    final lookup = profileLookup;
    return BuiltRoom(
      hub: RoomHub(
        RelayAuthority(
          parsed,
          creatorToken: creatorToken,
          creatorTokenVerifier: verify == null || roomKey == null
              ? null
              : (token) => verify(roomKey, token),
        ),
        protocolVersion: 1,
        simulationHz: 20,
        snapshotHz: 10,
        profileOf: lookup == null || roomKey == null
            ? null
            : (peerId) => lookup(roomKey, peerId),
        resumeGrace: resumeGrace,
      ),
      config: config,
    );
  }
}

/// `physics` rooms: server-simulated movement. Tick rates come from the
/// config's `tick` section; the physics engine arrives via [backendFactory]
/// so `server_sdk` never imports one — the node binary wires
/// `physics_react3d`, tests wire a deterministic backend.
class MovementAuthorityFactory implements AuthorityFactory {
  const MovementAuthorityFactory(this.backendFactory,
      {this.resumeGrace = const Duration(seconds: 15), this.creatorVerify,
      this.profileLookup});

  /// One backend per room (backends own a whole physics world).
  final PhysicsBackend Function() backendFactory;

  /// Signed creator-claim verification (see [RelayAuthorityFactory]).
  final TokenCheck Function(String roomKey, String token)? creatorVerify;

  /// Roster profile lookup (see [RelayAuthorityFactory]).
  final Map<String, dynamic>? Function(String roomKey, String peerId)?
      profileLookup;

  /// Disconnect grace before a peer is removed (tests shrink it).
  final Duration resumeGrace;

  @override
  String get template => 'physics';

  @override
  BuiltRoom build(Map<String, dynamic> config,
      {required String creatorToken, String? roomKey}) {
    final parsed = MovementRoomConfig.fromJson(config);
    final verify = creatorVerify;
    final lookup = profileLookup;
    return BuiltRoom(
      hub: RoomHub(
        MovementTemplateAuthority(
          parsed,
          backend: backendFactory(),
          creatorToken: creatorToken,
          creatorTokenVerifier: verify == null || roomKey == null
              ? null
              : (token) => verify(roomKey, token),
        ),
        profileOf: lookup == null || roomKey == null
            ? null
            : (peerId) => lookup(roomKey, peerId),
        protocolVersion: 1,
        simulationHz: parsed.tick.simulationHz,
        snapshotHz: parsed.tick.snapshotHz,
        resumeGrace: resumeGrace,
      ),
      config: config,
    );
  }
}
