import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:livefire_atproto_server/livefire_atproto_server.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'atproto_world.dart';

const apiKey = 'sk_test_node';

/// A whole node with the panel wired: supervisor + listener + control
/// plane + atproto provider + PanelApi, bound to an ephemeral port, over
/// an in-memory store.
class PanelNode {
  PanelNode._(this.listener, this.supervisor, this.store, this.tokens,
      this.provider, this.panel);

  final RoomsListener listener;
  final RoomSupervisor supervisor;
  final NodeStore store;
  final JoinTokens tokens;
  final AtprotoAuthProvider provider;
  final PanelApi panel;

  late final Uri base = Uri.parse('http://127.0.0.1:${listener.port}');

  static Future<PanelNode> start(
    FakeAtprotoWorld world, {
    List<String> adminDids = const ['did:plc:admin'],
  }) async {
    final store = NodeStore.open(':memory:')
      ..seedApiKeys({'default': apiKey});
    final platform = SqlitePlatformStore(store, adminDids: adminDids);
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
    return PanelNode._(
      bound,
      supervisor,
      store,
      tokens,
      provider,
      panel,
    );
  }

  Future<void> stop() async {
    await listener.close();
    await supervisor.close();
    store.close();
  }
}

Future<void> main() async {
  final world = FakeAtprotoWorld();
  setUpAll(() async {
    await world.start();
    world.addIdentity('admin.bsky.social', 'did:plc:admin');
    world.addIdentity('rando.bsky.social', 'did:plc:rando');
  });
  tearDownAll(() => world.stop());

  final client = http.Client();

  // Each PanelNode generates fresh OAuth client keys; the fake AS caches
  // the client metadata it saw on the first PAR, so rediscover per test.
  setUp(() {
    world.clientMetadata = null;
    world.clientJwks = null;
  });

  /// Full panel sign-in: start → browser follows the authorization URL →
  /// poll result → the `ps_` session token.
  Future<String> signIn(PanelNode node, String handle) async {
    final start = await client.get(node.base.replace(
      path: '/panel/api/auth/start',
      queryParameters: {'handle': handle},
    ));
    expect(start.statusCode, 200, reason: start.body);
    final startBody = jsonDecode(start.body) as Map<String, dynamic>;
    expect(startBody['authorizationUrl'], isA<String>());
    final browser =
        await world.client.get(Uri.parse(startBody['authorizationUrl'] as String));
    expect(browser.statusCode, 200, reason: browser.body);
    for (var i = 0; i < 100; i++) {
      final result = await client.get(node.base.replace(
        path: '/panel/api/auth/result',
        queryParameters: {'flow': startBody['flow'] as String},
      ));
      final body = jsonDecode(result.body) as Map<String, dynamic>;
      if (body['status'] == 'pending') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      expect(body['status'], 'ok', reason: result.body);
      expect(body['did'], isA<String>());
      expect(body['session'] as String, startsWith('ps_'));
      return body['session'] as String;
    }
    fail('panel sign-in never completed');
  }

  Future<http.Response> panelGet(
          PanelNode node, String path, String session) =>
      client.get(node.base.replace(path: path), headers: {
        'Authorization': 'Bearer $session',
      });

  test('the panel page, script and stylesheet are served with a strict CSP',
      () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);

    final page = await client.get(node.base.replace(path: '/panel'));
    expect(page.statusCode, 200);
    expect(page.headers['content-security-policy'],
        contains("script-src 'self'"));
    expect(page.body, contains('/panel/app.js'));
    expect(page.body, isNot(contains('<script>'))); // no inline script

    final js = await client.get(node.base.replace(path: '/panel/app.js'));
    expect(js.statusCode, 200);
    expect(js.headers['content-type'], startsWith('text/javascript'));
    expect(js.body, contains('/panel/api/keys'));
    final css = await client.get(node.base.replace(path: '/panel/panel.css'));
    expect(css.statusCode, 200);
    expect(css.headers['content-type'], startsWith('text/css'));
  });

  test('panel routes are 404 when no panel is wired', () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);
    // The page is always served; the API needs a session. Unauthenticated:
    final response = await client
        .get(node.base.replace(path: '/panel/api/session'));
    expect(response.statusCode, 401);
    // Unknown panel route:
    final unknown = await client
        .get(node.base.replace(path: '/panel/api/nope'));
    expect(unknown.statusCode, 404);
  });

  test('admin DID signs in, manages keys, counters increment', () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);

    // Sign-in over the real (fake-world) OAuth flow.
    final session = await signIn(node, 'admin.bsky.social');

    final me = await panelGet(node, '/panel/api/session', session);
    expect(me.statusCode, 200);
    expect(jsonDecode(me.body), {
      'did': 'did:plc:admin',
      'handle': 'admin.bsky.social',
      'admin': true,
      // SQLite mode: no admin management (config-owned) — surfaced so
      // the panel UI hides those sections.
      'mode': 'sqlite',
      'canManageAdmins': false,
    });

    // Bootstrap key is listed read-only, with its badge and prefix only.
    final listed = await panelGet(node, '/panel/api/keys', session);
    expect(listed.statusCode, 200);
    final keys = (jsonDecode(listed.body)['keys'] as List)
        .cast<Map<String, dynamic>>();
    expect(keys.length, 1);
    expect(keys.first['bootstrap'], true);
    expect(keys.first['label'], 'default');
    expect(keys.first['keyPrefix'], isNot(contains(apiKey)));

    // Create a key: full plaintext exactly once.
    final created = await client.post(
      node.base.replace(path: '/panel/api/keys'),
      headers: {'Authorization': 'Bearer $session'},
      body: jsonEncode({'label': 'my game'}),
    );
    expect(created.statusCode, 201, reason: created.body);
    final createdBody = jsonDecode(created.body) as Map<String, dynamic>;
    final fullKey = createdBody['key'] as String;
    expect(fullKey, startsWith('sk_'));
    expect(createdBody['label'], 'my game');
    expect(createdBody['createdByDid'], 'did:plc:admin');

    // The new key works on the control plane…
    final room = await client.post(
      node.base.replace(path: '/v1/rooms'),
      headers: {'Authorization': 'Bearer $fullKey'},
      body: jsonEncode({
        'template': 'relay',
        'config': {
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
        },
      }),
    );
    expect(room.statusCode, 201, reason: room.body);
    final roomId =
        (jsonDecode(room.body) as Map<String, dynamic>)['roomId'] as String;

    final minted = await client.post(
      node.base.replace(path: '/v1/rooms/$roomId/tokens'),
      headers: {'Authorization': 'Bearer $fullKey'},
    );
    expect(minted.statusCode, 201);

    // …and the counters moved. The list never carries the plaintext.
    final after = await panelGet(node, '/panel/api/keys', session);
    final rows = (jsonDecode(after.body)['keys'] as List)
        .cast<Map<String, dynamic>>();
    final mine = rows.firstWhere((k) => k['bootstrap'] != true);
    expect(mine['roomsCreated'], 1);
    expect(mine['tokensMinted'], 1);
    expect(jsonEncode(rows), isNot(contains(fullKey)));
    expect(mine['keyPrefix'], fullKey.substring(0, 8));

    // Rooms list (read-only): the room is there with template + status.
    final rooms = await panelGet(node, '/panel/api/rooms', session);
    expect(rooms.statusCode, 200);
    final roomRows = (jsonDecode(rooms.body)['rooms'] as List)
        .cast<Map<String, dynamic>>();
    expect(roomRows.any((r) =>
        r['roomId'] == roomId &&
        r['template'] == 'relay' &&
        r['status'] == 'live' &&
        r.containsKey('peers') &&
        r.containsKey('ageSeconds')), isTrue);

    // Revoke: the key dies on the control plane; bootstrap cannot.
    final revoked = await client.post(
      node.base.replace(path: '/panel/api/keys/${mine['id']}/revoke'),
      headers: {'Authorization': 'Bearer $session'},
    );
    expect(revoked.statusCode, 200);
    final deadKey = await client.post(
      node.base.replace(path: '/v1/rooms'),
      headers: {'Authorization': 'Bearer $fullKey'},
      body: jsonEncode({'template': 'relay', 'config': {}}),
    );
    expect(deadKey.statusCode, 401);

    final bootId = keys.first['id'] as String;
    final bootRevoke = await client.post(
      node.base.replace(path: '/panel/api/keys/$bootId/revoke'),
      headers: {'Authorization': 'Bearer $session'},
    );
    expect(bootRevoke.statusCode, 403);
    expect(jsonDecode(bootRevoke.body)['error']['code'], 'forbidden');
  });

  test('unknown DIDs are signed in but forbidden; keys never authenticate',
      () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);

    final session = await signIn(node, 'rando.bsky.social');
    final me = await panelGet(node, '/panel/api/session', session);
    expect(me.statusCode, 403);
    expect(jsonDecode(me.body)['error']['code'], 'forbidden');
    final keys = await panelGet(node, '/panel/api/keys', session);
    expect(keys.statusCode, 403);

    // An API key is not a panel credential, ever.
    final withKey = await client.get(node.base.replace(path: '/panel/api/keys'),
        headers: {'Authorization': 'Bearer $apiKey'});
    expect(withKey.statusCode, 401);
    // Nor is nothing at all.
    final anon = await client.get(node.base.replace(path: '/panel/api/keys'));
    expect(anon.statusCode, 401);
  });

  test('a failed panel sign-in surfaces its reason, not a generic 400',
      () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);

    // Start a panel sign-in (PAR against the fake AS succeeds).
    final start = await client.get(node.base.replace(
      path: '/panel/api/auth/start',
      queryParameters: {'handle': 'admin.bsky.social'},
    ));
    expect(start.statusCode, 200, reason: start.body);
    final startBody = jsonDecode(start.body) as Map<String, dynamic>;

    // The browser follows the authorization URL, but we intercept the
    // AS's redirect and tamper the code — the token exchange fails and
    // the flow ends in a terminal error.
    final httpClient = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => host == '127.0.0.1';
    final authorizeRequest = await httpClient
        .getUrl(Uri.parse(startBody['authorizationUrl'] as String));
    authorizeRequest.followRedirects = false;
    final authorizeResponse = await authorizeRequest.close();
    expect(authorizeResponse.statusCode, 302);
    final location = authorizeResponse.headers.value(HttpHeaders.locationHeader)!;
    expect(location, contains('iss='));
    final tampered = Uri.parse(location).replace(queryParameters: {
      ...Uri.parse(location).queryParameters,
      'code': 'code_tampered',
    });
    final callback = await client.get(tampered);
    expect(callback.statusCode, 400); // the generic browser page

    // /auth/result reports the terminal failure as 410 with the REAL
    // reason — this body is what the panel's sign-in handler shows.
    final result = await client.get(node.base.replace(
      path: '/panel/api/auth/result',
      queryParameters: {'flow': startBody['flow'] as String},
    ));
    expect(result.statusCode, 410);
    final body = jsonDecode(result.body) as Map<String, dynamic>;
    expect(body['status'], 'error');
    expect(body['error']['message'], contains('invalid_grant'));
  });

  test('/panel/api/auth/result: pending 202 → complete 200 → session '
      '(410 terminal covered above)', () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);

    final start = await client.get(node.base.replace(
      path: '/panel/api/auth/start',
      queryParameters: {'handle': 'admin.bsky.social'},
    ));
    expect(start.statusCode, 200, reason: start.body);
    final startBody = jsonDecode(start.body) as Map<String, dynamic>;

    Future<Map<String, dynamic>> poll() async {
      final response = await client.get(node.base.replace(
        path: '/panel/api/auth/result',
        queryParameters: {'flow': startBody['flow'] as String},
      ));
      return {
        'code': response.statusCode,
        'body': jsonDecode(response.body) as Map<String, dynamic>,
      };
    }

    // Before the browser touches the AS the flow is pending: 202.
    var result = await poll();
    expect(result['code'], 202);
    expect((result['body'] as Map)['status'], 'pending');

    // The browser completes the authorization → the flow resolves to
    // 200 with the ps_ session the panel JS stores.
    await world.client
        .get(Uri.parse(startBody['authorizationUrl'] as String));
    for (var i = 0; i < 100; i++) {
      result = await poll();
      if (result['code'] != 202) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(result['code'], 200);
    final body = result['body'] as Map<String, dynamic>;
    expect(body['status'], 'ok');
    expect(body['session'] as String, startsWith('ps_'));
  });

  test('the served poll loop never consults popup.closed; pollAction '
      '(run under node) cannot fail a pending flow', () async {
    final node = await PanelNode.start(world);
    addTearDown(node.stop);
    final js = await client.get(node.base.replace(path: '/panel/app.js'));
    expect(js.statusCode, 200);
    final source = js.body;

    // The poll decision must be driven by the server's flow state only.
    // popup.closed on a cross-origin popup reads true while the window
    // is provably open (verified via CDP) — it must not appear at all.
    expect(source.contains('popup.closed'), isFalse,
        reason: 'app.js must not read popup.closed');
    // The waiting hint + Cancel button wiring the brief requires.
    expect(source, contains('signin-cancel'));
    expect(source, contains('expiresInMs'));

    // Run the EXACT served pollAction under node: truth table it,
    // including the regression — a pending flow stays pending no
    // matter what the popup might claim.
    final helper =
        RegExp(r'function pollAction[\s\S]*?\n}').firstMatch(source);
    expect(helper, isNotNull, reason: 'pollAction missing from app.js');
    final harness = '''
const assert = require('assert');
${helper!.group(0)}
assert.equal(pollAction(200, 0, 600000), 'complete');
assert.equal(pollAction(410, 0, 600000), 'terminal');
assert.equal(pollAction(202, 0, 600000), 'keep');
assert.equal(pollAction(202, 599999, 600000), 'keep');
assert.equal(pollAction(202, 600000, 600000), 'timeout');
assert.equal(pollAction(202, 600001, 600000), 'timeout');
// Silence / server error / any other status: never a failure outcome —
// keep polling until the flow TTL lapses, then time out explicitly.
assert.equal(pollAction(0, 0, 600000), 'keep');
assert.equal(pollAction(0, 600000, 600000), 'timeout');
assert.equal(pollAction(500, 1, 600000), 'keep');
assert.equal(pollAction(500, 600000, 600000), 'timeout');
// popupClosed is not even a parameter: nothing a popup reports can
// produce 'complete'/'terminal'/failure while the server says pending.
assert.equal(pollAction.length, 3);
console.log('pollAction truth table ok');
''';
    final dir = await Directory.systemTemp.createTemp('openfire-pollaction');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/poll_action_test.js');
    await file.writeAsString(harness);
    final run = await Process.run('node', [file.path]);
    expect(run.exitCode, 0,
        reason: '\${run.stdout}\${run.stderr}');
    expect(run.stdout, contains('truth table ok'));
  });

  test('empty adminDids: panel present but disabled', () async {
    final node = await PanelNode.start(world, adminDids: const []);
    addTearDown(node.stop);

    final page = await client.get(node.base.replace(path: '/panel'));
    expect(page.statusCode, 200); // the page itself loads, says disabled
    final session = await client
        .get(node.base.replace(path: '/panel/api/session'));
    expect(session.statusCode, 503);
    expect(jsonDecode(session.body)['error']['code'], 'panel_disabled');
    final start = await client.get(node.base.replace(
      path: '/panel/api/auth/start',
      queryParameters: {'handle': 'admin.bsky.social'},
    ));
    expect(start.statusCode, 503);
  });
}
