import 'dart:convert';
import 'dart:io';

import 'package:rooms_node/rooms_node.dart';
import 'package:test/test.dart';

Map<String, dynamic> validConfig() => {
      'publicBaseUrl': 'https://rooms.example.com',
      'nodeSecret': 's3cret-node-secret-32-chars!!',
      'apiKeys': {'default': 'sk_test_key_1'},
      'dataDir': '/tmp/rooms-node-test',
      'listen': {'port': 8787, 'address': '127.0.0.1'},
      'allowedOrigins': ['https://game.example.com'],
      'limits': {
        'maxRooms': 10,
        'maxReservedCapacity': 200,
        'idleTtlSeconds': 60,
        'connectionsPerIpPerMinute': 30,
      },
      'joinTokenTtlSeconds': 600,
      'physics': true,
    };

Map<String, dynamic> withAuth(Map<String, dynamic> base,
        Map<String, dynamic> auth) =>
    {...base, 'auth': auth};

/// First problem NodeConfig.fromJson reports for [config], or null.
Object? configProblem(Map<String, dynamic> config) {
  try {
    NodeConfig.fromJson(config);
    return null;
  } on FormatException catch (e) {
    return e.message.split('\\n').first;
  }
}

void main() {
  test('auth defaults to the guest provider only', () {
    final config = NodeConfig.fromJson(validConfig());
    expect(config.auth.providers, ['guest']);
    expect(config.auth.atprotoEnabled, isFalse);
  });

  test('the atproto provider config parses', () {
    final config = NodeConfig.fromJson(withAuth(validConfig(), {
      'providers': ['guest', 'atproto'],
      'atproto': {
        'clientName': 'example rooms',
        'entrywayUrl': 'https://bsky.social',
        'plcDirectoryUrl': 'https://plc.directory',
        'jwksPath': '/etc/rooms/oauth-client-jwks.json',
      },
    }));
    expect(config.auth.providers, ['guest', 'atproto']);
    expect(config.auth.atprotoEnabled, isTrue);
    expect(config.auth.atproto!.clientName, 'example rooms');
    expect(
        config.auth.atproto!.jwksPath, '/etc/rooms/oauth-client-jwks.json');
  });

  test('atproto without its settings is rejected', () {
    expect(
      () => NodeConfig.fromJson(withAuth(validConfig(), {
        'providers': ['atproto'],
      })),
      throwsFormatException,
    );
    expect(
      () => NodeConfig.fromJson(withAuth(validConfig(), {
        'providers': ['guest'],
        'atproto': {'jwksPath': '/x'},
      })),
      throwsFormatException,
    );
    expect(
      () => NodeConfig.fromJson(withAuth(validConfig(), {
        'providers': ['nosuch'],
      })),
      throwsFormatException,
    );
    expect(
      () => NodeConfig.fromJson(withAuth(validConfig(), {
        'providers': [],
      })),
      throwsFormatException,
    );
  });

  test('the example config parses with every field applied', () {
    final config = NodeConfig.fromJson(validConfig());
    expect(config.listen.port, 8787);
    expect(config.listen.address, '127.0.0.1');
    expect(config.publicBaseUrl, 'https://rooms.example.com');
    expect(config.apiKeys, {'default': 'sk_test_key_1'});
    expect(config.dataDir, '/tmp/rooms-node-test');
    expect(config.allowedOrigins, ['https://game.example.com']);
    expect(config.limits.maxRooms, 10);
    expect(config.limits.idleTtlSeconds, 60);
    expect(config.joinTokenTtlSeconds, 600);
    expect(config.physics, isTrue);
  });

  test('the shipped self-hosting example starts with guest auth', () {
    final example = File('../../deploy/node.example.json').readAsStringSync();
    final config = NodeConfig.fromJson(
      jsonDecode(example) as Map<String, dynamic>,
    );
    expect(config.auth.providers, ['guest']);
    expect(config.auth.atproto, isNull);
    expect(config.adminDids, isEmpty);
  });

  test('adminDids defaults to empty (panel disabled) and parses DIDs', () {
    final config = NodeConfig.fromJson(validConfig());
    expect(config.adminDids, isEmpty);
    final withAdmins = NodeConfig.fromJson({
      ...validConfig(),
      'adminDids': ['did:plc:admin1', 'did:web:op.example.com'],
    });
    expect(withAdmins.adminDids,
        ['did:plc:admin1', 'did:web:op.example.com']);
    // Not DIDs:
    expect(
        configProblem({
          ...validConfig(),
          'adminDids': ['admin.bsky.social'],
        }),
        contains('adminDids must be a list of DIDs'));
    expect(
        configProblem({
          ...validConfig(),
          'adminDids': 'did:plc:admin1',
        }),
        contains('adminDids must be a list of DIDs'));
    expect(
        configProblem({
          ...validConfig(),
          'adminDids': [123],
          'allowedOrigins': [456],
        }),
        contains('allowedOrigins must be a list of strings'));
    final withProxies = NodeConfig.fromJson({
      ...validConfig(),
      'trustedProxies': ['127.0.0.1', '172.18.0.2'],
    });
    expect(withProxies.trustedProxies, ['127.0.0.1', '172.18.0.2']);
  });

  test('defaults apply when optional sections are absent', () {
    final config =
        NodeConfig.fromJson(jsonDecode(jsonEncode({
              ...validConfig()
                ..remove('listen')
                ..remove('limits')
                ..remove('allowedOrigins')
                ..remove('joinTokenTtlSeconds')
                ..remove('physics'),
            })));
    expect(config.listen.port, 8787);
    expect(config.listen.address, '0.0.0.0');
    expect(config.allowedOrigins, isEmpty);
    expect(config.limits.maxRooms, 256);
    expect(config.limits.idleTtlSeconds, 300);
    expect(config.limits.connectionsPerIpPerMinute, 60);
    expect(config.joinTokenTtlSeconds, 900);
    expect(config.physics, isTrue);
  });

  test('missing or invalid fields fail fast, all problems at once', () {
    final broken = validConfig()
      ..remove('publicBaseUrl')
      ..remove('nodeSecret')
      ..remove('apiKeys')
      ..remove('dataDir')
      ..['nodeSecret'] = 'short'
      ..['extra'] = true;
    broken['limits'] = {'maxRooms': 0, 'idleTtlSeconds': 999999999};
    Object? problem;
    try {
      NodeConfig.fromJson(broken);
    } on FormatException catch (e) {
      problem = e;
    }
    final message = (problem as FormatException).message;
    for (final expected in [
      'publicBaseUrl is required',
      'apiKeys must be a non-empty object',
      'dataDir is required',
      'nodeSecret must be at least 16 characters',
      'Unknown config field: extra',
      'maxRooms must be an integer in 1-100000',
      'idleTtlSeconds must be an integer in 1-86400',
    ]) {
      expect(message, contains(expected));
    }
  });

  test('bad publicBaseUrl and joinTokenTtlSeconds are rejected', () {
    Object? problemFor(Map<String, dynamic> config) {
      try {
        NodeConfig.fromJson(config);
        return null;
      } on FormatException catch (e) {
        return e.message;
      }
    }

    expect(
      problemFor({...validConfig(), 'publicBaseUrl': 'rooms.example.com'}),
      contains('publicBaseUrl must start with https://'),
    );
    expect(
      problemFor({...validConfig(), 'joinTokenTtlSeconds': 30}),
      contains('joinTokenTtlSeconds must be an integer in 60-86400'),
    );
    expect(
      problemFor({
        ...validConfig(),
        'listen': {'port': 80}
      }),
      contains('listen.port must be an integer in 1024-65535'),
    );
  });

  group('publishEvents', () {
    test('absent by default: disabled, nothing asked, nothing published',
        () {
      final config = NodeConfig.fromJson(validConfig());
      expect(config.publishEvents.enabled, isFalse);
      expect(config.publishEvents.gameId, isEmpty);
      expect(config.publishEvents.maxEventsPerMatch, 4);
      expect(config.publishEvents.summaryOnly, isTrue);
    });

    test('parses when enabled and requires a reverse-domain gameId', () {
      final config = NodeConfig.fromJson({
        ...validConfig(),
        'publishEvents': {
          'enabled': true,
          'gameId': 'com.example.golf',
          'maxEventsPerMatch': 2,
          'summaryOnly': false,
        },
      });
      expect(config.publishEvents.enabled, isTrue);
      expect(config.publishEvents.gameId, 'com.example.golf');
      expect(config.publishEvents.maxEventsPerMatch, 2);
      expect(config.publishEvents.summaryOnly, isFalse);

      expect(
        configProblem({
          ...validConfig(),
          'publishEvents': {'enabled': true},
        }),
        contains('publishEvents.gameId is required'),
      );
      expect(
        configProblem({
          ...validConfig(),
          'publishEvents': {'enabled': true, 'gameId': 'not a domain'},
        }),
        contains('publishEvents.gameId must be a reverse-domain id'),
      );
      expect(
        configProblem({
          ...validConfig(),
          'publishEvents': {'enabled': true, 'gameId': 'com.example.golf',
            'maxEventsPerMatch': 500},
        }),
        contains('maxEventsPerMatch must be an integer in 1-50'),
      );
    });

    test('unknown fields are rejected like everywhere else', () {
      expect(
        configProblem({
          ...validConfig(),
          'publishEvents': {'enabled': false, 'wat': 1},
        }),
        contains('Unknown publishEvents field: wat'),
      );
    });
  });

  group('ident (guest identity ladder)', () {
    test('absent by default: the ladder is off', () {
      final config = NodeConfig.fromJson(validConfig());
      expect(config.ident, isNull);
    });

    test('valid block parses with defaults', () {
      final config = NodeConfig.fromJson({
        ...validConfig(),
        'ident': {'pdsUrl': 'https://pds.example.com'},
      });
      final ident = config.ident!;
      expect(ident.pdsUrl, 'https://pds.example.com');
      expect(ident.serviceKey, isNull);
      expect(ident.handleDomain, isNull);
      expect(ident.nonceTtlSeconds, 300);
      expect(ident.sessionTtlSeconds, 2592000);
    });

    test('full block parses; handleDomain and ttls validated', () {
      final config = NodeConfig.fromJson({
        ...validConfig(),
        'ident': {
          'pdsUrl': 'http://127.0.0.1:9',
          'serviceKey': 'svc',
          'handleDomain': 'play.example.com',
          'nonceTtlSeconds': 120,
          'sessionTtlSeconds': 86400,
        },
      });
      expect(config.ident!.handleDomain, 'play.example.com');
      expect(config.ident!.nonceTtlSeconds, 120);

      expect(
        configProblem({
          ...validConfig(),
          'ident': {'pdsUrl': 'ftp://nope'},
        }),
        contains('ident.pdsUrl must be an http(s) URL'),
      );
      expect(
        configProblem({
          ...validConfig(),
          'ident': {
            'pdsUrl': 'https://pds.example.com',
            'handleDomain': 'Not A Domain',
          },
        }),
        contains('ident.handleDomain must be a DNS domain'),
      );
      expect(
        configProblem({
          ...validConfig(),
          'ident': {
            'pdsUrl': 'https://pds.example.com',
            'nonceTtlSeconds': 1,
          },
        }),
        contains('nonceTtlSeconds must be an integer in 60-3600'),
      );
      expect(
        configProblem({
          ...validConfig(),
          'ident': {'pdsUrl': 'https://pds.example.com', 'wat': 1},
        }),
        contains('Unknown ident field: wat'),
      );
    });
  });
}
