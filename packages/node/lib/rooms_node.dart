import 'dart:convert';
import 'dart:io';

import 'package:livefire_atproto_server/livefire_atproto_server.dart';
import 'package:physics_react3d/physics_react3d.dart';
import 'package:server_sdk/server_sdk.dart';

import 'src/node_config.dart' show NodeConfig, NodeIdent;

export 'src/node_config.dart';

/// A started node: the listener plus the platform store that must be
/// closed with it.
class NodeProcess {
  NodeProcess({required this.listener, required this.platform, this.ident});
  final AtprotoRoomsListener listener;
  final PlatformStore platform;

  /// The guest identity ladder, when the config enabled it — closed
  /// with the process.
  final GuestIdentityApi? ident;

  int get port => listener.port;
}

/// Wires a complete rooms node from a validated [config]: supervisor (with
/// the relay template always, physics rooms when enabled and the native
/// backend available), SQLite store in the data dir, control-plane API,
/// the developer panel (`/panel`, when admins are configured) and the
/// single multi-room listener — plus, when `auth.providers` includes
/// `atproto`, the OAuth client provider and the DID profile service
/// (`docs/identity.md`). Returns the started listener.
///
/// Room configurations and consumed join tokens live in the node's SQLite
/// file. Live game state is held in memory. Panel admins, API keys,
/// scopes, counters, and the audit log use SQLite unless
/// `SUPABASE_URL` + `SUPABASE_SECRET_KEY` are set in the environment:
/// then it moves to the shared Supabase Postgres (via Kong + the
/// service key), `adminDids` seeds `panel_admins` once, and the panel
/// gains admin management, scoped keys and the audit log.
Future<NodeProcess> startNode(NodeConfig config) async {
  final dataDir = Directory(config.dataDir);
  if (!await dataDir.exists()) {
    await dataDir.create(recursive: true);
  }
  final store = NodeStore.open('${config.dataDir}/rooms.db');
  final tokens = JoinTokens(utf8.encode(config.nodeSecret),
      defaultTtl: Duration(seconds: config.joinTokenTtlSeconds));
  final trustedProxies = config.trustedProxies.toSet();

  // Platform persistence: Postgres when the Supabase env pair is set,
  // otherwise the node's own SQLite — byte-for-byte the old behavior.
  final supabase = await SupabasePlatformStore.fromEnvironment(
    bootstrapKeys: config.apiKeys,
    seedAdminDids: config.adminDids,
  );
  final PlatformStore platform;
  if (supabase != null) {
    platform = supabase;
    stdout.writeln(
        'rooms-node: platform data in Supabase Postgres (${supabase.seededAdmins ? 'adminDids seeded' : 'admins already in database'}); room configs and token usage stay in SQLite');
  } else {
    store.seedApiKeys(config.apiKeys);
    platform = SqlitePlatformStore(store, adminDids: config.adminDids);
  }

  // AT Protocol identity (optional provider): the node is a confidential
  // OAuth client; DID-bearing join tokens carry the verified identity.
  late final sqliteAccounts = SqliteAccountStore(store.database);
  AtprotoAuthProvider? atproto;
  ProfileService? profiles;
  final identityIndex = RoomIdentityIndex();
  final atprotoConfig = config.auth.atprotoEnabled
      ? config.auth.atproto
      : null;
  if (atprotoConfig != null) {
    atproto = AtprotoAuthProvider(
      publicBaseUrl: config.publicBaseUrl,
      keys: await NodeClientKeys.fromJwkFile(atprotoConfig.jwksPath),
      tokens: tokens,
      clientName: atprotoConfig.clientName,
      identityResolver: NodeAtprotoResolver(
        entrywayUrl: atprotoConfig.entrywayUrl,
        plcDirectoryUrl: atprotoConfig.plcDirectoryUrl,
      ),
      // Match events as public records (docs/match_events.md):
      // only a node that enabled publishEvents asks players for the
      // repo-write scope; every other node keeps read-only sign-in.
      repoWriteScope: config.publishEvents.enabled,
    );
    profiles = ProfileService(store: sqliteAccounts);
  }

  Map<String, dynamic>? profileLookup(String roomKey, String peerId) {
    final did = identityIndex.didOf(roomKey, peerId);
    return did == null ? null : profiles?.profileOf(did);
  }

  final factories = <AuthorityFactory>[
    RelayAuthorityFactory(
      creatorVerify: (roomKey, token) =>
          tokens.verify(token, roomKey: roomKey, now: DateTime.now().toUtc()),
      profileLookup: profileLookup,
    ),
    if (config.physics)
      MovementAuthorityFactory(
        React3dPhysicsBackend.new,
        creatorVerify: (roomKey, token) =>
            tokens.verify(token, roomKey: roomKey, now: DateTime.now().toUtc()),
        profileLookup: profileLookup,
      ),
  ];
  final supervisor = RoomSupervisor(
    factories: factories,
    maxRooms: config.limits.maxRooms,
    maxReservedCapacity: config.limits.maxReservedCapacity,
    idleTtl: Duration(seconds: config.limits.idleTtlSeconds),
  )..startTicker(hz: 60);
  final api = ControlPlaneApi(
    supervisor: supervisor,
    store: store,
    platform: platform,
    tokens: tokens,
    publicBaseUrl: config.publicBaseUrl,
    joinTokenTtl: Duration(seconds: config.joinTokenTtlSeconds),
  );
  // The developer panel: same-origin at /panel, atproto sign-in, admins
  // from the platform store. Constructed even when disabled (no admins
  // or guest-only auth) so the page itself can say "panel disabled".
  final panel = PanelApi(
    store: store,
    platform: platform,
    supervisor: supervisor,
    tokens: tokens,
    atproto: atproto,
    trustedProxies: trustedProxies,
  );

  // Guest identity ladder (/ident/*): device accounts on the node's
  // PDS + client-held recovery keys (docs/identity.md). Off unless the
  // `ident` block is present in the config.
  GuestIdentityApi? ident;
  final NodeIdent? identConfig = config.ident;
  if (identConfig != null) {
    ident = GuestIdentityApi(
      platform: platform,
      accounts: supabase == null
          ? sqliteAccounts
          : SupabaseDeviceAccountStore(supabase),
      tokens: tokens,
      store: store,
      supervisor: supervisor,
      // serviceKey = the PDS admin password: the host mints one
      // single-use invite code per guest account with it (the only
      // creation path a stock reference PDS offers) and persists the
      // generated guest password for later repo writes.
      guests: HttpGuestAccountHost(
        pdsUrl: Uri.parse(identConfig.pdsUrl),
        serviceKey: identConfig.serviceKey,
      ),
      publicBaseUrl: config.publicBaseUrl,
      handleDomain: identConfig.handleDomain,
      nonceTtl: Duration(seconds: identConfig.nonceTtlSeconds),
      sessionTtl: Duration(seconds: identConfig.sessionTtlSeconds),
      throttle: IpThrottle(
        maxPerWindow: config.limits.connectionsPerIpPerMinute,
      ),
      trustedProxies: trustedProxies,
    );
  }

  final listener = AtprotoRoomsListener(
    supervisor: supervisor,
    api: api,
    store: store,
    tokens: tokens,
    tokenLedger: store,
    originGate: OriginGate(config.allowedOrigins),
    throttle: IpThrottle(
      maxPerWindow: config.limits.connectionsPerIpPerMinute,
    ),
    trustedProxies: trustedProxies,
    atproto: atproto,
    panel: panel,
    ident: ident,
    onPeerAttached: atproto == null
        ? null
        : (room, peer) {
            final did = peer.identity;
            if (did == null) return;
            identityIndex.set(room.key, peer.id, did);
            profiles?.ensure(
              did,
              pds: atproto?.pdsOf(did),
              hub: room.hub,
            );
          },
  );
  await listener.start(port: config.listen.port, address: config.listen.address);
  return NodeProcess(listener: listener, platform: platform, ident: ident);
}

/// Stops a node started by [startNode]: stops accepting, drains every room
/// (peers see close code `1001`), closes the store and the platform
/// store.
Future<void> stopNode(NodeProcess node) async {
  final supervisor = node.listener.supervisor;
  final store = node.listener.store;
  await node.listener.close();
  await supervisor.close();
  store.close();
  await node.ident?.close();
  await node.platform.close();
}
