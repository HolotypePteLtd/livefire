/// Fail-fast node configuration (`bin/node.dart --config node.json`).
///
/// Everything a self-contained rooms node needs, in one JSON file. The
/// loader rejects unknown fields (the repo-wide config culture) and
/// reports **every** problem before refusing to start.
library;

/// `listen` — where the single HTTP listener binds.
class NodeListen {
  const NodeListen({required this.address, required this.port});
  final String address;
  final int port;
}

/// `auth.atproto` — the AT Protocol OAuth client settings (only read when
/// `auth.providers` includes `atproto`).
class NodeAuthAtproto {
  const NodeAuthAtproto({
    required this.clientName,
    required this.entrywayUrl,
    required this.plcDirectoryUrl,
    required this.jwksPath,
  });

  /// Display name in the OAuth client metadata document.
  final String clientName;

  /// Entryway origin for `com.atproto.identity.resolveHandle`.
  final String entrywayUrl;

  /// PLC directory origin for `did:plc` document lookups.
  final String plcDirectoryUrl;

  /// Path to the node's private EC P-256 JWK file (`tool/gen_client_jwks.dart`
  /// writes one). Only the public half is ever served.
  final String jwksPath;
}

/// `publishEvents` — match events as public records
/// (`docs/match_events.md`). Ships OFF: without the block the node
/// requests only the read-only `atproto` scope at sign-in and publishes
/// nothing. Enabling it requests repo-write scope at sign-in. The game
/// must call the match publisher with the player's consent for each write.
class NodePublishEvents {
  const NodePublishEvents({
    this.enabled = false,
    this.gameId = '',
    this.maxEventsPerMatch = 4,
    this.summaryOnly = true,
  });

  final bool enabled;

  /// Identifies the game in every published record; third parties filter
  /// the public feed on it. Required when enabled.
  final String gameId;

  /// Per-match cap on published events (rate guard, even for milestones).
  final int maxEventsPerMatch;

  /// When true (default) only `matchResult` summaries may be published;
  /// individual `achievement` events require opting out.
  final bool summaryOnly;
}

/// `ident` — the guest identity ladder (`/ident/*`: device accounts +
/// recovery keys, `docs/identity.md`). Absent (the default) = the
/// ladder is off and `/ident*` 404s.
class NodeIdent {
  const NodeIdent({
    required this.pdsUrl,
    this.serviceKey,
    this.handleDomain,
    required this.nonceTtlSeconds,
    required this.sessionTtlSeconds,
  });

  /// The node's PDS origin: guest accounts are created there via the
  /// admin path a stock reference PDS supports (invite code + create).
  final String pdsUrl;

  /// The PDS **admin password** (`PDS_ADMIN_PASSWORD` on the PDS):
  /// basic auth `admin:<serviceKey>` mints the single-use invite code
  /// for each guest account (`com.atproto.server.createInviteCode`).
  /// Required — a stock PDS has no service-level creation mode.
  final String? serviceKey;

  /// Guest handle domain; defaults to the host of `publicBaseUrl`.
  final String? handleDomain;

  /// Recovery challenge nonce lifetime (default 300 s).
  final int nonceTtlSeconds;

  /// Guest session lifetime (default 30 days).
  final int sessionTtlSeconds;
}

/// `auth` — which join-credential providers the node runs.
class NodeAuth {
  const NodeAuth({required this.providers, this.atproto});
  /// `guest` (control-plane-minted join tokens only) and/or `atproto`
  /// (OAuth sign-in mints DID-bearing join tokens).
  final List<String> providers;

  final NodeAuthAtproto? atproto;

  bool get atprotoEnabled => providers.contains('atproto');
}

/// `limits` — node-level ceilings and gate tuning.
class NodeLimits {
  const NodeLimits({
    required this.maxRooms,
    required this.maxReservedCapacity,
    required this.idleTtlSeconds,
    required this.connectionsPerIpPerMinute,
  });

  final int maxRooms;
  final int maxReservedCapacity;
  final int idleTtlSeconds;
  final int connectionsPerIpPerMinute;
}

/// Validated node configuration.
class NodeConfig {
  const NodeConfig({
    required this.listen,
    required this.publicBaseUrl,
    required this.nodeSecret,
    required this.apiKeys,
    required this.dataDir,
    required this.allowedOrigins,
    this.trustedProxies = const [],
    this.adminDids = const [],
    required this.limits,
    required this.joinTokenTtlSeconds,
    required this.physics,
    this.auth = const NodeAuth(providers: ['guest']),
    this.publishEvents = const NodePublishEvents(),
    this.ident,
  });

  static NodeConfig fromJson(Map<String, dynamic> json) {
    final problems = <String>[];
    _only(json, const {
      'listen',
      'publicBaseUrl',
      'nodeSecret',
      'apiKeys',
      'dataDir',
      'allowedOrigins',
      'trustedProxies',
      'adminDids',
      'limits',
      'joinTokenTtlSeconds',
      'physics',
      'auth',
      'publishEvents',
      'ident',
    }, 'config', problems);

    var port = 8787;
    var address = '0.0.0.0';
    final listen = json['listen'];
    if (listen != null) {
      if (listen is! Map) {
        problems.add('listen must be an object');
      } else {
        _only(listen, const {'port', 'address'}, 'listen', problems);
        final rawPort = listen['port'] ?? port;
        // Unprivileged range only: the node runs as a non-root user and
        // TLS terminates at the reverse proxy, never here.
        if (rawPort is! int || rawPort < 1024 || rawPort > 65535) {
          problems.add('listen.port must be an integer in 1024-65535');
        } else {
          port = rawPort;
        }
        final rawAddress = listen['address'] ?? address;
        if (rawAddress is! String || rawAddress.isEmpty) {
          problems.add('listen.address must be a non-empty string');
        } else {
          address = rawAddress;
        }
      }
    }

    final publicBaseUrl = _requiredString(json, 'publicBaseUrl', problems);
    if (publicBaseUrl != null &&
        !publicBaseUrl.startsWith('https://') &&
        !publicBaseUrl.startsWith('http://')) {
      problems.add('publicBaseUrl must start with https:// (or http:// for '
          'local development)');
    }

    final nodeSecret = _requiredString(json, 'nodeSecret', problems);
    if (nodeSecret != null && nodeSecret.length < 16) {
      problems.add('nodeSecret must be at least 16 characters');
    }

    final rawKeys = json['apiKeys'];
    final apiKeys = <String, String>{};
    if (rawKeys is! Map || rawKeys.isEmpty) {
      problems.add('apiKeys must be a non-empty object (name -> key)');
    } else {
      for (final entry in rawKeys.entries) {
        if (entry.key is! String ||
            entry.value is! String ||
            (entry.value as String).length < 8) {
          problems
              .add('apiKeys.${entry.key} must be a string of >= 8 chars');
        } else {
          apiKeys[entry.key as String] = entry.value as String;
        }
      }
    }

    final dataDir = _requiredString(json, 'dataDir', problems);

    final rawOrigins = json['allowedOrigins'] ?? const <String>[];
    final allowedOriginsValid =
        rawOrigins is List && rawOrigins.every((o) => o is String);
    if (!allowedOriginsValid) {
      problems.add('allowedOrigins must be a list of strings');
    }
    final allowedOrigins = allowedOriginsValid
        ? [for (final origin in rawOrigins) origin as String]
        : const <String>[];

    final rawProxies = json['trustedProxies'] ?? const <String>[];
    final trustedProxiesValid = rawProxies is List &&
        rawProxies.every((p) => p is String && p.isNotEmpty);
    if (!trustedProxiesValid) {
      problems.add('trustedProxies must be a list of non-empty strings');
    }
    final trustedProxies = trustedProxiesValid
        ? [for (final proxy in rawProxies) proxy as String]
        : const <String>[];

    final rawAdminDids = json['adminDids'] ?? const <String>[];
    final adminDidsValid = rawAdminDids is List &&
        rawAdminDids.every((d) => d is String && d.startsWith('did:'));
    if (!adminDidsValid) {
      problems.add('adminDids must be a list of DIDs (did:plc:…, did:web:…)');
    }
    final adminDids = adminDidsValid
        ? [for (final did in rawAdminDids) did as String]
        : const <String>[];

    var maxRooms = 256;
    var maxReservedCapacity = 4096;
    var idleTtlSeconds = 300;
    var connectionsPerIpPerMinute = 60;
    final limits = json['limits'];
    if (limits != null) {
      if (limits is! Map) {
        problems.add('limits must be an object');
      } else {
        _only(
          limits,
          const {
            'maxRooms',
            'maxReservedCapacity',
            'idleTtlSeconds',
            'connectionsPerIpPerMinute',
          },
          'limits',
          problems,
        );
        maxRooms = _intIn(limits, 'maxRooms', 1, 100000, 256, problems);
        maxReservedCapacity = _intIn(limits, 'maxReservedCapacity', 1,
            10000000, 4096, problems);
        idleTtlSeconds =
            _intIn(limits, 'idleTtlSeconds', 1, 86400, 300, problems);
        connectionsPerIpPerMinute = _intIn(
            limits, 'connectionsPerIpPerMinute', 1, 100000, 60, problems);
      }
    }

    var joinTokenTtlSeconds = 900;
    final rawTtl = json['joinTokenTtlSeconds'];
    if (rawTtl != null) {
      if (rawTtl is! int || rawTtl < 60 || rawTtl > 86400) {
        problems.add('joinTokenTtlSeconds must be an integer in 60-86400');
      } else {
        joinTokenTtlSeconds = rawTtl;
      }
    }

    var physics = true;
    final rawPhysics = json['physics'];
    if (rawPhysics != null && rawPhysics is! bool) {
      problems.add('physics must be a bool');
    } else if (rawPhysics is bool) {
      physics = rawPhysics;
    }

    var publishEvents = const NodePublishEvents();
    final rawPublish = json['publishEvents'];
    if (rawPublish != null) {
      if (rawPublish is! Map) {
        problems.add('publishEvents must be an object');
      } else {
        _only(rawPublish,
            const {'enabled', 'gameId', 'maxEventsPerMatch', 'summaryOnly'},
            'publishEvents', problems);
        final rawEnabled = rawPublish['enabled'];
        if (rawEnabled != null && rawEnabled is! bool) {
          problems.add('publishEvents.enabled must be a bool');
        }
        final enabled = rawEnabled == true;
        final rawGameId = rawPublish['gameId'];
        if (rawGameId != null &&
            (rawGameId is! String ||
                !RegExp(r'^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$')
                    .hasMatch(rawGameId))) {
          problems.add('publishEvents.gameId must be a reverse-domain id '
              'like com.yourgame');
        }
        if (enabled && rawGameId is! String) {
          problems.add('publishEvents.gameId is required when '
              'publishEvents is enabled');
        }
        final rawSummary = rawPublish['summaryOnly'];
        if (rawSummary != null && rawSummary is! bool) {
          problems.add('publishEvents.summaryOnly must be a bool');
        }
        publishEvents = NodePublishEvents(
          enabled: enabled,
          gameId: rawGameId is String ? rawGameId : '',
          maxEventsPerMatch: _intIn(
              rawPublish, 'maxEventsPerMatch', 1, 50, 4, problems),
          summaryOnly: rawSummary is bool ? rawSummary : true,
        );
      }
    }

    var auth = const NodeAuth(providers: ['guest']);
    final rawAuth = json['auth'];
    if (rawAuth != null) {
      if (rawAuth is! Map) {
        problems.add('auth must be an object');
      } else {
        _only(rawAuth, const {'providers', 'atproto'}, 'auth', problems);
        final rawProviders = rawAuth['providers'];
        if (rawProviders is! List ||
            rawProviders.isEmpty ||
            rawProviders.any((p) => p is! String) ||
            rawProviders.toSet().difference(const {'guest', 'atproto'})
                .isNotEmpty ||
            rawProviders.length != rawProviders.toSet().length) {
          problems.add('auth.providers must be a non-empty list drawn from '
              '[guest, atproto] without duplicates');
        } else {
          final providers = [
            for (final provider in rawProviders) provider as String,
          ];
          NodeAuthAtproto? atproto;
          final rawAtproto = rawAuth['atproto'];
          if (providers.contains('atproto')) {
            if (rawAtproto is! Map) {
              problems.add('auth.atproto is required when the atproto '
                  'provider is enabled');
            } else {
              _only(rawAtproto,
                  const {'clientName', 'entrywayUrl', 'plcDirectoryUrl',
                      'jwksPath'},
                  'auth.atproto', problems);
              final rawName = rawAtproto['clientName'];
              if (rawName != null && rawName is! String) {
                problems.add('auth.atproto.clientName must be a string');
              }
              String? url(String key) {
                final value = rawAtproto[key];
                if (value is! String || Uri.tryParse(value) == null ||
                    !(value.startsWith('https://') ||
                        value.startsWith('http://'))) {
                  problems.add('auth.atproto.$key must be an http(s) URL');
                  return null;
                }
                return value;
              }
              final entryway = url('entrywayUrl');
              final plc = url('plcDirectoryUrl');
              final jwksPath = rawAtproto['jwksPath'];
              if (jwksPath is! String || jwksPath.isEmpty) {
                problems.add('auth.atproto.jwksPath must be a non-empty '
                    'string (generate one with tool/gen_client_jwks.dart)');
              }
              if (entryway != null && plc != null && jwksPath is String) {
                atproto = NodeAuthAtproto(
                  clientName: rawAtproto['clientName'] is String
                      ? rawAtproto['clientName'] as String
                      : 'rooms node',
                  entrywayUrl: entryway,
                  plcDirectoryUrl: plc,
                  jwksPath: jwksPath,
                );
              }
            }
          } else if (rawAtproto != null) {
            problems.add('auth.atproto is set but the atproto provider is '
                'not in auth.providers');
          }
          auth = NodeAuth(
            providers: List.unmodifiable(providers),
            atproto: atproto,
          );
        }
      }
    }

    NodeIdent? ident;
    final rawIdent = json['ident'];
    if (rawIdent != null) {
      if (rawIdent is! Map) {
        problems.add('ident must be an object');
      } else {
        _only(rawIdent, const {'pdsUrl', 'serviceKey', 'handleDomain',
            'nonceTtlSeconds', 'sessionTtlSeconds'}, 'ident', problems);
        final rawPds = rawIdent['pdsUrl'];
        if (rawPds is! String ||
            Uri.tryParse(rawPds) == null ||
            !(rawPds.startsWith('https://') ||
                rawPds.startsWith('http://'))) {
          problems.add('ident.pdsUrl must be an http(s) URL');
        }
        final rawServiceKey = rawIdent['serviceKey'];
        if (rawServiceKey != null && rawServiceKey is! String) {
          problems.add('ident.serviceKey must be a string');
        }
        final rawDomain = rawIdent['handleDomain'];
        if (rawDomain != null &&
            (rawDomain is! String ||
                !RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?'
                        r'(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
                    .hasMatch(rawDomain))) {
          problems.add('ident.handleDomain must be a DNS domain like '
              'play.example.com');
        }
        if (rawPds is String) {
          ident = NodeIdent(
            pdsUrl: rawPds,
            serviceKey: rawServiceKey is String ? rawServiceKey : null,
            handleDomain: rawDomain is String ? rawDomain : null,
            nonceTtlSeconds:
                _intIn(rawIdent, 'nonceTtlSeconds', 60, 3600, 300, problems),
            sessionTtlSeconds: _intIn(
                rawIdent, 'sessionTtlSeconds', 3600, 31536000, 2592000,
                problems),
          );
        }
      }
    }

    if (problems.isNotEmpty) {
      throw FormatException(
        'invalid node config:\n  - ${problems.join('\n  - ')}',
      );
    }
    return NodeConfig(
      listen: NodeListen(address: address, port: port),
      publicBaseUrl: publicBaseUrl!,
      nodeSecret: nodeSecret!,
      apiKeys: Map.unmodifiable(apiKeys),
      dataDir: dataDir!,
      allowedOrigins: List.unmodifiable(allowedOrigins),
      trustedProxies: List.unmodifiable(trustedProxies),
      adminDids: List.unmodifiable(adminDids),
      limits: NodeLimits(
        maxRooms: maxRooms,
        maxReservedCapacity: maxReservedCapacity,
        idleTtlSeconds: idleTtlSeconds,
        connectionsPerIpPerMinute: connectionsPerIpPerMinute,
      ),
      joinTokenTtlSeconds: joinTokenTtlSeconds,
      physics: physics,
      auth: auth,
      publishEvents: publishEvents,
      ident: ident,
    );
  }

  final NodeListen listen;

  /// Public base URL; room URLs derive as `wss://…/play/<roomKey>`.
  final String publicBaseUrl;

  /// HMAC secret for join/creator tokens (>= 16 chars).
  final String nodeSecret;

  /// Service keys by name (v0: static from config; per-game keys later).
  final Map<String, String> apiKeys;

  /// Node data dir (SQLite file lives here).
  final String dataDir;

  /// Origin allowlist; empty allows all (local development).
  final List<String> allowedOrigins;

  /// Reverse-proxy peer IPs trusted to supply `X-Forwarded-For` (`'*'`
  /// trusts any direct proxy). Empty by default.
  final List<String> trustedProxies;

  /// DIDs allowed into the developer panel at `/panel` (sign in with
  /// Bluesky). Empty — the default — disables the panel. The config
  /// `apiKeys` are bootstrap ADMIN keys: always valid for the control
  /// plane, read-only in the panel.
  final List<String> adminDids;

  final NodeLimits limits;

  final int joinTokenTtlSeconds;

  /// Whether the physics template (native movement engine) is wired.
  /// Disable for control-only nodes.
  final bool physics;

  /// Join-credential providers (`docs/identity.md`).
  final NodeAuth auth;

  /// Match events as public records — off by default
  /// (`docs/match_events.md`).
  final NodePublishEvents publishEvents;

  /// Guest identity ladder (`/ident/*`); null when off (the default).
  final NodeIdent? ident;
}

void _only(Map json, Set<String> allowed, String what, List<String> problems) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      problems.add('Unknown $what field: $key');
    }
  }
}

String? _requiredString(
  Map<String, dynamic> json,
  String key,
  List<String> problems,
) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    problems.add('$key is required (non-empty string)');
    return null;
  }
  return value;
}

int _intIn(Map json, String key, int min, int max, int fallback,
    List<String> problems) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is! int || value < min || value > max) {
    problems.add('$key must be an integer in $min-$max');
    return fallback;
  }
  return value;
}
