import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:atproto_oauth/atproto_oauth.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart';
import 'package:livefire_atproto_server/livefire_atproto_server.dart';
import 'package:server_sdk/server_sdk.dart' show JoinTokens;
import 'package:test/test.dart';

/// An in-test record server (PDS shape): real TLS on 127.0.0.1, serving
/// exactly the two endpoints [MatchEventPublisher] calls.
///
/// Real-world differences, kept honest (same list as the auth fake):
/// - No DPoP proof verification: the DPoP and Authorization headers must
///   be present, and the proof is decoded to check its shape, but the
///   signature itself is not checked.
/// - `use_dpop_nonce` behavior is simulated only when armed, to exercise
///   the client's retry path.
class FakeRecordServer {
  final created = <Map<String, dynamic>>[]; // request bodies
  final deleted = <Map<String, dynamic>>[]; // request bodies
  final problems = <String>[];
  String? demandNonceOnce;
  HttpServer? _server;
  Directory? _certDir;

  String get origin => 'https://127.0.0.1:${_server!.port}';

  http.Client trustedClient() => io_client.IOClient(
        HttpClient()
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) =>
                  host == '127.0.0.1',
      );

  Future<void> start() async {
    final certDir = _certDir =
        await Directory.systemTemp.createTemp('fake-record-server-');
    final cert = '${certDir.path}/cert.pem';
    final key = '${certDir.path}/key.pem';
    final generated = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
      '-keyout', key, '-out', cert, '-days', '2', '-nodes',
      '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
    ]);
    if (generated.exitCode != 0) {
      throw StateError('openssl failed: ${generated.stderr}');
    }
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    final server = _server = await HttpServer.bindSecure(
      '127.0.0.1',
      0,
      context,
    );
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _certDir?.delete(recursive: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final body = await utf8.decoder.bind(request).join();
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    final dpop = request.headers.value('DPoP');
    if (auth == null || !auth.startsWith('DPoP ')) {
      problems.add('${request.uri.path}: missing DPoP authorization');
    }
    if (dpop == null || dpop.split('.').length != 3) {
      problems.add('${request.uri.path}: missing or malformed DPoP proof');
    }
    if (demandNonceOnce != null) {
      final nonce = demandNonceOnce!;
      demandNonceOnce = null;
      request.response.headers.set('DPoP-Nonce', nonce);
      await _json(request, 401, {'error': 'use_dpop_nonce'});
      return;
    }
    if (path == '/xrpc/com.atproto.repo.createRecord' &&
        request.method == 'POST') {
      final json = jsonDecode(body) as Map<String, dynamic>;
      created.add(json);
      final rkey = json['rkey'] as String;
      await _json(request, 200, {
        'uri':
            'at://${json['repo']}/${json['collection']}/$rkey',
        'cid': 'cid_${created.length}',
      });
      return;
    }
    if (path == '/xrpc/com.atproto.repo.deleteRecord' &&
        request.method == 'POST') {
      final json = jsonDecode(body) as Map<String, dynamic>;
      deleted.add(json);
      final rkey = json['rkey'] as String;
      final known = created.any((c) => c['rkey'] == rkey);
      if (known) {
        await _json(request, 200, {});
      } else {
        await _json(request, 404, {
          'error': 'RecordNotFound',
          'message': 'Record could not be found',
        });
      }
      return;
    }
    await _json(request, 404, {'error': 'NotFound'});
  }

  static Future<void> _json(HttpRequest request, int status, Object body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

/// Real EC P-256 material in the library's own encoding (base64Url of
/// x||y for the public key, of d for the private key) — getDPoPHeader
/// decodes both, so placeholder strings would not survive.
DPoPKeyPair _dpopKeys() {
  final seed = Uint8List(32);
  final random = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = random.nextInt(256);
  }
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(
      ECKeyGeneratorParameters(ECCurve_secp256r1()),
      FortunaRandom()..seed(KeyParameter(seed)),
    ));
  final pair = generator.generateKeyPair();
  final point = pair.publicKey.Q!;
  Uint8List bytes(BigInt value) {
    var hexValue = value.toRadixString(16);
    if (hexValue.length.isOdd) hexValue = '0$hexValue';
    final out = Uint8List(hexValue.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hexValue.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  final x = bytes(point.x!.toBigInteger()!);
  final y = bytes(point.y!.toBigInteger()!);
  return DPoPKeyPair(
    publicKey: base64Url.encode(Uint8List.fromList([...x, ...y])),
    privateKey: base64Url.encode(bytes(pair.privateKey.d!)),
  );
}

OAuthSession _session(String origin, {String scope = 'atproto repo'}) {
  final keys = _dpopKeys();
  return OAuthSession(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    scope: scope,
    sub: 'did:plc:player1',
    issuer: origin,
    pds: origin,
    clientId: 'https://rooms.example.com/oauth/client.json',
    dpopPublicKey: keys.publicKey,
    dpopPrivateKey: keys.privateKey,
  );
}

void main() {
  late FakeRecordServer pds;

  setUp(() async {
    pds = FakeRecordServer();
    await pds.start();
  });

  tearDown(() async {
    await pds.stop();
  });

  MatchEventPublisher publisher(MatchEventSettings settings) {
    final publisher = MatchEventPublisher(
      settings: settings,
      httpClientFactory: pds.trustedClient,
      clock: () => DateTime.utc(2026, 2, 3, 12),
    );
    addTearDown(publisher.close);
    return publisher;
  }

  test('writes the record with the agreed type and fields when consented',
      () async {
    final matchEvent = publisher(const MatchEventSettings(
      enabled: true,
      gameId: 'com.example.golf',
    ));
    final record = await matchEvent.publishMatchEvent(
      session: _session(pds.origin),
      eventType: 'matchResult',
      matchId: 'match-1',
      playerId: 'p1',
      payload: {
        'score': 42,
        'place': 1,
        'replayUrl': 'https://cdn.example.com/r/match-1',
      },
      playerConsented: true,
    );

    expect(record, isNotNull);
    expect(pds.created, hasLength(1));
    final write = pds.created.single;
    expect(write['repo'], 'did:plc:player1');
    expect(write['collection'], 'com.openfire.matchEvent');
    expect(write['rkey'], record!.rkey);
    final event = write['record'] as Map<String, dynamic>;
    expect(event[r'$type'], 'com.openfire.matchEvent');
    expect(event['eventType'], 'matchResult');
    expect(event['matchId'], 'match-1');
    expect(event['gameId'], 'com.example.golf');
    expect(event['playerId'], 'p1');
    expect(event['payload']['score'], 42);
    expect(event['timestamp'], '2026-02-03T12:00:00.000Z');
    expect(record.uri, startsWith('at://did:plc:player1/com.openfire.'));
    expect(pds.problems, isEmpty);
  });

  test('no write when the player did not consent', () async {
    final matchEvent = publisher(
      const MatchEventSettings(enabled: true, gameId: 'com.example.golf'),
    );
    final record = await matchEvent.publishMatchEvent(
      session: _session(pds.origin),
      eventType: 'matchResult',
      matchId: 'match-1',
      playerId: 'p1',
      playerConsented: false,
    );
    expect(record, isNull);
    expect(pds.created, isEmpty);
  });

  test('no write when publishEvents is disabled (ships off)', () async {
    final matchEvent = publisher(const MatchEventSettings());
    final record = await matchEvent.publishMatchEvent(
      session: _session(pds.origin),
      eventType: 'matchResult',
      matchId: 'match-1',
      playerId: 'p1',
      playerConsented: true, // even with consent: the node gate rules
    );
    expect(record, isNull);
    expect(pds.created, isEmpty);
  });

  test('a read-only session is never enough, whatever the config says',
      () async {
    final matchEvent = publisher(
      const MatchEventSettings(enabled: true, gameId: 'com.example.golf'),
    );
    await expectLater(
      matchEvent.publishMatchEvent(
        session: _session(pds.origin, scope: 'atproto'),
        eventType: 'matchResult',
        matchId: 'match-1',
        playerId: 'p1',
        playerConsented: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(pds.created, isEmpty);
  });

  test('summaryOnly rejects individual achievements until opted out',
      () async {
    final matchEvent = publisher(const MatchEventSettings(
      enabled: true,
      gameId: 'com.example.golf',
    ));
    await expectLater(
      matchEvent.publishMatchEvent(
        session: _session(pds.origin),
        eventType: 'achievement',
        matchId: 'match-1',
        playerId: 'p1',
        playerConsented: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(pds.created, isEmpty);

    final allowAll = publisher(const MatchEventSettings(
      enabled: true,
      gameId: 'com.example.golf',
      summaryOnly: false,
    ));
    final record = await allowAll.publishMatchEvent(
      session: _session(pds.origin),
      eventType: 'achievement',
      matchId: 'match-1',
      playerId: 'p1',
      playerConsented: true,
    );
    expect(record, isNotNull);
  });

  test('the per-match cap holds even for a misbehaving caller', () async {
    final matchEvent = publisher(
      const MatchEventSettings(
        enabled: true,
        gameId: 'com.example.golf',
        maxEventsPerMatch: 2,
        summaryOnly: false,
      ),
    );
    final session = _session(pds.origin);
    Future<Object?> publish(String matchId) => matchEvent
        .publishMatchEvent(
          session: session,
          eventType: 'matchResult',
          matchId: matchId,
          playerId: 'p1',
          playerConsented: true,
        )
        .then((r) => r ?? 'null');
    await Future.wait([
      expectLater(publish('match-1'), completion(isA<MatchEventRecord>())),
      expectLater(publish('match-1'), completion(isA<MatchEventRecord>())),
      expectLater(publish('match-1'), throwsA(isA<StateError>())),
    ]);
    // The cap is per match: another match is unaffected.
    expect(await publish('match-2'), isA<MatchEventRecord>());
    expect(pds.created, hasLength(3));
  });

  test(
    'the oldest match retains its cap after more than 4096 matches',
    () async {
      final publisher = MatchEventPublisher(
        settings: const MatchEventSettings(enabled: true, maxEventsPerMatch: 1),
        httpClientFactory: () => MockClient(
          (_) async => http.Response('{"uri":"at://record","cid":"cid"}', 200),
        ),
      );
      addTearDown(publisher.close);
      final session = _session(pds.origin);
      Future<MatchEventRecord?> publish(String matchId) =>
          publisher.publishMatchEvent(
            session: session,
            eventType: 'matchResult',
            matchId: matchId,
            playerId: 'p1',
            playerConsented: true,
          );
      for (var i = 0; i <= 4096; i++) {
        await publish('match-$i');
      }
      await expectLater(publish('match-0'), throwsA(isA<StateError>()));
    },
  );

  test('oversize payloads are refused — milestones are small', () async {
    final matchEvent = publisher(
      const MatchEventSettings(enabled: true, gameId: 'com.example.golf'),
    );
    await expectLater(
      matchEvent.publishMatchEvent(
        session: _session(pds.origin),
        eventType: 'matchResult',
        matchId: 'match-1',
        playerId: 'p1',
        payload: {'blob': 'x' * 3000},
        playerConsented: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(pds.created, isEmpty);
  });

  test('delete removes a record; deleting a gone record is success',
      () async {
    final matchEvent = publisher(
      const MatchEventSettings(enabled: true, gameId: 'com.example.golf'),
    );
    final session = _session(pds.origin);
    final record = await matchEvent.publishMatchEvent(
      session: session,
      eventType: 'matchResult',
      matchId: 'match-1',
      playerId: 'p1',
      playerConsented: true,
    );
    await matchEvent.deleteMatchEvent(session: session, rkey: record!.rkey);
    expect(pds.deleted.single['rkey'], record.rkey);

    // The player may have deleted it themselves first: still fine.
    await matchEvent.deleteMatchEvent(session: session, rkey: record.rkey);
    expect(pds.deleted, hasLength(2));
  });

  test('a use_dpop_nonce challenge is answered with a retry', () async {
    pds.demandNonceOnce = 'nonce-1';
    final matchEvent = publisher(
      const MatchEventSettings(enabled: true, gameId: 'com.example.golf'),
    );
    final record = await matchEvent.publishMatchEvent(
      session: _session(pds.origin),
      eventType: 'matchResult',
      matchId: 'match-1',
      playerId: 'p1',
      playerConsented: true,
    );
    expect(record, isNotNull);
    expect(pds.created, hasLength(1));
    expect(pds.problems, isEmpty);
  });

  test('sign-in scope: read-only by default, repo only when configured',
      () async {
    final keys = await NodeClientKeys.generate();
    String scopeFor(bool repoWrite) => AtprotoAuthProvider(
          publicBaseUrl: 'https://rooms.example.com',
          keys: keys,
          tokens: JoinTokens('secret'.codeUnits),
          identityResolver: _failingResolver(),
          repoWriteScope: repoWrite,
        ).clientMetadata()['scope'] as String;
    expect(scopeFor(false), 'atproto');
    expect(scopeFor(true), 'atproto repo');
  });

  test('retained sessions: none by default, present when repo write is on',
      () async {
    final keys = await NodeClientKeys.generate();
    // The retention map fills during /auth/callback (covered by the auth
    // suite's full flow); here we pin the read-only invariant: the
    // default provider exposes no sessions at all.
    expect(
      AtprotoAuthProvider(
        publicBaseUrl: 'https://rooms.example.com',
        keys: keys,
        tokens: JoinTokens('secret'.codeUnits),
        identityResolver: _failingResolver(),
      ).sessionFor('did:plc:player1'),
      isNull,
    );
    expect(
      AtprotoAuthProvider(
        publicBaseUrl: 'https://rooms.example.com',
        keys: keys,
        tokens: JoinTokens('secret'.codeUnits),
        identityResolver: _failingResolver(),
        repoWriteScope: true,
      ).repoWriteScope,
      isTrue,
    );
  });
}

IdentityResolver _failingResolver() => _FailingResolver();

final class _FailingResolver implements IdentityResolver {
  @override
  noSuchMethod(Invocation invocation) =>
      throw StateError('not used in these tests');
}
