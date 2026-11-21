# Panel platform data on Supabase

The node's **platform** half — panel admins, API keys (hash-only,
scoped), usage counters, audit log — can live in a Supabase stack (Kong, Postgres, and PostgREST). The room
**runtime** (rooms, peers, join tokens, creator tokens, profiles)
always stays in the node's own SQLite file — the data plane never
waits on Postgres.

## Persistence mode is automatic

| | SQLite mode (default) | Postgres mode |
| --- | --- | --- |
| When | no `SUPABASE_*` env set | `SUPABASE_URL` + `SUPABASE_SECRET_KEY` both set |
| API keys | node's `api_keys` table, unscoped | `panel_api_keys` table, scoped (`maxRooms`, `templates`) |
| Key verification | local SQLite lookup (hash-only) | in-memory cache (30 s TTL + write refresh); SQL is the durable guard |
| Admins | `adminDids` in `node.json` (read-only) | `panel_admins` table; seeded once from `adminDids`, then managed in the panel |
| Admin management / audit log | not available | `/panel` (promote by DID or handle, revoke with guards, audit view) |
| Bootstrap keys (`apiKeys` config) | seeded into SQLite, read-only rows | hashed in node memory only — never Postgres rows, never revocable there |
| Room runtime | SQLite | SQLite (unchanged) |

Behavior in SQLite mode is byte-for-byte the pre-Supabase behavior;
self-hosters who do nothing notice nothing.

## Layout

- `migrations/` — numbered, idempotent SQL. `0001_panel_platform.sql`
  creates the `panel_*` tables, the RPC functions and applies the
  **RPC locks**: every function gets `REVOKE EXECUTE FROM
  anon, authenticated, public` + `GRANT EXECUTE TO service_role`
  (Supabase grants anon/authenticated by default on creation — a
  plain `REVOKE PUBLIC` is not enough), and the tables/sequences are
  locked away from anon/authenticated outright.
- `scripts/apply-migrations.sh` — applies them the stack way: psql
  INSIDE the `supabase-db` container as `supabase_admin`, files piped
  via stdin, `NOTIFY pgrst, 'reload schema'` at the end.
- `contract_test.sh` — proves the SQL semantics (idempotency, RPC
  locks via `SET ROLE` — the same thing PostgREST does — key
  lifecycle, scope enforcement, counters, admin guards, seeding,
  audit) against a bare local PostgreSQL. No Kong needed.

## Testing locally (no Supabase required)

Any PostgreSQL 16 will do (the repo's `.pgtest/` cluster, spun during
development, defaults):

```sh
# start a throwaway cluster if you do not have one
# docker run -d --name pg -p 15432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16

TEST_DATABASE_URL=postgres://postgres@127.0.0.1:15432/postgres \
  ./contract_test.sh
```

What is covered where:

- `contract_test.sh` — the SQL: migration idempotency, RPC locks,
  create/verify/revoke, `panel_consume_room` scope enforcement and
  counters, `panel_consume_token`, seed-once semantics, promote/revoke
  guards (`self`, `last_admin`, `not_found`), audit inserts/listing.
- `packages/server_sdk/test/supabase_store_test.dart` — the store's
  HTTP layer against a PostgREST stub: request shape (path, `apikey` +
  `Authorization` service-key headers, argument names), cache behavior
  (verify without RPCs, TTL refresh, post-write refresh),
  quota authorization and counter writes, guard-code mapping.
- `packages/server_sdk/test/panel_pg_test.dart` — the panel + control
  plane end-to-end in Postgres mode (over the stub): admin management,
  scoped keys enforced at `/v1` (`403 key_room_limit`,
  `403 key_template_not_allowed`), audit rows on every mutation, and
  the SQLite-mode contrast.

## Configure a deployment

1. Apply the migrations to your Supabase PostgreSQL container.

   ```sh
   SUPABASE_DB_CONTAINER=<database-container-name> ./scripts/apply-migrations.sh
   ```

2. Set the node environment variables in your deployment:

   ```
   SUPABASE_URL=https://<kong-domain-of-the-stack>
   SUPABASE_SECRET_KEY=<service-key>
   ```

   Kong accepts the opaque service key in `apikey`/`Authorization`
   and swaps it for the service-role JWT; the node sends it in both
   headers.

3. Restart the node. On the first Postgres-mode boot the config's
   `adminDids` are seeded into `panel_admins` (once — afterwards the
   database is the source of truth and the config list is ignored
   until a fresh database; a revoked admin is never re-added by
   reseeding).

Verify from the box:

```sh
# the RPC is reachable with the service key through Kong
curl -s "$SUPABASE_URL/rest/v1/rpc/panel_list_keys" \
  -H "apikey: $SUPABASE_SECRET_KEY" \
  -H "Authorization: Bearer $SUPABASE_SECRET_KEY" \
  -H 'Content-Type: application/json' -d '{}'
# and locked without it
curl -s -o /dev/null -w '%{http_code}\n' \
  "$SUPABASE_URL/rest/v1/rpc/panel_list_keys" -H 'Content-Type: application/json' -d '{}'
# the locks hold at the SQL level too
docker exec -it "$SUPABASE_DB_CONTAINER" psql -U supabase_admin -d postgres \
  -c "select has_function_privilege('anon','panel_create_key(text,text,text,text,text,integer,text[])','execute') as anon_exec;"
```

Rollback: unset the two env vars and restart — the node returns to
SQLite mode (the Postgres tables stay; nothing in the data plane ever
depended on them).
