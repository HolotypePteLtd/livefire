import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

void main() {
  List<int> bytes(String s) => s.codeUnits;

  group('JoinTokens', () {
    final tokens = JoinTokens(bytes('node-secret-1'));
    final now = DateTime.utc(2026, 12, 1, 12);

    test('mints verifiable join and creator tokens', () {
      final join = tokens.mintJoin('room-key-1', now: now);
      final creator = tokens.mintCreator('room-key-1', now: now);
      expect(join.startsWith('jt_'), isTrue);
      expect(creator.startsWith('ct_'), isTrue);
      final checkedJoin = tokens.verify(join,
          roomKey: 'room-key-1', now: now.add(const Duration(seconds: 1)));
      expect(checkedJoin.ok, isTrue);
      expect(checkedJoin.payload!.creator, isFalse);
      expect(checkedJoin.payload!.nonce, isNotEmpty);
      final checkedCreator = tokens.verify(creator,
          roomKey: 'room-key-1', now: now.add(const Duration(seconds: 1)));
      expect(checkedCreator.payload!.creator, isTrue);
    });

    test('rejects tokens from a different node secret', () {
      final other = JoinTokens(bytes('node-secret-2'));
      final token = other.mintJoin('room-key-1', now: now);
      final check = tokens.verify(token, roomKey: 'room-key-1', now: now);
      expect(check.ok, isFalse);
      expect(check.problem, TokenProblem.badSignature);
    });

    test('rejects tampered payloads and macs', () {
      final token = tokens.mintJoin('room-key-1', now: now);
      final tampered =
          token.replaceRange(5, 6, token[5] == 'A' ? 'B' : 'A');
      final check =
          tokens.verify(tampered, roomKey: 'room-key-1', now: now);
      expect(check.problem, anyOf(TokenProblem.badSignature, TokenProblem.malformed));
      final macFlipped = token.substring(0, token.length - 2) +
          (token.endsWith('aa') ? 'bb' : 'aa');
      expect(
        tokens.verify(macFlipped, roomKey: 'room-key-1', now: now).problem,
        TokenProblem.badSignature,
      );
    });

    test('rejects expired tokens at the boundary', () {
      final token = tokens.mintJoin('room-key-1',
          now: now, ttl: const Duration(minutes: 15));
      expect(
        tokens.verify(token,
            roomKey: 'room-key-1',
            now: now.add(const Duration(minutes: 15))),
        isA<TokenCheck>().having((c) => c.problem, 'problem',
            TokenProblem.expired),
      );
      expect(
        tokens.verify(token,
            roomKey: 'room-key-1',
            now: now.add(const Duration(minutes: 14, seconds: 59))).ok,
        isTrue,
      );
    });

    test('rejects tokens minted for another room', () {
      final token = tokens.mintJoin('room-key-1', now: now);
      expect(
        tokens.verify(token, roomKey: 'room-key-2', now: now).problem,
        TokenProblem.wrongRoom,
      );
    });

    test('rejects garbage outright', () {
      for (final garbage in ['', 'jt_', 'ct_nope', 'xx_a.b', 'jt_a.b.c']) {
        expect(
          tokens.verify(garbage, roomKey: 'r', now: now).ok,
          isFalse,
          reason: 'accepted "$garbage"',
        );
      }
    });

    test('every mint gets a fresh nonce (one-time ids)', () {
      final nonces = {
        for (var i = 0; i < 64; i++)
          tokens
              .mintJoin('r', now: now)
              .split('.')
              .last,
      };
      // The mac differs per nonce; 64 mints must yield 64 distinct macs.
      expect(nonces.length, 64);
    });
  });

  group('TokenLedger', () {
    test('consumption is single-use', () {
      final ledger = MemoryTokenLedger();
      expect(ledger.consume('a'), isTrue);
      expect(ledger.consume('a'), isFalse);
      expect(ledger.consume('b'), isTrue);
    });
  });

  group('OriginGate', () {
    test('empty allowlist allows everything (local dev)', () {
      final gate = OriginGate(const []);
      expect(gate.enforced, isFalse);
      expect(gate.allowed(null), isTrue);
      expect(gate.allowed('https://evil.example'), isTrue);
    });

    test('non-empty allowlist requires a listed origin', () {
      final gate = OriginGate(const ['https://game.example.com']);
      expect(gate.allowed('https://game.example.com'), isTrue);
      expect(gate.allowed('https://GAME.example.com'), isTrue); // normalized
      expect(gate.allowed('https://game.example.com:443'), isTrue); // default port
      expect(gate.allowed('https://other.example.com'), isFalse);
      expect(gate.allowed('https://game.example.com.evil.io'), isFalse);
      expect(gate.allowed('null'), isFalse);
      expect(gate.allowed(null), isFalse);
    });
  });

  group('IpThrottle', () {
    test('sliding window admits maxPerWindow then rejects', () {
      final throttle = IpThrottle(maxPerWindow: 3, window: const Duration(minutes: 1));
      final t0 = DateTime.utc(2026, 12, 1);
      for (var i = 0; i < 3; i++) {
        expect(throttle.allow('10.0.0.1', t0), isTrue, reason: 'attempt $i');
      }
      expect(throttle.allow('10.0.0.1', t0), isFalse);
      expect(throttle.allow('10.0.0.2', t0), isTrue); // per-IP
      // The window slides: attempts older than the window stop counting.
      final later = t0.add(const Duration(minutes: 1, seconds: 1));
      expect(throttle.allow('10.0.0.1', later), isTrue);
    });

    test('prune drops idle ips', () {
      final throttle = IpThrottle(maxPerWindow: 2, window: const Duration(seconds: 30));
      final t0 = DateTime.utc(2026, 12, 1);
      throttle.allow('10.0.0.1', t0);
      throttle.allow('10.0.0.2', t0);
      expect(throttle.trackedIps, 2);
      throttle.prune(t0.add(const Duration(seconds: 31)));
      expect(throttle.trackedIps, 0);
    });
  });

  test('secureEquals compares keys without shortcuts', () {
    expect(secureEquals('sk_same', 'sk_same'), isTrue);
    expect(secureEquals('sk_same', 'sk_diff'), isFalse);
    expect(secureEquals('sk_same', 'sk_same2'), isFalse);
    expect(secureEquals('', ''), isTrue);
  });
}
