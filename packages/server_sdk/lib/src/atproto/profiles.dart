import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:protocol/protocol.dart';

import '../node_store.dart';

/// Room-scoped identity index: `(roomKey, peerId) → DID`, filled by the
/// listener as DID-bearing peers attach, read by the hub roster's
/// `profileOf` closure. Peer ids are only unique per room, so the room key
/// is part of every key.
class RoomIdentityIndex {
  final _byRoom = <String, Map<String, String>>{};

  void set(String roomKey, String peerId, String did) {
    _byRoom.putIfAbsent(roomKey, () => {})[peerId] = did;
  }

  void removePeer(String roomKey, String peerId) {
    final map = _byRoom[roomKey];
    if (map == null) return;
    map.remove(peerId);
    if (map.isEmpty) _byRoom.remove(roomKey);
  }

  void removeRoom(String roomKey) {
    _byRoom.remove(roomKey);
  }

  String? didOf(String roomKey, String peerId) => _byRoom[roomKey]?[peerId];
}

/// Fetches and caches AT Protocol profiles (displayName, avatar) from the
/// user's PDS (`app.bsky.actor.getProfile`), keyed by DID.
///
/// Cache layers: memory (roster lookups are synchronous) → SQLite
/// (`did_profiles`, node-scoped) → the PDS. Entries carry a TTL; a stale
/// entry is refreshed in the background and still served until the fresh
/// one lands.
///
/// **Never blocks a join**: [ensure] is fire-and-forget with all errors
/// swallowed — when the fetch lands, the caller's [RoomHub.refreshRoster]
/// pushes an updated roster to the room.
///
/// Real-world notes:
/// - The fetch is unauthenticated (`app.bsky.actor.getProfile` allows it
///   for public profiles). Authenticated fetch (using the sign-in session)
///   is deferred — the node does not retain OAuth sessions in v0.
/// - `avatar` is the PDS blob URL as-is; clients render it with their own
///   image loader (and same policies they apply to any remote image).
class ProfileService {
  ProfileService({
    required this.store,
    http.Client Function()? httpClientFactory,
    this.ttl = const Duration(hours: 24),
  }) : _httpClientFactory = httpClientFactory ?? http.Client.new;

  final NodeStore store;
  final Duration ttl;
  final http.Client Function() _httpClientFactory;

  final _memory = <String, StoredProfile>{};
  final _inFlight = <String, Future<void>>{};
  static const _maxMemoryEntries = 4096;

  void _cacheMemory(String did, StoredProfile profile) {
    _memory.remove(did);
    if (_memory.length >= _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    _memory[did] = profile;
  }

  /// Synchronous lookup for the hub roster: the cached profile as
  /// `members[].profile` JSON, or null (guests, unknown DIDs, fetch not
  /// landed yet).
  Map<String, dynamic>? profileOf(String did) {
    final cached = _memory[did];
    if (cached != null && !_stale(cached)) return cached.toProfileJson();
    // A stale entry still shows (better than flickering to null) — the
    // refresh scheduled by [ensure] will replace it.
    if (cached != null) return cached.toProfileJson();
    final stored = store.profile(did);
    if (stored != null) {
      _cacheMemory(did, stored);
      return stored.toProfileJson();
    }
    return null;
  }

  bool _stale(StoredProfile profile) =>
      DateTime.now().toUtc().difference(profile.updatedAt) > ttl;

  /// Ensures a profile exists for [did], fetching from [pds] when the
  /// cache is cold or stale. Fire-and-forget: returns immediately, never
  /// throws, calls [hub]'s roster refresh when new data lands.
  void ensure(String did, {String? handle, String? pds, RoomHub? hub}) {
    final fresh = _memory[did] != null && !_stale(_memory[did]!);
    final stored = store.profile(did);
    final haveFresh = fresh || (stored != null && !_stale(stored));
    if (stored != null && _memory[did] == null) _memory[did] = stored;
    if (haveFresh) {
      if (stored?.handle == null && handle != null && stored != null) {
        store.saveProfile(StoredProfile(
          did: did,
          pds: stored.pds,
          handle: handle,
          displayName: stored.displayName,
          avatar: stored.avatar,
          updatedAt: stored.updatedAt,
        ));
      }
      return;
    }
    final origin = pds ?? stored?.pds;
    if (origin == null) return; // nothing to fetch from yet
    if (handle != null) store.saveHandle(handle, did);
    _inFlight.putIfAbsent(did, () {
      final client = _httpClientFactory();
      return _fetch(client, did, origin, handle).whenComplete(() {
        client.close();
        _inFlight.remove(did);
      });
    }).then((_) => hub?.refreshRoster()).catchError((Object _) {});
  }

  Future<void> _fetch(
    http.Client client,
    String did,
    String pdsOrigin,
    String? handle,
  ) async {
    final uri = Uri.parse('$pdsOrigin/xrpc/app.bsky.actor.getProfile')
        .replace(queryParameters: {'actor': did});
    final response = await client
        .get(uri)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return; // keep whatever cache we have
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      return;
    }
    final displayName = body['displayName'];
    final avatar = body['avatar'];
    final profile = StoredProfile(
      did: did,
      pds: pdsOrigin,
      handle: handle ?? (body['handle'] is String ? body['handle'] as String : null),
      displayName: displayName is String && displayName.isNotEmpty
          ? displayName
          : null,
      avatar: avatar is String && avatar.isNotEmpty ? avatar : null,
      updatedAt: DateTime.now().toUtc(),
    );
    store.saveProfile(profile);
    _cacheMemory(did, profile);
  }

  /// Registers the PDS origin a DID authenticated from, so later joins can
  /// refresh profiles without re-resolving (the provider's flow result
  /// carries it; the node forwards it here).
  void notePds(String did, String pds) {
    final existing = _memory[did] ?? store.profile(did);
    if (existing == null) {
      // Remember the PDS even before a profile lands (fetch pending).
      _memory[did] = StoredProfile(
        did: did,
        pds: pds,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      return;
    }
    if (existing.pds != pds) {
      final updated = StoredProfile(
        did: did,
        pds: pds,
        handle: existing.handle,
        displayName: existing.displayName,
        avatar: existing.avatar,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      _memory[did] = updated; // stale: forces a refresh on next ensure
    }
  }

}
