import 'dart:io';

import 'package:livefire_atproto_server/livefire_atproto_server.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import '../../server_sdk/test/supabase_stub.dart';

void main() {
  test(
    'enabling accounts on an existing node preserves its account data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'livefire-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/rooms.db';
      final original = NodeStore.open(path);
      try {
        // Structure used by nodes before the package split.
        original.database.execute('''
        CREATE TABLE guest_credentials (
          did TEXT PRIMARY KEY, handle TEXT NOT NULL,
          password TEXT NOT NULL, created_at TEXT NOT NULL
        );
        INSERT INTO guest_credentials VALUES (
          'did:plc:alice', 'alice.test', 'test-password', '2025-01-01T00:00:00Z'
        );
      ''');
      } finally {
        original.close();
      }

      final reopened = NodeStore.open(path);
      addTearDown(reopened.close);
      final accounts = SqliteAccountStore(reopened.database);
      final alice = await accounts.guestCredentialFor('did:plc:alice');
      expect(alice?.handle, 'alice.test');
      expect(alice?.password, 'test-password');
      await accounts.addRecoveryKey(
        StoredRecoveryKey(
          did: 'did:plc:alice',
          pubkeyHash: 'hash',
          pubkeyJwk: {'kty': 'EC'},
          guest: true,
          createdAt: DateTime.utc(2025),
        ),
      );
      expect(
        (await accounts.recoveryKeyFor('did:plc:alice'))?.pubkeyHash,
        'hash',
      );
    },
  );

  group('guest credentials (identity ladder)', () {
    test('upsert + fetch; latest credentials win', () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final platform = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const [],
      );
      addTearDown(platform.close);
      final store = SupabaseDeviceAccountStore(platform);

      expect(await store.guestCredentialFor('did:plc:g'), isNull);
      await store.addGuestCredential(
        StoredGuestCredential(
          did: 'did:plc:g',
          handle: 'anon-abc.example.com',
          password: 'pw-one',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      final first = await store.guestCredentialFor('did:plc:g');
      expect(first!.handle, 'anon-abc.example.com');
      expect(first.password, 'pw-one');

      await store.addGuestCredential(
        StoredGuestCredential(
          did: 'did:plc:g',
          handle: 'anon-abc.example.com',
          password: 'pw-two',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      expect((await store.guestCredentialFor('did:plc:g'))!.password, 'pw-two');

      // Wire shape: the upsert RPC carries the password as its own arg.
      final upserts = supabase.calls
          .where((c) => c.$1 == 'panel_upsert_guest_credential')
          .toList();
      expect(upserts, hasLength(2));
      expect(upserts.first.$2['p_password'], 'pw-one');
    });
  });

  group('recovery keys (guest identity ladder)', () {
    test(
      'register once, fetch back, conflict surfaces as StateError',
      () async {
        final supabase = FakeSupabase('svc-key-1');
        await supabase.start();
        addTearDown(supabase.stop);

        final platform = await SupabasePlatformStore.connect(
          supabase.origin,
          'svc-key-1',
          bootstrapKeys: const {},
          seedAdminDids: const [],
        );
        addTearDown(platform.close);
        final store = SupabaseDeviceAccountStore(platform);

        final jwk = {'kty': 'EC', 'crv': 'P-256', 'x': 'A' * 43, 'y': 'B' * 43};
        await store.addRecoveryKey(
          StoredRecoveryKey(
            did: 'did:plc:guest1',
            pubkeyHash: 'hash-1',
            pubkeyJwk: jwk,
            guest: true,
            createdAt: DateTime.now().toUtc(),
          ),
        );

        final fetched = await store.recoveryKeyFor('did:plc:guest1');
        expect(fetched, isNotNull);
        expect(fetched!.did, 'did:plc:guest1');
        expect(fetched.pubkeyHash, 'hash-1');
        expect(fetched.pubkeyJwk, jwk);
        expect(fetched.guest, isTrue);

        expect(await store.recoveryKeyFor('did:plc:none'), isNull);

        // One key per DID: the SQL insert returns null -> StateError.
        await expectLater(
          () => store.addRecoveryKey(
            StoredRecoveryKey(
              did: 'did:plc:guest1',
              pubkeyHash: 'hash-2',
              pubkeyJwk: jwk,
              guest: true,
              createdAt: DateTime.now().toUtc(),
            ),
          ),
          throwsA(isA<StateError>()),
        );

        // The JWK travels as the RPC argument as a jsonb object, never a
        // string-encoded one (the store passes the Map through).
        final register = supabase.calls
            .where((c) => c.$1 == 'panel_register_recovery_key')
            .toList();
        expect(register, hasLength(2));
        expect(register.first.$2['p_pubkey_jwk'], isA<Map<String, dynamic>>());
      },
    );
  });
}
