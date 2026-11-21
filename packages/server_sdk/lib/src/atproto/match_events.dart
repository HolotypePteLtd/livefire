import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:atproto_oauth/atproto_oauth.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import '../sqlite_database.dart';

/// Match events as public records — the write side of
/// `docs/match_events.md`. A record published to a player's atproto
/// account (`com.openfire.matchEvent`) flows to the public feed by itself;
/// subscribers filter on the collection and the `gameId` field.
///
/// Granularity is the contract: milestones, not telemetry. `matchResult`
/// summaries batch a match's stats into one record; `achievement` records
/// mark single milestones and need `summaryOnly: false`. Nothing here
/// publishes per-tick or per-action events, and the per-match cap holds
/// even when the caller misbehaves.
///
/// Guardrails, in the order they run:
/// 1. [MatchEventSettings.enabled] — the node config gate. Ships false.
/// 2. `playerConsented` — per event, per player. The recommended client
///    wording is one plain sentence shown before sign-in asks for the
///    write scope: "Publish your achievements and match results to your
///    Bluesky account?"
/// 3. The session must actually carry the `repo` scope — a read-only
///    identity session is never enough, whatever the config says.
/// 4. Rate limit: at most `maxEventsPerMatch` events per match id.
/// 5. Payload size cap (2 KiB encoded) — large artifacts are referenced
///    by pointer, never inlined (replays do not fit; see the design doc).
///
/// Deletion is first-class: [deleteMatchEvent] removes a record and treats
/// "already gone" as success — the delete is itself an event on the public
/// feed, and consumers must respect removal.
///
/// What this slice does NOT do (documented stubs):
/// - **Server-account publishing** (`publishMatchEventFromServiceAccount`)
///   is not implemented. It needs a long-lived service-account OAuth
///   session on the node (its own DID, its own DPoP keys, refresh
///   plumbing) — bigger than this slice. Until it exists, match-level
///   records publish only through a consenting player's session.
/// - **Session refresh on publish.** Retained sessions are used as-is
///   (`AtprotoAuthProvider.sessionFor`); if the access token has expired,
///   publishing fails with an operator-safe error and the player signs in
///   again. Refresh plumbing rides with the service-account work.
/// - The **feed side** (subscribing, leaderboards) stays a documented
///   future use; this module only writes.
final class MatchEventPublisher {
  MatchEventPublisher({
    required this.settings,
    http.Client Function()? httpClientFactory,
    this.clock = _systemClock,
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new;

  /// Node-level settings (from `publishEvents` in `node.json`).
  final MatchEventSettings settings;

  final http.Client Function() _httpClientFactory;
  final DateTime Function() clock;

  /// The record collection. Third parties filter the public feed on it,
  /// then on `gameId` for a specific game.
  static const collection = 'com.openfire.matchEvent';

  /// Encoded payload cap — milestones are small; big artifacts are
  /// pointers.
  static const maxPayloadBytes = 2 * 1024;

  static const _maxNonceRetries = 2;

  // SQLite removes this temporary database when the publisher is collected
  // or closed. Counts survive for the lifetime of the publisher, with a
  // bounded page cache even when the number of match IDs grows.
  Database? _matchCounts;
  bool _closed = false;

  Database get _counts => _matchCounts ??= openSqliteDatabase('')
    ..execute('PRAGMA cache_size = -256;')
    ..execute('''
      CREATE TABLE match_events (
        match_id TEXT PRIMARY KEY,
        reserved INTEGER NOT NULL
      ) WITHOUT ROWID;
    ''');

  /// Releases the temporary match counter database.
  void close() {
    _closed = true;
    _matchCounts?.dispose();
    _matchCounts = null;
  }

  void _reserveEvent(String matchId) {
    final limit = settings.maxEventsPerMatch;
    final counts = _counts;
    counts.execute(
      '''
      INSERT INTO match_events (match_id, reserved)
      SELECT ?, 1 WHERE ? > 0
      ON CONFLICT (match_id) DO UPDATE SET reserved = reserved + 1
      WHERE reserved < ?;
    ''',
      [matchId, limit, limit],
    );
    if (counts.updatedRows == 0) {
      throw StateError(
        'Match $matchId has reached the per-match cap '
        'of $limit events (including pending writes).',
      );
    }
  }

  /// Publishes one match event to the player's repo. Returns the record's
  /// location (rkey + uri + cid), or null when a guard declined the write
  /// (publishing disabled, or the player did not consent) — a declined
  /// event is a normal outcome, not an error.
  ///
  /// Throws [StateError]/[FormatException] with operator-safe messages on
  /// hard rule violations (no repo scope, summaryOnly, rate cap, payload
  /// too large) and on PDS rejection.
  Future<MatchEventRecord?> publishMatchEvent({
    required OAuthSession session,
    required String eventType,
    required String matchId,
    required String playerId,
    Map<String, dynamic> payload = const {},
    bool playerConsented = false,
  }) async {
    if (_closed) throw StateError('Match event publisher is closed.');
    if (!settings.enabled || !playerConsented) return null;
    if (!session.scope.split(' ').contains('repo')) {
      throw StateError(
        'This sign-in does not allow publishing '
        '(the repo scope was not granted).',
      );
    }
    if (eventType != 'matchResult' && eventType != 'achievement') {
      throw const FormatException(
        'eventType must be "matchResult" or "achievement".',
      );
    }
    if (settings.summaryOnly && eventType != 'matchResult') {
      throw StateError(
        'This node publishes match summaries only '
        '(publishEvents.summaryOnly).',
      );
    }
    if (matchId.isEmpty || matchId.length > 128) {
      throw const FormatException('matchId must be 1-128 characters.');
    }
    final encoded = utf8.encode(jsonEncode(payload));
    if (encoded.length > maxPayloadBytes) {
      throw StateError(
        'Event payload is too large '
        '(over $maxPayloadBytes bytes encoded); reference big artifacts '
        'by pointer instead.',
      );
    }
    final rkey = _rkey();
    final record = <String, dynamic>{
      '\$type': collection,
      'eventType': eventType,
      'matchId': matchId,
      'gameId': settings.gameId,
      'playerId': playerId,
      'payload': payload,
      'timestamp': clock().toUtc().toIso8601String(),
    };
    final body = <String, dynamic>{
      'repo': session.sub,
      'collection': collection,
      'rkey': rkey,
      'record': record,
    };
    final endpoint = Uri.parse(
      '${session.pds}/xrpc/com.atproto.repo.createRecord',
    );
    // Reserve before awaiting the PDS so simultaneous calls share the cap.
    _reserveEvent(matchId);
    final response = await _dpopPost(session, endpoint, body);
    if (response.statusCode != 200) {
      // A confirmed client error permits a retry. A transport error or
      // server failure can occur after the PDS has created the record.
      if (!_closed && response.statusCode >= 400 && response.statusCode < 500) {
        final counts = _counts;
        counts.execute(
          'UPDATE match_events SET reserved = reserved - 1 WHERE match_id = ?;',
          [matchId],
        );
        counts.execute(
          'DELETE FROM match_events WHERE match_id = ? AND reserved = 0;',
          [matchId],
        );
      }
      throw StateError(
        'The record server rejected the event '
        '(HTTP ${response.statusCode}).',
      );
    }
    final json = _tryDecode(response.body);
    final uri = json is Map ? json['uri'] as String? : null;
    final cid = json is Map ? json['cid'] as String? : null;
    if (uri == null || cid == null) {
      throw StateError('The record server returned no record location.');
    }
    return MatchEventRecord(rkey: rkey, uri: uri, cid: cid);
  }

  /// Removes a published event. Deleting an already-deleted (or never
  /// existing) record is a success — the player may have removed it
  /// themselves, and that removal must be respected, not fought.
  Future<void> deleteMatchEvent({
    required OAuthSession session,
    required String rkey,
  }) async {
    if (_closed) throw StateError('Match event publisher is closed.');
    if (!session.scope.split(' ').contains('repo')) {
      throw StateError(
        'This sign-in does not allow publishing '
        '(the repo scope was not granted).',
      );
    }
    final response = await _dpopPost(
      session,
      Uri.parse('${session.pds}/xrpc/com.atproto.repo.deleteRecord'),
      <String, dynamic>{
        'repo': session.sub,
        'collection': collection,
        'rkey': rkey,
      },
    );
    if (response.statusCode != 200 && response.statusCode != 404) {
      throw StateError('The record server rejected the delete '
          '(HTTP ${response.statusCode}).');
    }
  }

  /// One DPoP-signed JSON POST to the PDS, with `use_dpop_nonce` retry
  /// (RFC 9449), mirroring the atproto_oauth client's own token requests.
  /// The proof binds method, URI and the access token (`ath`), so a
  /// replayed proof cannot authorize anything else.
  Future<http.Response> _dpopPost(
    OAuthSession session,
    Uri endpoint,
    Map<String, dynamic> body,
  ) async {
    final client = _httpClientFactory();
    try {
      // RFC 9449 §4.2: `htu` excludes query and fragment.
      final htu = endpoint
          .replace(queryParameters: const {}, fragment: '')
          .toString();
      String? nonce = _nonces[endpoint.origin];
      http.Response response;
      for (var attempt = 0;; attempt++) {
        final proof = getDPoPHeader(
          clientId: session.clientId,
          endpoint: htu,
          method: 'POST',
          dPoPNonce: nonce,
          accessToken: session.accessToken,
          publicKey: session.dpopPublicKey,
          privateKey: session.dpopPrivateKey,
        );
        response = await client.post(
          endpoint,
          headers: {
            'Authorization': 'DPoP ${session.accessToken}',
            'DPoP': proof,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        );
        final nextNonce = response.headers['dpop-nonce'];
        if (nextNonce != null) _setNonce(endpoint.origin, nextNonce);
        final json = _tryDecode(response.body);
        final isNonceError =
            (response.statusCode == 400 || response.statusCode == 401) &&
            json is Map &&
            json['error'] == 'use_dpop_nonce' &&
            nextNonce != null &&
            nextNonce != nonce;
        if (!isNonceError || attempt >= _maxNonceRetries) break;
        nonce = nextNonce;
      }
      return response;
    } finally {
      client.close();
    }
  }

  static const _maxTrackedNonces = 1024;
  final _nonces = <String, String>{};

  void _setNonce(String origin, String nonce) {
    _nonces.remove(origin);
    if (_nonces.length >= _maxTrackedNonces) {
      _nonces.remove(_nonces.keys.first);
    }
    _nonces[origin] = nonce;
  }

  /// atproto-style rkey: sortable, unique enough for events.
  static String _rkey() {
    final random = Random.secure();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${base64Url.encode(List.generate(6, (_) => random.nextInt(256))).replaceAll('=', '')}';
  }

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

/// The `publishEvents` block of `node.json`, as seen by the publisher.
/// The node package parses and validates the raw config; this is the
/// validated view handed to [MatchEventPublisher].
class MatchEventSettings {
  const MatchEventSettings({
    this.enabled = false,
    this.gameId = '',
    this.maxEventsPerMatch = 4,
    this.summaryOnly = true,
  });

  final bool enabled;
  final String gameId;
  final int maxEventsPerMatch;
  final bool summaryOnly;
}

/// Where a published event landed.
class MatchEventRecord {
  const MatchEventRecord({required this.rkey, required this.uri, required this.cid});

  /// The record key within the collection (used for deletes).
  final String rkey;

  /// Full `at://` uri as returned by the PDS.
  final String uri;

  /// Content id of the written record.
  final String cid;
}

DateTime _systemClock() => DateTime.now().toUtc();
