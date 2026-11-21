#!/usr/bin/env bash
# Contract tests for the panel platform SQL, against a bare local
# PostgreSQL (no Kong/PostgREST needed — role switching with SET ROLE
# is exactly how PostgREST enforces JWT roles).
#
# Requires:
#   TEST_DATABASE_URL  URL of a cluster to create/replace a scratch
#                      database on, e.g.
#                      postgres://postgres@127.0.0.1:15432/postgres
#                      (default: the repo's .pgtest cluster)
#   PSQL               path to a matching psql binary
#                      (default: PATH, then ../.pgtest/bin)
#
# What is covered here (the SQL side; the Dart store's HTTP mapping is
# covered by supabase_store_test.dart):
#   - migration idempotency (applied twice),
#   - RPC locks: anon/authenticated denied (behavioral SET ROLE check,
#     the same thing PostgREST does, plus the catalog view),
#     service_role allowed; tables/sequences locked,
#   - key lifecycle: create (hash-only) / list / revoke / re-revoke,
#   - scope enforcement: panel_consume_room room_limit +
#     template_not_allowed + success ordering, counters,
#   - panel_consume_token accounting,
#   - admin seeding: once-only marker, never re-adds a revoked admin,
#   - promote/revoke guards: self, last_active_admin, not_found,
#   - audit: insert + newest-first listing + details jsonb + limit clamp.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$ROOT")"
TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgres://postgres@127.0.0.1:15432/postgres}"
DBNAME="openfire_panel_contract"

if [ -z "${PSQL:-}" ]; then
  if command -v psql >/dev/null 2>&1; then PSQL="$(command -v psql)";
  elif [ -x "$REPO/.pgtest/bin/psql" ]; then PSQL="$REPO/.pgtest/bin/psql";
  else echo "no psql found (set PSQL=...)" >&2; exit 2; fi
fi

# The scratch database URL: replace the URL path with $DBNAME.
case "$TEST_DATABASE_URL" in
  */*) DBURL="${TEST_DATABASE_URL%/*}/$DBNAME" ;;
  *)   DBURL="$TEST_DATABASE_URL/$DBNAME" ;;
esac

pass=0
fail=0
declare -a failures=()
TMP="$(mktemp -d)"

# expect <description> <expected> <actual>
expect() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    echo "ok   $1"
  else
    fail=$((fail + 1))
    failures+=("$1: expected [$2] got [$3]")
    echo "FAIL $1: expected [$2] got [$3]"
  fi
}

# Run SQL as a role (empty = as the superuser); last stdout line back.
sql() {
  if [ -n "$1" ]; then
    "$PSQL" "$DBURL" -tAq -v ON_ERROR_STOP=0 -c "set role $1; $2" 2>&1
  else
    "$PSQL" "$DBURL" -tAq -v ON_ERROR_STOP=0 -c "$2" 2>&1
  fi
}
value() { sql "" "$1" | tail -n 1; }
denied() {  # <role> <statement> -> "yes" when permission was denied
  case "$(sql "$1" "$2")" in
    *"permission denied"*) echo yes ;;
    *) echo no ;;
  esac
}

echo "== preparing scratch database $DBNAME on ${TEST_DATABASE_URL%%/*}//*"
"$PSQL" "$TEST_DATABASE_URL" -q -c "drop database if exists $DBNAME with (force);" >/dev/null
"$PSQL" "$TEST_DATABASE_URL" -q -c "create database $DBNAME;" || exit 2
# Supabase provisions these roles; create bare equivalents a plain
# cluster lacks so the SET ROLE contract can be exercised.
"$PSQL" "$TEST_DATABASE_URL" -q <<'SQL' || exit 2
do $$ begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit;
  end if;
end $$;
SQL

MIGRATION="$ROOT/migrations/0001_panel_platform.sql"
MIGRATION2="$ROOT/migrations/0002_recovery_keys.sql"
MIGRATION3="$ROOT/migrations/0003_guest_credentials.sql"

echo
echo "== migrations apply cleanly, twice (idempotency)"
"$PSQL" "$DBURL" -v ON_ERROR_STOP=1 -q -f "$MIGRATION" \
  && echo "ok   0001 first apply" || { echo "FAIL 0001 first apply"; exit 1; }
"$PSQL" "$DBURL" -v ON_ERROR_STOP=1 -q -f "$MIGRATION" \
  && echo "ok   0001 second apply (idempotent)" || { echo "FAIL 0001 second apply"; exit 1; }
"$PSQL" "$DBURL" -v ON_ERROR_STOP=1 -q -f "$MIGRATION2" \
  && echo "ok   0002 first apply" || { echo "FAIL 0002 first apply"; exit 1; }
"$PSQL" "$DBURL" -v ON_ERROR_STOP=1 -q -f "$MIGRATION2" \
  && echo "ok   0002 second apply (idempotent)" || { echo "FAIL 0002 second apply"; exit 1; }
"$PSQL" "$DBURL" -v ON_ERROR_STOP=1 -q -f "$MIGRATION3" \
  && echo "ok   0003 first apply" || { echo "FAIL 0003 first apply"; exit 1; }
"$PSQL" "$DBURL" -v ON_ERROR_STOP=1 -q -f "$MIGRATION3" \
  && echo "ok   0003 second apply (idempotent)" || { echo "FAIL 0003 second apply"; exit 1; }

echo
echo "== RPC locks: anon / authenticated denied, service_role allowed"
expect "anon cannot call panel_list_keys"          yes "$(denied anon "select public.panel_list_keys();")"
expect "anon cannot call panel_create_key"         yes "$(denied anon "select public.panel_create_key('ak_x','x','h','p',null,null,null);")"
expect "anon cannot call panel_consume_room"       yes "$(denied anon "select public.panel_consume_room('ak_x','relay');")"
expect "anon cannot call panel_seed_admins"        yes "$(denied anon "select public.panel_seed_admins(array['did:plc:a']);")"
expect "anon cannot call panel_promote_admin"      yes "$(denied anon "select public.panel_promote_admin('did:plc:x');")"
expect "anon cannot call panel_revoke_admin"       yes "$(denied anon "select public.panel_revoke_admin('did:plc:x','did:plc:y');")"
expect "anon cannot call panel_audit"              yes "$(denied anon "select public.panel_audit('did:plc:a','x');")"
expect "anon cannot call panel_list_audit"         yes "$(denied anon "select public.panel_list_audit();")"
expect "anon cannot select panel_api_keys"         yes "$(denied anon "select count(*) from public.panel_api_keys;")"
expect "anon cannot select panel_audit_log"        yes "$(denied anon "select count(*) from public.panel_audit_log;")"
expect "anon cannot insert panel_audit_log"        yes "$(denied anon "insert into public.panel_audit_log (action) values ('x');")"
expect "authenticated cannot call panel_list_keys" yes "$(denied authenticated "select public.panel_list_keys();")"
expect "authenticated cannot call panel_create_key" yes "$(denied authenticated "select public.panel_create_key('ak_x','x','h','p',null,null,null);")"
expect "authenticated cannot call panel_audit"     yes "$(denied authenticated "select public.panel_audit('did:plc:a','x');")"
expect "authenticated cannot select panel_api_keys" yes "$(denied authenticated "select count(*) from public.panel_api_keys;")"
expect "anon cannot call panel_register_recovery_key" yes "$(denied anon "select public.panel_register_recovery_key('did:plc:x','h','{}'::jsonb,true);")"
expect "anon cannot call panel_get_recovery_key"    yes "$(denied anon "select public.panel_get_recovery_key('did:plc:x');")"
expect "anon cannot select recovery_keys"           yes "$(denied anon "select count(*) from public.recovery_keys;")"
expect "authenticated cannot call panel_register_recovery_key" yes "$(denied authenticated "select public.panel_register_recovery_key('did:plc:x','h','{}'::jsonb,true);")"
expect "authenticated cannot select recovery_keys"  yes "$(denied authenticated "select count(*) from public.recovery_keys;")"
expect "anon cannot call panel_upsert_guest_credential" yes "$(denied anon "select public.panel_upsert_guest_credential('did:plc:x','h','p');")"
expect "anon cannot call panel_get_guest_credential"   yes "$(denied anon "select public.panel_get_guest_credential('did:plc:x');")"
expect "anon cannot select guest_credentials"          yes "$(denied anon "select count(*) from public.guest_credentials;")"
expect "authenticated cannot call panel_get_guest_credential" yes "$(denied authenticated "select public.panel_get_guest_credential('did:plc:x');")"
expect "authenticated cannot select guest_credentials" yes "$(denied authenticated "select count(*) from public.guest_credentials;")"
expect "service_role can call panel_list_keys"     '[]' "$(value "select public.panel_list_keys();")"
expect "service_role can call panel_list_admins"   '[]' "$(value "select public.panel_list_admins();")"
expect "service_role can call panel_list_audit"    '[]' "$(value "select public.panel_list_audit();")"
expect "catalog: anon has no EXECUTE on panel_create_key" f \
  "$(value "select has_function_privilege('anon','public.panel_create_key(text,text,text,text,text,integer,text[])','execute');")"
expect "catalog: authenticated has no EXECUTE on panel_consume_room" f \
  "$(value "select has_function_privilege('authenticated','public.panel_consume_room(text,text)','execute');")"
expect "catalog: public has no EXECUTE on panel_audit" f \
  "$(value "select has_function_privilege('public','public.panel_audit(text,text,text,text,jsonb)','execute');")"
expect "catalog: service_role has EXECUTE on panel_create_key" t \
  "$(value "select has_function_privilege('service_role','public.panel_create_key(text,text,text,text,text,integer,text[])','execute');")"
expect "catalog: anon has no EXECUTE on panel_register_recovery_key" f \
  "$(value "select has_function_privilege('anon','public.panel_register_recovery_key(text,text,jsonb,boolean)','execute');")"
expect "catalog: service_role has EXECUTE on panel_get_recovery_key" t \
  "$(value "select has_function_privilege('service_role','public.panel_get_recovery_key(text)','execute');")"

echo
echo "== admin seeding: once-only, never re-adds revoked admins"
expect "first seed reports seeded=true" true \
  "$(value "select public.panel_seed_admins(array['did:plc:admin1','did:plc:admin2'])->>'seeded';")"
expect "second seed is a no-op (seeded=false)" false \
  "$(value "select public.panel_seed_admins(array['did:plc:admin1','did:plc:admin2'])->>'seeded';")"
expect "both admins active" 2 \
  "$(value "select count(*) from public.panel_admins where revoked_at is null;")"
value "select public.panel_revoke_admin('did:plc:admin2','did:plc:admin1');" >/dev/null
expect "re-seeding after a revoke does not re-add it" 0 \
  "$(value "select public.panel_seed_admins(array['did:plc:admin1','did:plc:admin2']); select count(*) from public.panel_admins where did='did:plc:admin2' and revoked_at is null;")"

echo
echo "== promote / revoke guards"
expect "cannot revoke yourself (code=self)" self \
  "$(value "select public.panel_revoke_admin('did:plc:admin1','did:plc:admin1')->>'code';")"
expect "cannot revoke unknown admin (code=not_found)" not_found \
  "$(value "select public.panel_revoke_admin('did:plc:nobody','did:plc:admin1')->>'code';")"
expect "cannot revoke the last active admin (code=last_admin)" last_admin \
  "$(value "select public.panel_revoke_admin('did:plc:admin1','did:plc:admin2')->>'code';")"
expect "promote rejects non-DIDs (code=invalid_did)" invalid_did \
  "$(value "select public.panel_promote_admin('admin.bsky.social')->>'code';")"
expect "promote (re-)activates with ok=true and actor recorded" "did:plc:admin1|true" \
  "$(value "select public.panel_promote_admin('did:plc:admin2','did:plc:admin1'); select format('%s|%s', (select added_by_did from public.panel_admins where did='did:plc:admin2'), (select case when revoked_at is null then 'true' else 'false' end from public.panel_admins where did='did:plc:admin2'));")"
expect "revoke succeeds once there are two admins" true \
  "$(value "select public.panel_revoke_admin('did:plc:admin2','did:plc:admin1')->>'ok';")"
expect "re-revoke is not_found" not_found \
  "$(value "select public.panel_revoke_admin('did:plc:admin2','did:plc:admin1')->>'code';")"

echo
echo "== key lifecycle (hash-only)"
expect "create returns an ak_ id with zero counters and no revoked_at" "ak_|0|0|null" \
  "$(value "select format('%s|%s|%s|%s', left(k.id,3), k.\"roomsCreated\", k.\"tokensMinted\", coalesce(k.\"revokedAt\"::text, 'null')) from jsonb_to_record(public.panel_create_key('ak_game1','game','hash1','sk_ABCDEF12',null,2,array['relay'])) as k(id text, \"roomsCreated\" bigint, \"tokensMinted\" bigint, \"revokedAt\" timestamptz);")"
expect "list shows the key newest first with its scopes" "game|2|relay" \
  "$(value "select format('%s|%s|%s', j->>'label', j->>'maxRooms', j->'templates'->>0) from jsonb_array_elements(public.panel_list_keys()) as j limit 1;")"
expect "no plaintext key material anywhere in the table" 0 \
  "$(value "select count(*) from public.panel_api_keys where id like '%sk_%' or label like '%sk_%' or key_prefix = key_hash;")"
expect "revoke once: true" t \
  "$(value "select public.panel_revoke_key((select id from public.panel_api_keys limit 1));")"
expect "re-revoke: false" f \
  "$(value "select coalesce(public.panel_revoke_key((select id from public.panel_api_keys limit 1)), false);")"
expect "revoked keys no longer consume rooms (unknown_key)" unknown_key \
  "$(value "select public.panel_consume_room((select id from public.panel_api_keys limit 1),'relay')->>'code';")"
expect "duplicate key hashes are rejected by the unique index" "duplicate key value violates unique constraint" \
  "$(sql "" "select public.panel_create_key('ak_dup','dup','hash1','sk_ABCDEF12',null,null,null);" | grep -oE 'duplicate key value violates unique constraint' | head -1 || true)"

echo
echo "== scope enforcement + counters"
KID="$(value "select public.panel_create_key('ak_scoped','scoped','hash2','sk_FEDCBA98','did:plc:admin1',2,array['relay'])->>'id';")"
expect "template outside the key's set is refused" "false|template_not_allowed" \
  "$(value "with r as (select public.panel_consume_room('$KID','physics') as j) select (j->>'ok') || '|' || (j->>'code') from r;")"
expect "first allowed room consumes 1" "true|1" \
  "$(value "with r as (select public.panel_consume_room('$KID','relay') as j) select (j->>'ok') || '|' || (j->>'roomsCreated') from r;")"
expect "second allowed room consumes 2 (== maxRooms)" "true|2" \
  "$(value "with r as (select public.panel_consume_room('$KID','relay') as j) select (j->>'ok') || '|' || (j->>'roomsCreated') from r;")"
expect "third room is over the maxRooms limit" "false|room_limit|2" \
  "$(value "with r as (select public.panel_consume_room('$KID','relay') as j) select (j->>'ok') || '|' || (j->>'code') || '|' || (j->>'roomsCreated') from r;")"
expect "token accounting increments" "true|1" \
  "$(value "with r as (select public.panel_consume_token('$KID') as j) select (j->>'ok') || '|' || (j->>'tokensMinted') from r;")"
UKID="$(value "select public.panel_create_key('ak_unscoped','unscoped','hash3','sk_01234567',null,null,null)->>'id';")"
expect "null scopes mean unlimited rooms (1)" "true|1" \
  "$(value "with r as (select public.panel_consume_room('$UKID','physics') as j) select (j->>'ok') || '|' || (j->>'roomsCreated') from r;")"
expect "null scopes mean all templates (2)" "true|2" \
  "$(value "with r as (select public.panel_consume_room('$UKID','relay') as j) select (j->>'ok') || '|' || (j->>'roomsCreated') from r;")"

echo
echo "== audit log"
expect "audit insert returns nothing" "" \
  "$(value "select public.panel_audit('did:plc:admin1','key.create','api_key','$KID','{\"label\":\"scoped\"}');")"
"$PSQL" "$DBURL" -q -c "select public.panel_audit('did:plc:admin1','key.revoke','api_key','$KID');" >/dev/null
expect "listing is newest first" "key.revoke" \
  "$(value "select public.panel_list_audit()->0->>'action';")"
expect "older entries carry their details jsonb" scoped \
  "$(value "select public.panel_list_audit()->1->'details'->>'label';")"
expect "actor and target round-trip" "did:plc:admin1|$KID" \
  "$(value "select (public.panel_list_audit()->1->>'actorDid') || '|' || (public.panel_list_audit()->1->>'targetId');")"
expect "limit clamps to at least 1" 1 \
  "$(value "select jsonb_array_length(public.panel_list_audit(0));")"

echo
echo "== recovery keys (guest identity ladder, 0002)"
expect "unknown did -> null (empty result)" "$(value "select coalesce(public.panel_get_recovery_key('did:plc:none')::text,'null');")" null
expect "register returns the did" "$(value "select (public.panel_register_recovery_key('did:plc:guest1','hash-1','{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"a\",\"y\":\"b\"}'::jsonb, true)->>'did');")" "did:plc:guest1"
expect "register returns the hash" "$(value "select (public.panel_register_recovery_key('did:plc:guest2','hash-1','{}'::jsonb, true)->>'pubkeyHash');")" "hash-1"
CONFLICT=$(value "select public.panel_register_recovery_key('did:plc:guest1','hash-2','{}'::jsonb, true);")
expect "second register for same did -> null" "$( [ -z "$CONFLICT" ] && echo null || echo "$CONFLICT" )" null
expect "get returns the hash" "$(value "select (public.panel_get_recovery_key('did:plc:guest1')->>'pubkeyHash');")" "hash-1"
expect "get returns the jwk kty" "$(value "select (public.panel_get_recovery_key('did:plc:guest1')->'pubkeyJwk'->>'kty');")" "EC"
expect "guest flag true" "$(value "select (public.panel_get_recovery_key('did:plc:guest1')->>'guest');")" true
expect "guest flag defaults true" "$(value "select (public.panel_get_recovery_key('did:plc:guest1')->>'guest');")" true



echo
echo "== guest credentials (identity ladder, 0003)"
expect "unknown did -> null" "$(value "select coalesce(public.panel_get_guest_credential('did:plc:none')::text,'null');")" null
expect "upsert returns the row" "$(value "select (public.panel_upsert_guest_credential('did:plc:guest1','anon-abc.g','pw-1')->>'password');")" "pw-1"
expect "get returns handle+password" "$(value "select (public.panel_get_guest_credential('did:plc:guest1')->>'handle') || '/' || (public.panel_get_guest_credential('did:plc:guest1')->>'password');")" "anon-abc.g/pw-1"
expect "upsert replaces credentials" "$(value "select (public.panel_upsert_guest_credential('did:plc:guest1','anon-abc.g','pw-2')->>'password');")" "pw-2"
expect "get sees the replacement" "$(value "select (public.panel_get_guest_credential('did:plc:guest1')->>'password');")" "pw-2"

echo
echo "== summary"
echo "passed: $pass  failed: $fail"
if [ "$fail" -gt 0 ]; then
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
