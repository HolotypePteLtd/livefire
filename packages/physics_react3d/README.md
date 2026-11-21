# physics_react3d

The [reactphysics3d_dart](https://github.com/nmfisher/reactphysics3d_dart)
implementation of `PhysicsBackend` for physics room templates
(`docs/room_templates.md`). This package is deliberately thin: it builds the
static physics world from a validated `MovementRoomConfig` (boxes, capsules,
heightfield, gravity), manages player capsule bodies, applies movement
intents and steps the engine. All config validation, input policing, spawn
assignment and movement game logic live in `server_sdk`, which depends on no
physics engine.

## Wiring a physics room

```dart
import 'package:physics_react3d/physics_react3d.dart';
import 'package:server_sdk/server_sdk.dart';

final config = MovementRoomConfig.fromJson(roomConfigJson);
final room = MovementTemplateAuthority(
  config,
  backend: React3dPhysicsBackend(),
  creatorToken: creatorToken,
);
final hub = RoomHub(
  authority: room,
  simulationHz: config.tick.simulationHz, // 60
  snapshotHz: config.tick.snapshotHz, // 20 — the hub snapshots at this rate
);
```

## Native library

reactphysics3d_dart is native FFI. Its build hook compiles the C bridge and
links a prebuilt ReactPhysics3D static archive (linux-x86_64/arm64,
macos-arm64 ship in the repo). Tests therefore need a C toolchain — `dart
pub get && dart test` builds the hook automatically. On other targets,
provide a compatible archive first (see that package's BUILDING.md).

The upstream dependency is pinned by commit in `pubspec.yaml`; it is a
private GitHub repository, so `dart pub get` needs credentials for
`https://github.com/nmfisher/reactphysics3d_dart.git`.

## Conventions and simplifications (v0)

- Spawn positions are **feet** positions; the player capsule centre lands at
  `spawn.y + playerHeight / 2`. Player capsule size (radius 0.4 m, height
  1.8 m) is a fixed v0 constant, overridable on `React3dPhysicsBackend`.
- Heightfields sample at one-metre spacing and centre on the origin: `size`
  counts cells per axis and the field spans `nx × nz` metres.
- Player bodies are dynamic capsules with velocity-target control: the
  authority sets horizontal velocity each tick, the engine resolves
  collisions (walls block, floors support), gravity owns vertical dynamics.
  Orientation is pinned upright; facing (yaw) is authority-side.
- The grounded check raycasts from the body centre downward past the feet
  (rays ignore shapes they start inside, so the own capsule never matches).
