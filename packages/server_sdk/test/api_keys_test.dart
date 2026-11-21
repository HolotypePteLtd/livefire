import 'dart:convert';
import 'dart:io';

import 'package:server_sdk/server_sdk.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('NodeStore API keys (hash-only)', () {
    test('bootstrap keys verify and are read-only for the panel', () {
      final store = NodeStore.open(':memory:')
        ..seedApiKeys({'default': 'sk_boot_key_1'});
      final verified = store.verifyApiKey('sk_boot_key_1');
      expect(verified, isNotNull);
      expect(verified!.bootstrap, isTrue);
      expect(verified.label, 'default');
      // Bootstrap rows cannot be revoked.
      expect(store.revokeApiKey(verified.id), isFalse);
      expect(store.verifyApiKey('sk_boot_key_1'), isNotNull);
      // Unknown and wrong keys fail.
      expect(store.verifyApiKey('sk_boot_key_2'), isNull);
      expect(store.verifyApiKey(''), isNull);
      store.close();
    });

    test('create returns the full key exactly once; only hashes persist',
        () async {
      final dir = await Directory.systemTemp.createTemp('api-keys-test-');
      final path = '${dir.path}/rooms.db';
      final store = NodeStore.open(path)
        ..seedApiKeys({'default': 'sk_boot_key_1'});
      final created = store.createApiKey(
        label: 'my game',
        createdByDid: 'did:plc:admin1',
      );
      expect(created.fullKey, startsWith('sk_'));
      expect(created.fullKey.length, 43); // sk_ + 40 unguessable chars
      expect(created.record.keyPrefix, created.fullKey.substring(0, 8));
      expect(created.record.bootstrap, isFalse);
      expect(created.record.live, isTrue);

      // The plaintext verifies via its hash…
      final verified = store.verifyApiKey(created.fullKey);
      expect(verified!.id, created.record.id);
      expect(verified.label, 'my game');
      expect(verified.createdByDid, 'did:plc:admin1');

      // …and is nowhere in the database: scan every cell of every table
      // through an independent connection.
      store.close();
      final raw = sqlite3.open(path);
      final dump = StringBuffer();
      for (final table
          in raw.select("SELECT name FROM sqlite_master WHERE type = 'table';")) {
        final name = table['name'] as String;
        for (final row in raw.select('SELECT * FROM $name;')) {
          dump.write(jsonEncode([for (final k in row.keys) row[k]]));
        }
      }
      raw.dispose();
      expect(dump.toString().contains(created.fullKey), isFalse);
      expect(dump.toString().contains(created.record.keyHash), isTrue);

      // Listing (after reopen) shows prefix/label/dates only.
      final reopened = NodeStore.open(path);
      final listed = reopened.listApiKeys();
      expect(listed.length, 2);
      expect(listed.first.bootstrap, isTrue); // bootstrap first
      expect(listed.last.keyPrefix, created.record.keyPrefix);
      reopened.close();
      await dir.delete(recursive: true);
    });

    test('revoked keys stop verifying; re-revoke is a no-op', () {
      final store = NodeStore.open(':memory:');
      final created = store.createApiKey(label: 'temp');
      expect(store.verifyApiKey(created.fullKey), isNotNull);
      expect(store.revokeApiKey(created.record.id), isTrue);
      expect(store.verifyApiKey(created.fullKey), isNull);
      expect(store.revokeApiKey(created.record.id), isFalse);
      final listed = store.listApiKeys().single;
      expect(listed.revokedAt, isNotNull);
      expect(listed.live, isFalse);
      store.close();
    });

    test('usage counters increment per key', () {
      final store = NodeStore.open(':memory:');
      final a = store.createApiKey(label: 'a');
      final b = store.createApiKey(label: 'b');
      store.incrementApiKeyUsage(a.record.id, roomsCreated: 1);
      store.incrementApiKeyUsage(a.record.id, tokensMinted: 1);
      store.incrementApiKeyUsage(a.record.id, tokensMinted: 1);
      store.incrementApiKeyUsage(b.record.id, roomsCreated: 1);
      final rows = {for (final k in store.listApiKeys()) k.id: k};
      expect(rows[a.record.id]!.roomsCreated, 1);
      expect(rows[a.record.id]!.tokensMinted, 2);
      expect(rows[b.record.id]!.roomsCreated, 1);
      expect(rows[b.record.id]!.tokensMinted, 0);
      store.close();
    });

    test('reseeding bootstrap keys leaves panel keys and counters alone',
        () {
      final store = NodeStore.open(':memory:')
        ..seedApiKeys({'default': 'sk_boot_key_1'});
      final created = store.createApiKey(label: 'panel key');
      store.incrementApiKeyUsage(created.record.id, roomsCreated: 3);
      // Boot again with a rotated bootstrap key.
      store.seedApiKeys({'default': 'sk_boot_key_2'});
      expect(store.verifyApiKey('sk_boot_key_1'), isNull);
      expect(store.verifyApiKey('sk_boot_key_2'), isNotNull);
      final stillThere = store.verifyApiKey(created.fullKey);
      expect(stillThere!.roomsCreated, 3);
      expect(store.listApiKeys().length, 2);
      store.close();
    });

    test('migrates a pre-panel plaintext api_keys table', () async {
      final dir = await Directory.systemTemp.createTemp('api-keys-mig-');
      final path = '${dir.path}/rooms.db';
      // A v0 database: the old plaintext (key, name, created_at) table.
      final raw = sqlite3.open(path);
      raw.execute(
          'CREATE TABLE api_keys (key TEXT PRIMARY KEY, name TEXT NOT NULL,'
          ' created_at TEXT NOT NULL);');
      raw.execute(
          "INSERT INTO api_keys VALUES ('sk_plaintext_legacy', 'default',"
          " '2026-01-01T00:00:00Z');");
      raw.dispose();
      // Opening it migrates to the hash-only schema; the boot seed that
      // follows restores the bootstrap row (hashed) from config.
      final store = NodeStore.open(path);
      expect(store.verifyApiKey('sk_plaintext_legacy'), isNull);
      store.seedApiKeys({'default': 'sk_fresh_boot_key'});
      expect(store.verifyApiKey('sk_fresh_boot_key'), isNotNull);
      store.close();
      await dir.delete(recursive: true);
    });
  });

  group('panel session tokens', () {
    final tokens = JoinTokens('node-secret-1'.codeUnits);
    final now = DateTime.utc(2026, 12, 1, 12);

    test('mints and verifies a reusable DID session', () {
      final session = tokens.mintPanelSession('did:plc:admin',
          handle: 'admin.bsky.social', now: now);
      expect(session.startsWith('ps_'), isTrue);
      final check = tokens.verifyPanelSession(session,
          now: now.add(const Duration(hours: 1)));
      expect(check.ok, isTrue);
      expect(check.session!.did, 'did:plc:admin');
      expect(check.session!.handle, 'admin.bsky.social');
      // Still valid later (multi-use bearer, no ledger).
      final later = tokens.verifyPanelSession(session,
          now: now.add(const Duration(hours: 11)));
      expect(later.ok, isTrue);
    });

    test('expired sessions and foreign token types are rejected', () {
      final session = tokens.mintPanelSession('did:plc:admin', now: now);
      expect(
        tokens
            .verifyPanelSession(session,
                now: now.add(const Duration(hours: 12, seconds: 1)))
            .problem,
        TokenProblem.expired,
      );
      // A join token is not a panel session.
      final join = tokens.mintJoin('room-key', now: now);
      expect(
        tokens.verifyPanelSession(join, now: now).problem,
        TokenProblem.malformed,
      );
      // Neither is a tampered panel token.
      final tampered = session.replaceRange(
          6, 7, session[6] == 'A' ? 'B' : 'A');
      expect(
        tokens.verifyPanelSession(tampered, now: now).problem,
        anyOf(TokenProblem.badSignature, TokenProblem.malformed),
      );
      // A panel session is not a join token either.
      expect(
        tokens.verify(session, roomKey: '', now: now).ok,
        isFalse,
      );
    });

    test('a panel session from another node secret fails its signature',
        () {
      final other = JoinTokens('node-secret-2'.codeUnits);
      final session = other.mintPanelSession('did:plc:admin', now: now);
      expect(
        tokens.verifyPanelSession(session, now: now).problem,
        TokenProblem.badSignature,
      );
    });
  });
}
