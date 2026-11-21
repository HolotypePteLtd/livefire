import 'dart:async';

import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'supabase_stub.dart';

void main() {
  group('SupabasePlatformStore over PostgREST RPC', () {
    test('connect seeds admins once, warms the cache, reports seeding',
        () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {'default': 'sk_boot_key_1'},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      expect(store.mode, 'postgres');
      expect(store.seededAdmins, isTrue);
      expect(store.hasAdmins, isTrue);
      expect(store.isAdmin('did:plc:admin'), isTrue);
      expect(store.isAdmin('did:plc:rando'), isFalse);

      // A second boot against the same database: the marker row makes
      // the seed a no-op; the DB admins are the truth.
      final again = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin', 'did:plc:other'],
      );
      addTearDown(again.close);
      expect(again.seededAdmins, isFalse);
      expect(again.isAdmin('did:plc:admin'), isTrue);
      expect(again.isAdmin('did:plc:other'), isFalse); // not re-seeded
    });

    test('bootstrap keys verify in memory and never hit Postgres',
        () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {'default': 'sk_boot_key_1'},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final verified = store.verifyApiKey('sk_boot_key_1');
      expect(verified, isNotNull);
      expect(verified!.bootstrap, isTrue);
      expect(verified.id, 'boot-default');
      expect(store.verifyApiKey('sk_wrong'), isNull);
      // Bootstrap keys are not rows: no create/revoke calls happened.
      expect(
        supabase.calls.where((c) => c.$1.startsWith('panel_create')).length,
        0,
      );
      expect(await store.revokeApiKey('boot-default'), isFalse);
    });

    test('bearer verification is cache-backed: no HTTP per request',
        () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);
      supabase.addKey('ak_preexisting',
          label: 'pre-existing', keyHash: ApiKeyMaterial.hash('sk_old_key'));

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final before = supabase.calls.length;
      for (var i = 0; i < 50; i++) {
        expect(store.verifyApiKey('sk_old_key'), isNotNull);
      }
      expect(supabase.calls.length, before); // zero RPCs for 50 verifies
    });

    test('create returns the full key once; only the hash crosses the wire',
        () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final created = await store.createApiKey(
        label: 'my game',
        createdByDid: 'did:plc:admin',
        maxRooms: 5,
        templates: const ['relay'],
      );
      expect(created.fullKey, startsWith('sk_'));
      expect(created.fullKey.length, 43);
      expect(created.record.maxRooms, 5);
      expect(created.record.templates, ['relay']);
      expect(created.record.bootstrap, isFalse);

      // The RPC saw the hash, the prefix, the scopes — never the key.
      final call = supabase.calls
          .firstWhere((c) => c.$1 == 'panel_create_key')
          .$2;
      expect(call['p_key_hash'], ApiKeyMaterial.hash(created.fullKey));
      expect(call['p_key_prefix'], created.fullKey.substring(0, 8));
      expect(call['p_max_rooms'], 5);
      expect(call['p_templates'], ['relay']);
      expect(jsonOf(supabase).contains(created.fullKey), isFalse);

      // And the new key verifies immediately (cache updated by refresh).
      final verified = store.verifyApiKey(created.fullKey);
      expect(verified!.id, created.record.id);
      expect(verified.maxRooms, 5);
    });

    test('revocation stops verification after the post-write refresh',
        () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final created = await store.createApiKey(label: 'temp');
      expect(store.verifyApiKey(created.fullKey), isNotNull);
      expect(await store.revokeApiKey(created.record.id), isTrue);
      expect(store.verifyApiKey(created.fullKey), isNull);
      expect(await store.revokeApiKey(created.record.id), isFalse);

      // The revoked row is still listed (with its revokedAt).
      final listed = await store.listApiKeys();
      expect(listed.single.revokedAt, isNotNull);
    });

    test('consumeRoom waits for the authoritative counters and denies stale keys',
        () async {
      final supabase = FakeSupabase('svc-key-1', latency: const Duration(milliseconds: 300));
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final created = await store.createApiKey(label: 'game', maxRooms: 2);
      final key = store.verifyApiKey(created.fullKey)!;
      final authorization = store.consumeRoom(key, 'relay');
      expect(store.verifyApiKey(created.fullKey)!.roomsCreated, 0);
      await authorization;
      expect(store.verifyApiKey(created.fullKey)!.roomsCreated, 1);
      final call = supabase.calls
          .firstWhere((c) => c.$1 == 'panel_consume_room')
          .$2;
      expect(call['p_id'], created.record.id);
      expect(call['p_template'], 'relay');

      // Both requests use the same cached key. SQL approves only one.
      await Future.wait([
        expectLater(store.consumeRoom(key, 'relay'), completes),
        expectLater(store.consumeRoom(key, 'relay'), throwsA(
            isA<RoomException>().having((error) => error.code, 'code', 'key_room_limit'))),
      ]);
      final key3 = store.verifyApiKey(created.fullKey)!;
      expect(key3.roomsCreated, 2);
      expect(key3.scopeViolationFor('relay')!.code, 'key_room_limit');
      final scoped = await store.createApiKey(
          label: 'templates-only', templates: const ['relay']);
      final freshKey = store.verifyApiKey(scoped.fullKey)!;
      expect(freshKey.scopeViolationFor('physics')!.code,
          'key_template_not_allowed');
      expect(freshKey.scopeViolationFor('relay'), isNull);
      // An unscoped key (null templates) allows every template.
      final open = await store.createApiKey(label: 'open');
      final openKey = store.verifyApiKey(open.fullKey)!;
      expect(openKey.scopeViolationFor('anything'), isNull);
    });

    test('consumeToken counts best-effort in cache and SQL', () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final created = await store.createApiKey(label: 'tokens');
      final key = store.verifyApiKey(created.fullKey)!;
      await store.consumeToken(key);
      expect(store.verifyApiKey(created.fullKey)!.tokensMinted, 1);
      await pumpUntil(() => supabase.calls.any((c) => c.$1 == 'panel_consume_token'));
    });

    test('admin mutations surface the SQL guard codes', () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      final promoted =
          await store.promoteAdmin(did: 'did:plc:two', actorDid: 'did:plc:admin');
      expect(promoted.ok, isTrue);
      expect(store.isAdmin('did:plc:two'), isTrue);

      expect((await store.revokeAdmin(did: 'did:plc:two', actorDid: 'did:plc:two')).code, 'self');
      expect((await store.revokeAdmin(did: 'did:plc:ghost', actorDid: 'did:plc:admin')).code, 'not_found');

      // Two active admins: revoking one is fine…
      expect(
          (await store.revokeAdmin(did: 'did:plc:two', actorDid: 'did:plc:admin'))
              .ok,
          isTrue);
      expect(store.isAdmin('did:plc:two'), isFalse);
      // …but now the last one cannot go.
      expect(
          (await store.revokeAdmin(did: 'did:plc:admin', actorDid: 'did:plc:two'))
              .code,
          'last_admin');
      expect(store.isAdmin('did:plc:admin'), isTrue);

      // Re-promotion re-activates the revoked row.
      expect(
          (await store.promoteAdmin(did: 'did:plc:two', actorDid: 'did:plc:admin'))
              .ok,
          isTrue);
      expect(store.isAdmin('did:plc:two'), isTrue);
    });

    test('audit writes round-trip; listing is newest first', () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
      );
      addTearDown(store.close);

      await store.writeAudit(
        actorDid: 'did:plc:admin',
        action: 'key.create',
        targetType: 'api_key',
        targetId: 'ak_1',
        details: {'label': 'game'},
      );
      await store.writeAudit(actorDid: 'did:plc:admin', action: 'key.revoke');
      final entries = await store.listAudit();
      expect(entries.length, 2);
      expect(entries.first.action, 'key.revoke'); // newest first
      expect(entries.last.action, 'key.create');
      expect(entries.last.details, {'label': 'game'});
      expect(entries.last.targetId, 'ak_1');
      final limited = await store.listAudit(limit: 1);
      expect(limited.length, 1);
    });

    test('a short TTL refreshes the cache without a panel write',
        () async {
      final supabase = FakeSupabase('svc-key-1');
      await supabase.start();
      addTearDown(supabase.stop);
      supabase.addKey('ak_direct',
          label: 'direct', keyHash: ApiKeyMaterial.hash('sk_direct_key'));

      final store = await SupabasePlatformStore.connect(
        supabase.origin,
        'svc-key-1',
        bootstrapKeys: const {},
        seedAdminDids: const ['did:plc:admin'],
        refreshTtl: const Duration(milliseconds: 30),
      );
      addTearDown(store.close);
      expect(store.verifyApiKey('sk_direct_key'), isNotNull);

      // Another actor revokes the key directly in the database; no
      // panel write happens on this node — the TTL timer picks it up.
      supabase.addKey('ak_direct',
          label: 'direct',
          keyHash: ApiKeyMaterial.hash('sk_direct_key'),
          revoked: true);
      await pumpUntil(() => store.verifyApiKey('sk_direct_key') == null,
          timeout: const Duration(seconds: 5));
    });

    test('fromEnvironment returns null without the env pair (SQLite mode)',
        () async {
      // The test runner does not set SUPABASE_*; the automatic mode
      // selection must fall back to SQLite.
      expect(
        await SupabasePlatformStore.fromEnvironment(
          bootstrapKeys: const {},
          seedAdminDids: const [],
        ),
        isNull,
      );
    });

    test('unreachable stack fails connect loudly (never keyless)',
        () async {
      // Port 1 on localhost: nothing there.
      await expectLater(
        SupabasePlatformStore.connect(
          'http://127.0.0.1:1',
          'svc-key-1',
          bootstrapKeys: const {},
          seedAdminDids: const [],
        ),
        throwsA(isA<PlatformStoreException>()),
      );
    });
  });

  group('SqlitePlatformStore (SQLite mode is unchanged)', () {
    test('delegates keys to NodeStore; admins are the config list',
        () async {
      final store = NodeStore.open(':memory:')
        ..seedApiKeys({'default': 'sk_boot_key_1'});
      addTearDown(store.close);
      final platform = SqlitePlatformStore(store,
          adminDids: const ['did:plc:admin']);

      expect(platform.mode, 'sqlite');
      expect(platform.canManageAdmins, isFalse);
      expect(platform.hasAuditLog, isFalse);
      expect(platform.hasAdmins, isTrue);
      expect(platform.isAdmin('did:plc:admin'), isTrue);
      expect(platform.isAdmin('did:plc:rando'), isFalse);

      final verified = platform.verifyApiKey('sk_boot_key_1');
      expect(verified!.bootstrap, isTrue);

      final created = await platform.createApiKey(label: 'game');
      expect(created.record.maxRooms, isNull); // unscoped in SQLite mode
      final key = platform.verifyApiKey(created.fullKey)!;
      await platform.consumeRoom(key, 'relay');
      await platform.consumeToken(key);
      expect(platform.verifyApiKey(created.fullKey)!.roomsCreated, 1);
      expect(platform.verifyApiKey(created.fullKey)!.tokensMinted, 1);
      expect(await platform.revokeApiKey(created.record.id), isTrue);

      final admins = await platform.listAdmins();
      expect(admins.single.readOnly, isTrue);
      expect((await platform.promoteAdmin(did: 'did:plc:x', actorDid: 'did:plc:admin')).ok,
          isFalse);
      expect((await platform.revokeAdmin(did: 'did:plc:admin', actorDid: 'did:plc:admin')).ok,
          isFalse);
      // Audit is a documented no-op; listing is empty, not an error.
      await platform.writeAudit(actorDid: 'did:plc:admin', action: 'key.create');
      expect(await platform.listAudit(), isEmpty);
      await platform.close(); // does not close the NodeStore
    });

    test('scoped key creation is refused loudly in SQLite mode', () async {
      final store = NodeStore.open(':memory:');
      addTearDown(store.close);
      final platform = SqlitePlatformStore(store, adminDids: const []);
      await expectLater(
        platform.createApiKey(label: 'scoped', maxRooms: 3),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        platform.createApiKey(label: 'scoped', templates: const ['relay']),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

}

/// Everything the stub ever received, as one JSON blob (plaintext scan).
String jsonOf(FakeSupabase supabase) =>
    supabase.calls.map((c) => '${c.$1}${c.$2}').join();

/// Pumps the event loop until [test] passes (bounded).
Future<void> pumpUntil(bool Function() test, {Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
