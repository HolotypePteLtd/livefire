import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'supabase_stub.dart';

/// A fake stock reference PDS speaking exactly the contract
/// [HttpGuestAccountHost] implements (live-confirmed shape):
/// - `POST /xrpc/com.atproto.server.createInviteCode` — basic auth
///   `admin:<adminPassword>` required, body `{"useCount":1}` → a
///   single-use `{"code": …}` (second use is refused);
/// - `POST /xrpc/com.atproto.server.createAccount` — requires
///   `{handle, password, inviteCode}`; a missing/used invite code gets
///   the production `InvalidInviteCode` answer; taken handles 409.
class FakePds {
  FakePds({this.adminPassword = 'pds-admin-pw'});

  /// The PDS admin password (what the node's `ident.serviceKey` must
  /// carry). Null disables the invite requirement (not stock).
  final String? adminPassword;
  final handles = <String>{};
  final didByHandle = <String, String>{};
  final calls = <Map<String, dynamic>>[];
  final inviteCalls = <Map<String, dynamic>>[];
  final inviteCodes = <String>{};
  int _next = 0;

  /// When set, the next created account reuses this DID (forces the
  /// one-recovery-key-per-DID conflict path).
  String? forceDid;

  HttpServer? _server;

  String get origin => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    final server = _server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  bool _adminAuthorized(HttpRequest request) {
    final header = request.headers.value('Authorization') ?? '';
    if (!header.startsWith('Basic ')) return false;
    final decoded = String.fromCharCodes(
        base64Decode(header.substring('Basic '.length)));
    return decoded == 'admin:$adminPassword';
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final path = request.uri.path;
    if (path == '/xrpc/com.atproto.server.createInviteCode') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      inviteCalls.add(Map<String, dynamic>.from(body));
      if (!_adminAuthorized(request)) {
        request.response.statusCode = 401;
        request.response.write(jsonEncode({'error': 'AuthenticationRequired'}));
        await request.response.close();
        return;
      }
      final code = 'invite-${inviteCodes.length}-${_unguessable(8)}';
      inviteCodes.add(code);
      request.response.statusCode = 200;
      request.response.write(jsonEncode({'code': code}));
      await request.response.close();
      return;
    }
    if (path != '/xrpc/com.atproto.server.createAccount') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    calls.add(Map<String, dynamic>.from(body));
    final invite = body['inviteCode'];
    if (adminPassword != null &&
        (invite is! String ||
            !inviteCodes.contains(invite) ||
            // Single-use, exactly like the reference PDS.
            !inviteCodes.remove(invite))) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({
        'error': 'InvalidInviteCode',
        'message': invite is! String
            ? 'No invite code provided'
            : 'Invite code is invalid',
      }));
      await request.response.close();
      return;
    }
    final handle = body['handle'] as String;
    if (handles.contains(handle)) {
      request.response.statusCode = 409;
      request.response.write(jsonEncode({
        'error': 'InvalidRequestError',
        'message': 'Handle already taken: $handle',
      }));
      await request.response.close();
      return;
    }
    handles.add(handle);
    final did = forceDid ?? 'did:plc:guest${_next++}';
    forceDid = null;
    didByHandle[handle] = did;
    request.response.statusCode = 200;
    request.response.write(jsonEncode({'did': did, 'handle': handle}));
    await request.response.close();
  }

  static String _unguessable(int length) {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt((random >> (i % 20)) % alphabet.length),
    ]);
  }
}

/// One node under test: real [RoomsListener] with the [GuestIdentityApi]
/// wired, in the requested persistence mode.
class IdentNode {
  IdentNode._(this.listener, this.platform, this.store, this.pds);

  final RoomsListener listener;
  final PlatformStore platform;
  final NodeStore store;
  final FakePds pds;

  Uri get base => Uri.parse('http://127.0.0.1:${listener.port}');

  static Future<IdentNode> start(
    FakePds pds, {
    required bool postgres,
    Duration? nonceTtl,
    DateTime Function()? clock,
    IpThrottle? throttle,
  }) async {
    final store = NodeStore.open(':memory:');
    final PlatformStore platform;
    if (postgres) {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      platform = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(supabase.stop);
    } else {
      platform = SqlitePlatformStore(store, adminDids: const [
        'did:plc:admin'
      ]);
    }
    final tokens = JoinTokens('ident-test-secret!!'.codeUnits);
    final supervisor = RoomSupervisor(factories: const [])
      ..startTicker(hz: 10);
    final ident = GuestIdentityApi(
      platform: platform,
      tokens: tokens,
      store: store,
      supervisor: supervisor,
      guests: HttpGuestAccountHost(
        pdsUrl: Uri.parse(pds.origin),
        serviceKey: pds.adminPassword,
      ),
      publicBaseUrl: 'http://127.0.0.1:9', // host = handle domain
      throttle: throttle ?? IpThrottle(maxPerWindow: 1000),
      nonceTtl: nonceTtl ?? const Duration(minutes: 5),
      sessionTtl: const Duration(days: 30),
      clock: clock ?? () => DateTime.now().toUtc(),
    );
    final listener = RoomsListener(
      supervisor: supervisor,
      api: _noControlPlane(supervisor, store, platform, tokens),
      store: store,
      tokens: tokens,
      tokenLedger: store,
      originGate: OriginGate(const []),
      throttle: throttle ?? IpThrottle(maxPerWindow: 1000),
      ident: ident,
    );
    await listener.start(port: 0, address: '127.0.0.1');
    return IdentNode._(listener, platform, store, pds);
  }

  static ControlPlaneApi _noControlPlane(
    RoomSupervisor supervisor,
    NodeStore store,
    PlatformStore platform,
    JoinTokens tokens,
  ) =>
      ControlPlaneApi(
        supervisor: supervisor,
        store: store,
        platform: platform,
        tokens: tokens,
        publicBaseUrl: 'http://127.0.0.1:9',
      );

  Future<void> stop() async {
    await listener.close();
    await listener.supervisor.close();
    store.close();
    await platform.close();
  }
}

Future<void> main() async {
  final client = http.Client();

  /// Creates a room row so `/ident` room binding has something real.
  String seedRoom(IdentNode node) {
    final room = StoredRoom(
      roomId: 'rm_test1',
      roomKey: 'rk_test1',
      template: 'relay',
      config: '{"version":1,"template":"relay"}',
      creatorToken: 'ct_x',
      status: 'live',
      createdAt: DateTime.now().toUtc(),
    );
    node.store.insertRoom(room);
    return room.roomKey;
  }

  /// A fresh client-held ES256 keypair (same shape the TS SDK makes).
  Future<(NodeClientKeys, Map<String, dynamic>)> freshKey() async {
    final keys = await NodeClientKeys.generate();
    final pub = keys.publicJwks()['keys'].first as Map<String, dynamic>;
    return (keys, pub);
  }

  /// The recovery assertion: ES256 JWS over {iss, sub, nonce, iat}.
  String assertionFor(NodeClientKeys keys, String did, String nonce,
      {int iatOffsetSeconds = 0}) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return keys.signJwt(
      {'alg': 'ES256', 'typ': 'JWT'},
      {
        'iss': did,
        'sub': did,
        'nonce': nonce,
        'iat': now + iatOffsetSeconds,
      },
    );
  }

  Future<Map<String, dynamic>> postJson(
    IdentNode node,
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await client.post(
      node.base.replace(path: path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return {
      'status': response.statusCode,
      'cors': response.headers['access-control-allow-origin'],
      'body': response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>,
    };
  }

  Future<Map<String, dynamic>> getJson(IdentNode node, String path) async {
    // The path may carry an encoded query (?did=...), so parse the
    // whole string instead of Uri.replace(path:), which would escape
    // the '?' into the path.
    final response = await client.get(Uri.parse('${node.base}$path'));
    return {
      'status': response.statusCode,
      'body': response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>,
    };
  }

  for (final mode in ['sqlite', 'postgres']) {
    group('guest identity ladder ($mode mode)', () {
      test('create -> recover -> same did; wrong key and replay rejected',
          () async {
        final pds = FakePds();
        await pds.start();
        addTearDown(pds.stop);
        final node = await IdentNode.start(pds, postgres: mode == 'postgres');
        addTearDown(node.stop);
        final roomKey = seedRoom(node);

        // ---- create -----------------------------------------------------
        final (keys, pubJwk) = await freshKey();
        final created = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': pubJwk,
          'room': roomKey,
        });
        expect(created['status'], 200, reason: jsonEncode(created));
        final createdBody = created['body'] as Map<String, dynamic>;
        final did = createdBody['did'] as String;
        expect(did, startsWith('did:'));
        expect(createdBody['handle'] as String,
            matches(RegExp(r'^anon-[a-z2-9]{6}\.127\.0\.0\.1$')));
        expect(createdBody['session'] as String, startsWith('gs_'));
        expect(createdBody['joinToken'] as String, startsWith('jt_'));
        expect(createdBody['roomKey'], roomKey);
        expect(
          createdBody['url'] as String,
          contains('/play/$roomKey?token=jt_'),
        );
        expect(createdBody.containsKey('panelSession'), isFalse);

        // The join token carries the DID (identity binding in the hub).
        final check = node.listener.tokens.verify(
          createdBody['joinToken'] as String,
          roomKey: roomKey,
          now: DateTime.now().toUtc(),
        );
        expect(check.ok, isTrue);
        expect(check.payload!.did, did);

        // The recovery key is stored, flagged guest, hash canonical.
        final stored = await node.platform.recoveryKeyFor(did);
        expect(stored, isNotNull);
        expect(stored!.guest, isTrue);
        expect(stored.pubkeyHash, RecoveryKeyMaterial.hash(pubJwk));
        expect(stored.pubkeyJwk['x'], pubJwk['x']);

        // The PDS saw exactly the handle it assigned (JSON body).
        expect(pds.calls.single['handle'], createdBody['handle']);

        // The session verifies as a gs_ token.
        final sessionCheck = node.listener.tokens.verifyGuestSession(
          createdBody['session'] as String,
          now: DateTime.now().toUtc(),
        );
        expect(sessionCheck.ok, isTrue);
        expect(sessionCheck.session!.did, did);
        expect(sessionCheck.session!.guest, isTrue);

        // ---- recover: proof of key -> same did ---------------------------
        final nonce = await getJson(
            node, '/ident/nonce?did=${Uri.encodeComponent(did)}');
        expect(nonce['status'], 200);
        final nonceBody = nonce['body'] as Map<String, dynamic>;
        expect(nonceBody['nonce'], isA<String>());
        expect(nonceBody['expiresInMs'], greaterThan(0));

        final recovered = await postJson(node, '/ident/recover', {
          'did': did,
          'nonce': nonceBody['nonce'],
          'assertion': assertionFor(keys, did, nonceBody['nonce'] as String),
          'room': roomKey,
        });
        expect(recovered['status'], 200, reason: jsonEncode(recovered));
        final recoveredBody = recovered['body'] as Map<String, dynamic>;
        expect(recoveredBody['did'], did);
        expect(recoveredBody['session'], startsWith('gs_'));
        expect(recoveredBody['joinToken'], startsWith('jt_'));
        expect(recoveredBody['url'], contains('/play/$roomKey?token=jt_'));

        // ---- wrong key: signature does not verify ------------------------
        final (otherKeys, _) = await freshKey();
        final nonce2 = (await getJson(
                node, '/ident/nonce?did=${Uri.encodeComponent(did)}'))
            ['body'] as Map<String, dynamic>;
        final wrongKey = await postJson(node, '/ident/recover', {
          'did': did,
          'nonce': nonce2['nonce'],
          'assertion':
              assertionFor(otherKeys, did, nonce2['nonce'] as String),
        });
        expect(wrongKey['status'], 403);
        expect(
          (wrongKey['body'] as Map)['error']['code'],
          'bad_assertion',
        );

        // ---- nonce replay: single-use, even after a successful use -------
        final replay = await postJson(node, '/ident/recover', {
          'did': did,
          'nonce': nonceBody['nonce'],
          'assertion': assertionFor(keys, did, nonceBody['nonce'] as String),
        });
        expect(replay['status'], 403);
        expect(
          (replay['body'] as Map)['error']['code'],
          anyOf('invalid_nonce', 'bad_assertion'),
        );

        // A fresh nonce + the right key still works (not locked out).
        final nonce3 = (await getJson(
                node, '/ident/nonce?did=${Uri.encodeComponent(did)}'))
            ['body'] as Map<String, dynamic>;
        final again = await postJson(node, '/ident/recover', {
          'did': did,
          'nonce': nonce3['nonce'],
          'assertion': assertionFor(keys, did, nonce3['nonce'] as String),
        });
        expect(again['status'], 200);
      });

      test('unknown did, malformed jwk, bogus room, preflight, admin ps_',
          () async {
        final pds = FakePds();
        await pds.start();
        addTearDown(pds.stop);
        final node = await IdentNode.start(pds, postgres: mode == 'postgres');
        addTearDown(node.stop);

        // CORS preflight (browser games POST JSON cross-origin).
        final pre = await http.Client().send(http.Request(
          'OPTIONS',
          node.base.replace(path: '/ident/device-account'),
        ) as http.BaseRequest);
        expect(pre.statusCode, 204);
        expect(pre.headers['access-control-allow-origin'], '*');

        // Malformed rotationPubJwk.
        final badJwk = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': {'kty': 'EC', 'crv': 'P-256', 'x': 'AAAA'},
        });
        expect(badJwk['status'], 400);
        expect((badJwk['body'] as Map)['error']['code'], 'invalid_request');

        // Custom handle outside the domain.
        final badHandle = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': (await freshKey()).$2,
          'handle': 'evil.example.com',
        });
        expect(badHandle['status'], 400);

        // Unknown room.
        final badRoom = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': (await freshKey()).$2,
          'room': 'rk_nope',
        });
        expect(badRoom['status'], 404);

        // Recover for an unknown did.
        final unknown = await postJson(node, '/ident/recover', {
          'did': 'did:plc:never',
          'nonce': 'n',
          'assertion': 'a.b.c',
        });
        expect(unknown['status'], 404);

        // Admin DID: recovery ALSO yields a ps_ panel session. The fake
        // PDS is forced to hand the admin's did back for the next create.
        pds.forceDid = 'did:plc:admin';
        final (keys, pubJwk) = await freshKey();
        final created = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': pubJwk,
        });
        expect(created['status'], 200, reason: jsonEncode(created));
        expect(
          (created['body'] as Map)['panelSession'],
          startsWith('ps_'),
        );

        // Duplicate DID (PDS reuses a did): one recovery key per DID.
        pds.forceDid = 'did:plc:admin';
        final dup = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': (await freshKey()).$2,
        });
        expect(dup['status'], 409);
        expect((dup['body'] as Map)['error']['code'], 'already_registered');
      });

      test('expired nonce is refused; throttle caps the surface',
          () async {
        var now = DateTime.now().toUtc();
        final pds = FakePds();
        await pds.start();
        addTearDown(pds.stop);
        final node = await IdentNode.start(
          pds,
          postgres: mode == 'postgres',
          nonceTtl: const Duration(minutes: 5),
          clock: () => now,
          throttle: IpThrottle(maxPerWindow: 5),
        );
        addTearDown(node.stop);

        final (keys, pubJwk) = await freshKey();
        final created = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': pubJwk,
        });
        final did = (created['body'] as Map)['did'] as String;

        final nonce = ((await getJson(
                node, '/ident/nonce?did=${Uri.encodeComponent(did)}'))
            ['body'] as Map)['nonce'] as String;

        // Clock moves past the TTL: the nonce is dead.
        now = now.add(const Duration(minutes: 6));
        final expired = await postJson(node, '/ident/recover', {
          'did': did,
          'nonce': nonce,
          'assertion': assertionFor(keys, did, nonce),
        });
        expect(expired['status'], 403);
        expect((expired['body'] as Map)['error']['code'], 'invalid_nonce');

        // And an iat outside the window fails even with a live nonce
        // (clock back inside the TTL).
        now = now.subtract(const Duration(minutes: 4));
        final nonce2 = ((await getJson(
                node, '/ident/nonce?did=${Uri.encodeComponent(did)}'))
            ['body'] as Map)['nonce'] as String;
        final stale = await postJson(node, '/ident/recover', {
          'did': did,
          'nonce': nonce2,
          'assertion': assertionFor(keys, did, nonce2,
              iatOffsetSeconds: 3600),
        });
        expect(stale['status'], 403);

        // The shared per-IP throttle caps the whole /ident surface.
        final burst = await getJson(node, '/ident/nonce?did=did:plc:x');
        expect(burst['status'], 429);
        expect((burst['body'] as Map)['error']['code'], 'quota_exceeded');
      });

      test('fixture: admin invite mint + createAccount(handle, password, '
          'inviteCode); password returned and persisted', () async {
        final pds = FakePds(adminPassword: 's3cret-admin-pw');
        await pds.start();
        addTearDown(pds.stop);
        final node = await IdentNode.start(
          pds,
          postgres: mode == 'postgres',
        );
        addTearDown(node.stop);

        // ---- the flow completes against the stock-PDS contract --------
        final (keys, pubJwk) = await freshKey();
        final created = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': pubJwk,
        });
        expect(created['status'], 200, reason: jsonEncode(created));
        final body = created['body'] as Map<String, dynamic>;
        final did = body['did'] as String;

        // ---- exactly what went over the wire ---------------------------
        // 1. One invite mint, basic auth admin:<adminPassword>, useCount 1.
        expect(pds.inviteCalls, hasLength(1));
        expect(pds.inviteCalls.single['useCount'], 1);
        // 2. createAccount carried handle + generated password + code.
        expect(pds.calls, hasLength(1));
        final createBody = pds.calls.single;
        expect(createBody['handle'], body['handle']);
        final password = createBody['password'] as String;
        expect(password.length, greaterThanOrEqualTo(24));
        expect(password, isNot(contains(RegExp(r'[0O1Il]'))));
        expect(createBody['inviteCode'], isA<String>());
        expect(createBody.containsKey('email'), isFalse,
            reason: 'no email on the guest path');
        // The invite code was single-use (consumed by this create).
        expect(pds.inviteCodes, isEmpty);

        // ---- the credential is persisted in the platform store ---------
        final stored = await node.platform.guestCredentialFor(did);
        expect(stored, isNotNull);
        expect(stored!.did, did);
        expect(stored.handle, body['handle']);
        expect(stored.password, password);
        expect(stored.createdAt, isA<DateTime>());
      });

      test('no admin password / wrong password -> 502, nothing persisted',
          () async {
        final pds = FakePds(adminPassword: 'real-pw');
        await pds.start();
        addTearDown(pds.stop);

        // No serviceKey: the host refuses before any HTTP (clear error).
        final host = HttpGuestAccountHost(pdsUrl: Uri.parse(pds.origin));
        await expectLater(
          () => host.createAccount('anon-x.127.0.0.1'),
          throwsA(isA<GuestAccountException>().having(
              (e) => e.message, 'message', contains('admin password'))),
        );

        // Wrong password: the PDS refuses the invite mint (401) -> the
        // node reports account_host_unavailable and stores nothing.
        final wrong = HttpGuestAccountHost(
          pdsUrl: Uri.parse(pds.origin),
          serviceKey: 'wrong-pw',
        );
        await expectLater(
          () => wrong.createAccount('anon-x.127.0.0.1'),
          throwsA(isA<GuestAccountException>().having(
              (e) => e.message, 'message', contains('createInviteCode'))),
        );
        expect(pds.calls, isEmpty);
        await wrong.close();
        await host.close();
      });

      test('PDS outage surfaces as 502; conflicts retry with fresh handles',
          () async {
        final pds = FakePds();
        await pds.start();
        addTearDown(pds.stop);
        // Pre-take the first auto handle the node would generate by
        // forcing collisions: pre-seed via the PDS's own create path is
        // not possible (random suffix), so instead verify the retry
        // path directly with a host that always conflicts twice.
        final flaky = _FlakyHost();
        final store = NodeStore.open(':memory:');
        final platform =
            SqlitePlatformStore(store, adminDids: const []);
        final tokens = JoinTokens('flaky-secret-123456'.codeUnits);
        final supervisor = RoomSupervisor(factories: const []);
        final ident = GuestIdentityApi(
          platform: platform,
          tokens: tokens,
          store: store,
          supervisor: supervisor,
          guests: flaky,
          publicBaseUrl: 'http://127.0.0.1:9',
          throttle: IpThrottle(maxPerWindow: 1000),
        );
        final listener = RoomsListener(
          supervisor: supervisor,
          api: IdentNode._noControlPlane(
              supervisor, store, platform, tokens),
          store: store,
          tokens: tokens,
          tokenLedger: store,
          originGate: OriginGate(const []),
          throttle: IpThrottle(maxPerWindow: 1000),
          ident: ident,
        );
        await listener.start(port: 0, address: '127.0.0.1');
        addTearDown(() async {
          await listener.close();
          await supervisor.close();
          store.close();
          await platform.close();
        });

        final node = IdentNode._(listener, platform, store, FakePds());

        // Two conflicts, then success: 3 handle attempts in total.
        final ok = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': (await freshKey()).$2,
        });
        expect(ok['status'], 200, reason: jsonEncode(ok));
        expect(flaky.attempts, 3);

        // Hard failure (not a conflict): 502, nothing stored.
        flaky.fail = true;
        final down = await postJson(node, '/ident/device-account', {
          'rotationPubJwk': (await freshKey()).$2,
        });
        expect(down['status'], 502);
        expect(
          (down['body'] as Map)['error']['code'],
          'account_host_unavailable',
        );
      });
    });
  }
}

/// A [GuestAccountHost] that conflicts twice then succeeds, or fails
/// hard on demand.
class _FlakyHost implements GuestAccountHost {
  int attempts = 0;
  bool fail = false;

  @override
  Future<GuestAccount> createAccount(String handle) async {
    attempts++;
    if (fail) {
      throw const GuestAccountException('pds is down', conflict: false);
    }
    if (attempts <= 2) {
      throw const GuestAccountException('handle taken', conflict: true);
    }
    return GuestAccount(did: 'did:plc:flaky$attempts', handle: handle);
  }
}
