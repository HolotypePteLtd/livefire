import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:livefire_atproto_server/livefire_atproto_server.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'atproto_world.dart';
import '../../server_sdk/test/supabase_stub.dart';

const apiKey = 'sk_test_node';

/// The full panel + control plane over the POSTGRES platform store
/// (`SupabasePlatformStore` against `FakeSupabase`, which implements
/// the migration's RPC semantics) — everything except the SQL itself,
/// which supabase/contract_test.sh proves against a real Postgres.
void main() {
  final world = FakeAtprotoWorld();
  setUpAll(() async {
    await world.start();
    world.addIdentity('admin.bsky.social', 'did:plc:admin');
    world.addIdentity('second.bsky.social', 'did:plc:second');
    world.addIdentity('third.bsky.social', 'did:plc:third');
  });
  tearDownAll(() => world.stop());
  setUp(() {
    world.clientMetadata = null;
    world.clientJwks = null;
  });

  final client = http.Client();

  Future<String> signIn(Uri base, String handle) async {
    final start = await client.get(base.replace(
      path: '/panel/api/auth/start',
      queryParameters: {'handle': handle},
    ));
    expect(start.statusCode, 200, reason: start.body);
    final startBody = jsonDecode(start.body) as Map<String, dynamic>;
    await world.client
        .get(Uri.parse(startBody['authorizationUrl'] as String));
    for (var i = 0; i < 100; i++) {
      final result = await client.get(base.replace(
        path: '/panel/api/auth/result',
        queryParameters: {'flow': startBody['flow'] as String},
      ));
      final body = jsonDecode(result.body) as Map<String, dynamic>;
      if (body['status'] == 'pending') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      return body['session'] as String;
    }
    fail('panel sign-in never completed');
  }

  Future<http.Response> panel(Uri base, String method, String path,
          {String? session, Object? body}) =>
      client.send(http.Request(method, base.replace(path: path))
        ..headers['Authorization'] = 'Bearer ${session ?? ''}'
        ..headers['Content-Type'] = 'application/json'
        ..body = body == null ? '' : jsonEncode(body))
          .then(http.Response.fromStream);

  test('Postgres mode: admins, scoped keys and audit, end to end', () async {
    final node = await _PgNode.start(world);
    addTearDown(node.stop);

    final session = await signIn(node.base, 'admin.bsky.social');

    // The session advertises the mode; the UI keys off it.
    final me = await panel(node.base, 'GET', '/panel/api/session', session: session);
    expect(jsonDecode(me.body), {
      'did': 'did:plc:admin',
      'handle': 'admin.bsky.social',
      'admin': true,
      'mode': 'postgres',
      'canManageAdmins': true,
    });

    // ---- Admins: seeded from config, then managed here ----------------
    final admins = await panel(node.base, 'GET', '/panel/api/admins', session: session);
    expect(jsonDecode(admins.body)['admins'].first['did'], 'did:plc:admin');

    // Promote by handle: the panel resolves it to the DID itself.
    final promoted = await panel(node.base, 'POST', '/panel/api/admins',
        session: session, body: {'didOrHandle': 'second.bsky.social'});
    expect(promoted.statusCode, 201, reason: promoted.body);
    final adminRows =
        (jsonDecode(promoted.body)['admins'] as List).cast<Map<String, dynamic>>();
    expect(adminRows.any((a) =>
        a['did'] == 'did:plc:second' && a['active'] == true), isTrue);

    // Guards: cannot revoke yourself, cannot revoke the last admin,
    // unknown DIDs 404 — the SQL codes map onto panel statuses.
    final self = await panel(node.base, 'POST',
        '/panel/api/admins/${Uri.encodeComponent('did:plc:admin')}/revoke',
        session: session);
    expect(self.statusCode, 409);
    expect(jsonDecode(self.body)['error']['message'],
        contains('your own'));

    final unknown = await panel(node.base, 'POST',
        '/panel/api/admins/${Uri.encodeComponent('did:plc:ghost')}/revoke',
        session: session);
    expect(unknown.statusCode, 404);

    // Revoke the second admin, then the last-admin guard would apply —
    // but there are still two, so this succeeds.
    final revoked = await panel(node.base, 'POST',
        '/panel/api/admins/${Uri.encodeComponent('did:plc:second')}/revoke',
        session: session);
    expect(revoked.statusCode, 200, reason: revoked.body);
    final nowLast = await panel(node.base, 'POST',
        '/panel/api/admins/${Uri.encodeComponent('did:plc:second')}/revoke',
        session: session);
    expect(nowLast.statusCode, 404); // already revoked -> not_found

    // ---- Scoped keys: created here, enforced at /v1 --------------------
    final relayConfig = {
      'version': 1,
      'template': 'relay',
      'capacity': 8,
      'maxRows': 64,
      'totalBytes': 32768,
      'playerKeys': {
        'pose': {'maxBytes': 256, 'publishesPerSecond': 10},
      },
      'roomKeys': {
        'phase': {'maxBytes': 64, 'publishesPerSecond': 1},
      },
    };
    final created = await panel(node.base, 'POST', '/panel/api/keys',
        session: session,
        body: {'label': 'demo game', 'maxRooms': 1, 'templates': ['relay']});
    expect(created.statusCode, 201, reason: created.body);
    final createdBody = jsonDecode(created.body) as Map<String, dynamic>;
    final fullKey = createdBody['key'] as String;
    expect(createdBody['maxRooms'], 1);
    expect(createdBody['templates'], ['relay']);

    // First, a template outside the key's set -> 403 (the room limit
    // has not been reached yet, so the template guard is what fires).
    final wrongTemplate = await client.post(node.base.replace(path: '/v1/rooms'),
        headers: {'Authorization': 'Bearer $fullKey'},
        body: jsonEncode({'template': 'physics', 'config': relayConfig}));
    expect(wrongTemplate.statusCode, 403);
    expect(jsonDecode(wrongTemplate.body)['error']['code'],
        'key_template_not_allowed');

    Future<http.Response> createRelay() => client.post(
      node.base.replace(path: '/v1/rooms'),
      headers: {'Authorization': 'Bearer $fullKey'},
      body: jsonEncode({'template': 'relay', 'config': relayConfig}),
    );

    node.supabase.rejectRoomRpc = true;
    final unavailable = await createRelay();
    expect(unavailable.statusCode, 503, reason: unavailable.body);
    expect(node.store.listRooms().rooms, isEmpty);
    expect(node.supervisor.rooms, isEmpty);
    node.supabase.rejectRoomRpc = false;

    final attempts = await Future.wait([createRelay(), createRelay()]);
    expect(attempts.map((response) => response.statusCode),
        unorderedEquals([201, 403]));
    final limited = attempts.singleWhere((response) => response.statusCode == 403);
    expect(jsonDecode(limited.body)['error']['code'], 'key_room_limit');
    expect(node.store.listRooms().rooms, hasLength(1));
    expect(node.supervisor.rooms, hasLength(1));

    // The bootstrap config key is unlimited and not a Postgres row.
    final boot = await client.post(node.base.replace(path: '/v1/rooms'),
        headers: {'Authorization': 'Bearer $apiKey'},
        body: jsonEncode({'template': 'relay', 'config': relayConfig}));
    expect(boot.statusCode, 201, reason: boot.body);
    final keys = await panel(node.base, 'GET', '/panel/api/keys', session: session);
    final keyRows = (jsonDecode(keys.body)['keys'] as List)
        .cast<Map<String, dynamic>>();
    final bootRow = keyRows.firstWhere((k) => k['bootstrap'] == true);
    expect(bootRow['id'], 'boot-default');
    final bootRevoke = await panel(node.base, 'POST',
        '/panel/api/keys/${bootRow['id']}/revoke', session: session);
    expect(bootRevoke.statusCode, 403);

    // Counters moved for the scoped key (1 room, 0 tokens).
    final scopedRow = keyRows.firstWhere((k) => k['id'] == createdBody['id']);
    expect(scopedRow['roomsCreated'], 1);
    expect(scopedRow['tokensMinted'], 0);

    // ---- Audit: every mutation above is in the log ----------------------
    final audit = await panel(node.base, 'GET', '/panel/api/audit', session: session);
    expect(audit.statusCode, 200);
    final entries = (jsonDecode(audit.body)['entries'] as List)
        .cast<Map<String, dynamic>>();
    final actions = entries.map((e) => e['action'] as String).toList();
    expect(actions.toSet().containsAll(
        ['admin.promote', 'admin.revoke', 'key.create']), isTrue);
    expect(entries.first['actorDid'], 'did:plc:admin');
    final keyCreate = entries.firstWhere((e) => e['action'] == 'key.create');
    expect(keyCreate['targetType'], 'api_key');
    expect(keyCreate['targetId'], createdBody['id']);
    expect(keyCreate['details'], {
      'label': 'demo game',
      'maxRooms': 1,
      'templates': ['relay'],
    });
    final promote = entries.firstWhere((e) => e['action'] == 'admin.promote');
    expect(promote['details'], {'handle': 'second.bsky.social'});

    // SQLite-mode-only rule: admin management is refused with guidance.
    // (Fresh OAuth client keys per node: let the fake AS re-discover.)
    world.clientMetadata = null;
    world.clientJwks = null;
    final sqlite = await _SqlitePanelNode.start(world);
    addTearDown(sqlite.stop);
    final sqliteSession = await signIn(sqlite.base, 'admin.bsky.social');
    final sqlitePromote = await panel(
        sqlite.base, 'POST', '/panel/api/admins',
        session: sqliteSession, body: {'didOrHandle': 'did:plc:third'});
    expect(sqlitePromote.statusCode, 403);
    expect(
        jsonDecode(sqlitePromote.body)['error']['message'],
        contains('SUPABASE_URL'));
    final sqliteAudit = await panel(
        sqlite.base, 'GET', '/panel/api/audit', session: sqliteSession);
    expect(sqliteAudit.statusCode, 404); // no audit log in SQLite mode
    final sqliteScoped = await panel(sqlite.base, 'POST', '/panel/api/keys',
        session: sqliteSession, body: {'label': 'x', 'maxRooms': 2});
    expect(sqliteScoped.statusCode, 400); // scopes need Postgres mode
  });
}

/// A whole panel node in POSTGRES persistence mode: rooms in an
/// in-memory SQLite store, platform data in SupabasePlatformStore over
/// the FakeSupabase RPC stub.
class _PgNode {
  _PgNode._(this.listener, this.supervisor, this.store, this.supabase,
      this.platform);

  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;
  final FakeSupabase supabase;
  final SupabasePlatformStore platform;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');

  static Future<_PgNode> start(FakeAtprotoWorld world) async {
    final store = NodeStore.open(':memory:');
    final supabase = FakeSupabase('svc-test-key');
    await supabase.start();
    final platform = await SupabasePlatformStore.connect(
      supabase.origin,
      'svc-test-key',
      bootstrapKeys: const {'default': apiKey},
      seedAdminDids: const ['did:plc:admin'],
    );
    final tokens = JoinTokens('node-secret'.codeUnits);
    final supervisor = RoomSupervisor(
      factories: [
        RelayAuthorityFactory(
          resumeGrace: const Duration(seconds: 1),
          creatorVerify: (roomKey, token) => tokens.verify(
            token,
            roomKey: roomKey,
            now: DateTime.now().toUtc(),
          ),
        ),
      ],
      maxRooms: 64,
    )..startTicker(hz: 60);
    final keys = await NodeClientKeys.generate();
    final provider = AtprotoAuthProvider(
      publicBaseUrl: 'http://127.0.0.1:0',
      keys: keys,
      tokens: tokens,
      identityResolver: NodeAtprotoResolver(
        entrywayUrl: world.origin,
        plcDirectoryUrl: world.origin,
        httpClient: world.newClient(),
        allowPrivateNetwork: true,
      ),
      httpClientFactory: world.newClient,
      allowPrivateNetwork: true,
    );
    final api = ControlPlaneApi(
      supervisor: supervisor,
      store: store,
      platform: platform,
      tokens: tokens,
      publicBaseUrl: 'http://127.0.0.1:0',
    );
    final panel = PanelApi(
      store: store,
      platform: platform,
      supervisor: supervisor,
      tokens: tokens,
      atproto: provider,
    );
    final bound = AtprotoRoomsListener(
      supervisor: supervisor,
      api: api,
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(const []),
      throttle: IpThrottle(maxPerWindow: 1000),
      atproto: provider,
      panel: panel,
    );
    await bound.start(port: 0, address: '127.0.0.1');
    provider.publicBaseUrl = 'http://127.0.0.1:${bound.port}';
    return _PgNode._(bound, supervisor, store, supabase, platform);
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
    await platform.close();
    await supabase.stop();
  }
}

/// The same node wired the SQLite way (the default) for mode contrast.
class _SqlitePanelNode {
  _SqlitePanelNode._(this.listener, this.supervisor, this.store);
  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');

  static Future<_SqlitePanelNode> start(FakeAtprotoWorld world) async {
    final store = NodeStore.open(':memory:')
      ..seedApiKeys({'default': apiKey});
    final platform = SqlitePlatformStore(store,
        adminDids: const ['did:plc:admin']);
    final tokens = JoinTokens('node-secret'.codeUnits);
    final supervisor = RoomSupervisor(
      factories: [
        RelayAuthorityFactory(
          creatorVerify: (roomKey, token) => tokens.verify(
            token,
            roomKey: roomKey,
            now: DateTime.now().toUtc(),
          ),
        ),
      ],
      maxRooms: 64,
    )..startTicker(hz: 60);
    final keys = await NodeClientKeys.generate();
    final provider = AtprotoAuthProvider(
      publicBaseUrl: 'http://127.0.0.1:0',
      keys: keys,
      tokens: tokens,
      identityResolver: NodeAtprotoResolver(
        entrywayUrl: world.origin,
        plcDirectoryUrl: world.origin,
        httpClient: world.newClient(),
        allowPrivateNetwork: true,
      ),
      httpClientFactory: world.newClient,
      allowPrivateNetwork: true,
    );
    final panel = PanelApi(
      store: store,
      platform: platform,
      supervisor: supervisor,
      tokens: tokens,
      atproto: provider,
    );
    final bound = AtprotoRoomsListener(
      supervisor: supervisor,
      api: ControlPlaneApi(
        supervisor: supervisor,
        store: store,
        platform: platform,
        tokens: tokens,
        publicBaseUrl: 'http://127.0.0.1:0',
      ),
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(const []),
      throttle: IpThrottle(maxPerWindow: 1000),
      atproto: provider,
      panel: panel,
    );
    await bound.start(port: 0, address: '127.0.0.1');
    provider.publicBaseUrl = 'http://127.0.0.1:${bound.port}';
    return _SqlitePanelNode._(bound, supervisor, store);
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
  }
}
