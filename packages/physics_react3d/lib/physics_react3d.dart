/// reactphysics3d_dart binding for physics room templates.
///
/// Exports [React3dPhysicsBackend], the reference [PhysicsBackend] for
/// `server_sdk`'s `MovementTemplateAuthority`. This package holds engine
/// code only — config parsing, validation and movement game logic all live
/// in `server_sdk`, which stays engine-free.
library;

export 'package:server_sdk/server_sdk.dart'
    show MovementRoomConfig, PhysicsBackend, BackendPose, BackendSpawn, MovementIntent;

export 'src/react3d_backend.dart';
