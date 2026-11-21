import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:atproto_oauth/atproto_oauth.dart';
import 'package:http/http.dart' as http;
import 'package:server_sdk/server_sdk.dart';

import 'client_keys.dart';
import 'confidential_client.dart';
import 'discovery_client.dart';

/// An in-flight (or completed) atproto sign-in on the node.
///
/// The flow id is opaque and unguessable; `/auth/result?flow=…` hands the
/// minted join token to whoever presents it, so treat it like a bearer
/// secret (same trust level as the join token itself, which is one-time
/// through the ledger).
class AtprotoAuthFlow {
  AtprotoAuthFlow._({
    required this.id,
    required this.roomKey,
    required this.creator,
    required this.panel,
    required this.expiresAt,
  });

  final String id;
  final String roomKey;
  final bool creator;

  /// Panel sign-in (`/panel`): instead of a room join token, the
  /// completed flow mints a `ps_` panel session for the verified DID.
  final bool panel;
  final DateTime expiresAt;

  Uri? authorizationUrl;
  OAuthClient? client;
  http.Client? _httpClient;
  OAuthStateStore? states;
  String? resolvedHandle;

  Map<String, dynamic>? result; // status: ok
  Map<String, dynamic>? error; // status: error
  bool get done => result != null || error != null;

  void _closeHttp() {
    _httpClient?.close();
    _httpClient = null;
  }
}

/// Records the OAuth `state` values a flow creates so `/auth/callback`
/// can route the authorization server's redirect back to its flow.
final class _FlowStateStore implements OAuthStateStore {
  final _contexts = <String, OAuthContext>{};
  void Function(String state)? onNew;

  @override
  Future<void> set(String key, OAuthContext context) async {
    _contexts[key] = context;
    onNew?.call(key);
  }

  @override
  Future<OAuthContext?> find(String key) async => _contexts[key];

  @override
  Future<void> delete(String key) async => _contexts.remove(key);
}

/// The node's atproto auth provider: an OAuth **client** (web/server shape,
/// confidential via `private_key_jwt`) that turns a verified AT Protocol
/// sign-in into a normal node join token whose claims include the DID.
///
/// Surface (served by [RoomsListener]):
/// - `GET /oauth/client.json` — the client metadata document; the
///   `client_id` **is** its URL, per the atproto OAuth profile.
/// - `GET /oauth/jwks.json` — the public half of [keys].
/// - `GET /auth/start?handle=…&room=…&creator=…` — resolve → AS metadata →
///   PAR → authorization URL.
/// - `GET /auth/callback?code&state&iss` — PKCE + DPoP + client-assertion
///   code exchange; extracts the DID from the token response `sub`.
/// - `GET /auth/result?flow=…` — polling endpoint for the client helper.
///
/// In-flight flows live in process memory: a node restart drops them (the
/// user signs in again). `atproto_oauth` verifies `iss` (RFC 9207), PKCE
/// and that `sub` is the DID the flow was started for.
///
/// **Discovery chain** (`atproto_oauth` + `discovery_client.dart`):
/// handle → DID (entryway XRPC) → PDS (DID document) →
/// `GET <PDS>/.well-known/oauth-protected-resource` (RFC 9728) →
/// `authorization_servers[0]` is the authorization server →
/// `GET <AS>/.well-known/oauth-authorization-server` → PAR. Sharded PDS
/// hosts (Bluesky's `*.host.bsky.network`) publish the real AS
/// (`https://bsky.social`) only there; a PDS with no such document is
/// its own AS (self-hosted topology) — [DiscoveryClient] falls back to
/// the PDS origin in that case. `entrywayUrl` stays what it always was:
/// the handle-resolution XRPC endpoint (`atproto_resolver.dart`); it
/// never bypassed AS discovery and still does not — the PDS's own
/// protected-resource declaration wins, so accounts on third-party
/// PDSs keep resolving to their real AS.
class AtprotoAuthProvider {
  AtprotoAuthProvider({
    required this.publicBaseUrl,
    required this.keys,
    required this.tokens,
    required IdentityResolver identityResolver,
    http.Client Function()? httpClientFactory,
    this.clientName = 'rooms node',
    this.flowTtl = const Duration(minutes: 10),
    this.allowPrivateNetwork = false,
    this.repoWriteScope = false,
  }) : _resolver = identityResolver,
       _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// The node's public origin (e.g. `https://rooms.example.com`) — the
  /// base for the client metadata document and the OAuth redirect URI.
  /// Production authorization servers require https here. Assign once at
  /// boot if the port is not known at construction (the listener must be
  /// bound before flows start).
  String publicBaseUrl;

  /// When true (node config `publishEvents.enabled`), sign-in requests the
  /// repo-write scope (`atproto repo`) so match events can be published to
  /// the player's repo (`match_events.dart`). Off by default: sessions stay
  /// read-only identity grants, and the wider scope is only ever requested
  /// when the node operator explicitly enabled publishing. The
  /// authorization server still shows the player what is being asked; per
  /// event, the publisher additionally requires the player's consent.
  final bool repoWriteScope;

  /// Private ES256 key (JWKS at `/oauth/jwks.json`); signs client
  /// assertions for confidential token requests.
  final NodeClientKeys keys;

  /// Mints the DID-bearing join/creator tokens handed out by `/auth/result`.
  final JoinTokens tokens;

  final IdentityResolver _resolver;
  final http.Client Function() _httpClientFactory;
  final String clientName;
  final Duration flowTtl;
  final bool allowPrivateNetwork;

  final _flows = <String, AtprotoAuthFlow>{};
  final _flowsByState = <String, AtprotoAuthFlow>{};

  /// Resolves a handle (or DID) through the node's configured identity
  /// resolver — the panel uses it to turn a typed handle into a DID
  /// when promoting an admin.
  Future<ResolvedIdentity> resolveIdentity(String input) =>
      _resolver.resolve(input);

  /// DID → PDS origin learned at sign-in, for profile prefetches (bounded).
  final _pdsByDid = <String, String>{};
  static const _maxRetainedPds = 4096;

  void _recordPds(String did, String pds) {
    _pdsByDid.remove(did);
    if (_pdsByDid.length >= _maxRetainedPds) {
      _pdsByDid.remove(_pdsByDid.keys.first);
    }
    _pdsByDid[did] = pds;
  }

  /// DID → OAuth session, retained **only** when [repoWriteScope] is on,
  /// so match events can be published to the player's repo later
  /// (`match_events.dart`). Memory-only and small (bounded below): a node
  /// restart drops them and affected players simply sign in again. Never
  /// populated in the default read-only mode — those sessions stay
  /// single-purpose (identity) and are discarded, as before.
  final _sessionsByDid = <String, OAuthSession>{};
  static const _maxRetainedSessions = 64;

  /// The retained write-capable session for [did], or null when the node
  /// runs read-only (the default) or the player signed in before the
  /// flag was enabled.
  OAuthSession? sessionFor(String did) => _sessionsByDid[did];

  /// The PDS origin [did] last authenticated from, or null.
  String? pdsOf(String did) => _pdsByDid[did];

  String get clientId => '$publicBaseUrl/oauth/client.json';

  /// The client metadata document (atproto OAuth profile, web client).
  Map<String, dynamic> clientMetadata() => {
    'client_id': clientId,
    'client_name': clientName,
    'application_type': 'web',
    'client_uri': publicBaseUrl,
    'redirect_uris': ['$publicBaseUrl/auth/callback'],
    'grant_types': const ['authorization_code', 'refresh_token'],
    'response_types': const ['code'],
    'scope': repoWriteScope ? 'atproto repo' : 'atproto',
    'token_endpoint_auth_method': 'private_key_jwt',
    // REQUIRED by the atproto OAuth spec for private_key_jwt clients;
    // bsky.social rejects PAR without it (invalid_client_metadata).
    // Must match the JWKS key algorithm (ES256 P-256 keys).
    'token_endpoint_auth_signing_alg': 'ES256',
    'jwks_uri': '$publicBaseUrl/oauth/jwks.json',
    'dpop_bound_access_tokens': true,
  };

  Map<String, dynamic> publicJwks() => keys.publicJwks();

  bool _expired(AtprotoAuthFlow flow) =>
      DateTime.now().toUtc().isAfter(flow.expiresAt);

  void _dropExpired() {
    _flows.removeWhere((_, flow) {
      if (!_expired(flow)) return false;
      flow._closeHttp();
      flow.client = null;
      flow.states = null;
      return true;
    });
    _flowsByState.removeWhere((_, flow) => _expired(flow));
  }

  /// Resolves the handle and pushes the authorization request. Throws
  /// [OAuthException]/[IdentityException] with an operator-safe message on
  /// failure (unknown handle, unreachable PDS, PAR rejected).
  ///
  /// [panel] starts a panel sign-in (no room binding; the completed flow
  /// mints a `ps_` session token instead of a join token).
  Future<AtprotoAuthFlow> start({
    required String handle,
    String roomKey = '',
    bool creator = false,
    bool panel = false,
  }) async {
    _dropExpired();
    final flow = AtprotoAuthFlow._(
      id: _flowId(),
      roomKey: roomKey,
      creator: creator,
      panel: panel,
      expiresAt: DateTime.now().toUtc().add(flowTtl),
    );
    final states = flow.states = _FlowStateStore()
      ..onNew = (state) {
        if (_flowsByState[state] == null) _flowsByState[state] = flow;
      };
    // The full atproto discovery chain rides this client:
    // handle → DID → PDS → protected-resource hop (with the PDS-as-AS
    // fallback for single-server deployments, `discovery_client.dart`)
    // → AS metadata → PAR. See the class doc.
    final inner = DiscoveryClient(_httpClientFactory());
    flow._httpClient = inner;
    final client = OAuthClient(
      OAuthClientMetadata.fromJson(clientMetadata()),
      httpClient: ConfidentialClient(
        keys: keys,
        clientId: clientId,
        inner: inner,
      ),
      identityResolver: _resolver,
      stateStore: states,
      allowPrivateNetwork: allowPrivateNetwork,
    );
    flow.client = client;
    try {
      flow.authorizationUrl = await client.authorize(handle.trim());
    } catch (_) {
      flow._closeHttp();
      _flowsByState.removeWhere((_, f) => identical(f, flow));
      rethrow;
    }
    flow.resolvedHandle = handle.trim();
    _flows[flow.id] = flow;
    return flow;
  }

  /// Handles the authorization server's redirect: code exchange with PKCE
  /// (+ DPoP and the client assertion). Returns the flow on success, null
  /// when the state is unknown/expired. On exchange failure the flow is
  /// terminal (error result) — retrying needs a new `/auth/start`.
  Future<AtprotoAuthFlow?> complete(Uri callbackUri) async {
    final state = callbackUri.queryParameters['state'];
    if (state == null) return null;
    final flow = _flowsByState[state];
    if (flow == null || flow.done || _expired(flow)) return null;
    try {
      final session = await flow.client!.callback(callbackUri.toString());
      if (flow.panel) {
        flow.result = {
          'status': 'ok',
          'session': tokens.mintPanelSession(
            session.sub,
            handle: flow.resolvedHandle,
          ),
          'did': session.sub,
          'handle': flow.resolvedHandle,
        };
        _recordPds(session.sub, session.pds);
        return flow;
      }
      final mintedAt = DateTime.now().toUtc();
      final expiresAt = mintedAt.add(tokens.defaultTtl);
      final joinToken = tokens.mintJoin(
        flow.roomKey,
        now: mintedAt,
        did: session.sub,
        handle: flow.resolvedHandle,
      );
      _recordPds(session.sub, session.pds);
      if (repoWriteScope) {
        if (_sessionsByDid.length >= _maxRetainedSessions &&
            !_sessionsByDid.containsKey(session.sub)) {
          _sessionsByDid.remove(_sessionsByDid.keys.first);
        }
        _sessionsByDid[session.sub] = session;
      }
      String? creatorToken;
      if (flow.creator) {
        creatorToken = tokens.mintCreator(
          flow.roomKey,
          now: mintedAt,
          did: session.sub,
        );
      }
      flow.result = {
        'status': 'ok',
        'joinToken': joinToken,
        'joinTokenExpiresAt': expiresAt.toIso8601String(),
        'did': session.sub,
        'handle': flow.resolvedHandle,
        'roomKey': flow.roomKey,
        'url': '${_playUrl(flow.roomKey, joinToken)}',
        'creatorToken': ?creatorToken,
        'pds': session.pds,
      };
    } on OAuthException catch (error) {
      flow.error = {
        'code': 'auth_failed',
        // OAuthException messages never carry token bodies (the library
        // scrubs them), but stay defensive anyway.
        'message': error.message.length > 200
            ? 'Authorization failed.'
            : error.message,
      };
    } catch (_) {
      flow.error = {
        'code': 'auth_failed',
        'message': 'Authorization failed.',
      };
    } finally {
      flow._closeHttp();
      flow.client = null;
      flow.states = null;
    }
    return flow;
  }

  /// The polling result: `pending` (null), a completed credential map, or
  /// a terminal error map.
  Map<String, dynamic>? result(String flowId) {
    final flow = _flows[flowId];
    if (flow == null || _expired(flow)) {
      return {
        'status': 'error',
        'error': {'code': 'not_found', 'message': 'unknown or expired flow'},
      };
    }
    if (flow.result != null) return flow.result;
    if (flow.error != null) {
      return {'status': 'error', 'error': flow.error};
    }
    return null;
  }

  Uri _playUrl(String roomKey, String joinToken) {
    final base = Uri.parse(publicBaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/play/$roomKey',
      queryParameters: {'token': joinToken},
    );
  }

  static String _flowId() {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(18, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }
}
