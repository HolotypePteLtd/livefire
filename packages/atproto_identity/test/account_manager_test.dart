import 'dart:convert';
import 'dart:io';

import 'package:rooms_atproto/rooms_atproto.dart';
import 'package:test/test.dart';

import 'fake_atproto.dart';

void main() {
  late FakeAtprotoServer atproto;
  late MemoryVault vault;

  setUp(() async {
    atproto = FakeAtprotoServer();
    await atproto.start();
    atproto.addIdentity('alice.test', 'did:plc:alice');
    atproto.addIdentity('bob.test', 'did:plc:bob');
    vault = MemoryVault();
  });

  tearDown(() => atproto.stop());

  AtprotoAccountManager manager() => AtprotoAccountManager(
    vault: vault,
    httpClientFactory: atproto.newClient,
    identityResolver: atproto.resolver(),
    openBrowser: (url) => browserVisit(atproto, url),
    clientName: 'rooms tests',
    allowPrivateNetwork: true,
  );

  test('loopback sign-in completes against the fake authorization server',
      () async {
    final account = await manager().signIn(handleHint: 'alice.test');
    expect(account.did, 'did:plc:alice');
    expect(account.handle, 'alice.test');
    expect(account.pds, Uri.parse(atproto.origin));
    expect(atproto.parCalls, hasLength(1));
    expect(atproto.parCalls.single['login_hint'], 'alice.test');
    expect(atproto.parCalls.single['scope'], 'atproto');
    expect(atproto.tokenCalls, hasLength(1));
    expect(atproto.tokenCalls.single['grant_type'], 'authorization_code');
    expect(atproto.tokenCalls.single['code_verifier'], isNotNull);
    // The vault now holds a version-1 session for the DID.
    final saved = jsonDecode(vault.value!) as Map<String, dynamic>;
    expect(saved['version'], 1);
    expect(saved['handle'], 'alice.test');
    expect((saved['session'] as Map)['sub'], 'did:plc:alice');
  });

  test('a saved session restores without a new browser round trip', () async {
    await manager().signIn(handleHint: 'alice.test');
    final second = manager();
    final account = await second.restore();
    expect(account?.did, 'did:plc:alice');
    // No new authorization: still exactly the one token call from sign-in.
    expect(atproto.tokenCalls, hasLength(1));
  });

  test('an expired session restores via the refresh grant', () async {
    // Sign in for an already-stale session, then re-issue for 1 hour: the
    // next restore must use the refresh grant on the same origin.
    atproto.expiresInSeconds = 0;
    final first = manager();
    await first.signIn(handleHint: 'alice.test');
    await first.dispose();
    atproto.expiresInSeconds = 3600;

    final account = await manager().restore();
    expect(account?.did, 'did:plc:alice');
    expect(
      atproto.tokenCalls.map((c) => c['grant_type']),
      contains('refresh_token'),
    );
  });

  test('a tampered session is discarded, not restored', () async {
    await manager().signIn(handleHint: 'alice.test');
    final saved = jsonDecode(vault.value!) as Map<String, dynamic>;
    (saved['session'] as Map)['sub'] = 'not-a-did';
    vault.value = jsonEncode(saved);
    final account = await manager().restore();
    expect(account, isNull);
    expect(vault.value, isNull);
  });

  test('signing in twice without signing out is refused', () async {
    final m = manager();
    await m.signIn(handleHint: 'alice.test');
    await expectLater(
      m.signIn(handleHint: 'bob.test'),
      throwsA(
        isA<AtprotoException>().having(
          (e) => e.code,
          'code',
          AtprotoError.conflict,
        ),
      ),
    );
    await m.dispose();
  });

  test('sign out clears the session and the vault', () async {
    final m = manager();
    await m.signIn(handleHint: 'alice.test');
    await m.signOut();
    expect(m.current, isNull);
    expect(vault.value, isNull);
    await m.dispose();
  });

  test('an unknown handle fails without a browser round trip', () async {
    await expectLater(
      manager().signIn(handleHint: 'nobody.test'),
      throwsA(isA<AtprotoException>()),
    );
  });

  test('oauth loopback rejects stray requests and consumes once', () async {
    final loopback = await OAuthLoopback.open(
      applicationName: 'tests',
      accept: (uri) async => uri.queryParameters.containsKey('state'),
    );
    try {
      final good = loopback.redirectUri.replace(queryParameters: {
        'state': 's1',
        'iss': 'http://127.0.0.1:1',
        'code': 'c1',
      });
      final client = HttpClient();
      try {
        final first = await client.getUrl(good);
        final response1 = await first.close();
        expect(response1.statusCode, 200);
        final second = await client.getUrl(good);
        final response2 = await second.close();
        expect(response2.statusCode, 400); // consumed
        final other = await client.getUrl(
          loopback.redirectUri.replace(path: '/nope'),
        );
        final response3 = await other.close();
        expect(response3.statusCode, 404);
      } finally {
        client.close();
      }
      expect((await loopback.callback).queryParameters['code'], 'c1');
    } finally {
      await loopback.close();
    }
  });
}
