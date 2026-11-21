-- Livefire panel platform data, migration 0001 (idempotent).
--
-- Tables and functions for the node's PLATFORM half: panel admins,
-- API keys (hash-only, scoped), usage counters and the audit log.
-- Room RUNTIME state (rooms, peers, join tokens, …) stays in the
-- node's SQLite file and is never stored here.
--
-- Conventions:
-- - panel_-prefixed tables in public,
-- - every RPC is SECURITY DEFINER + locked: REVOKE EXECUTE from
--   anon/authenticated/PUBLIC, GRANT to service_role only — Supabase
--   grants anon/authenticated by default on creation, so a plain
--   REVOKE from PUBLIC alone is insufficient,
-- - the node reaches all of this over PostgREST RPC
--   (POST /rest/v1/rpc/<fn>) through Kong with the stack's service
--   key; tables are never queried directly,
-- - run as supabase_admin, files piped via stdin, idempotent by
--   convention (create if not exists / create or replace), then
--   NOTIFY pgrst, 'reload schema'.

-- Supabase ships these roles; a bare test Postgres does not. Creating
-- them when missing lets the same file run in both places.
do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit;
  end if;
end
$$;

-- ---- Tables --------------------------------------------------------------

create table if not exists public.panel_admins (
  did          text primary key,
  added_by_did text,
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz
);

comment on table public.panel_admins is
  'Livefire panel admins: DIDs allowed into /panel. Seeded once from '
  'node.json adminDids (panel_seed_admins marker), managed from the '
  'panel afterwards.';

create table if not exists public.panel_api_keys (
  id             text primary key,
  label          text not null,
  key_hash       text not null unique,   -- SHA-256 hex of the full key; plaintext never stored
  key_prefix     text not null,
  created_by_did text,
  created_at     timestamptz not null default now(),
  revoked_at     timestamptz,
  max_rooms      integer,                -- null = unlimited
  templates      text[],                 -- null = all templates
  rooms_created  bigint not null default 0,
  tokens_minted  bigint not null default 0,
  constraint panel_api_keys_max_rooms_nonneg
    check (max_rooms is null or max_rooms >= 0)
);

comment on table public.panel_api_keys is
  'Livefire panel-issued API keys (hash-only). Scopes: max_rooms null '
  '= unlimited, templates null = all templates. Bootstrap keys from '
  'node.json apiKeys are NOT rows here — they live in the node only.';

create table if not exists public.panel_audit_log (
  id          bigint generated always as identity primary key,
  ts          timestamptz not null default now(),
  actor_did   text,
  action      text not null,
  target_type text,
  target_id   text,
  details     jsonb not null default '{}'::jsonb
);

comment on table public.panel_audit_log is
  'Livefire panel audit trail: one row per mutating panel action.';

-- One-shot markers (currently: adminDids seeding) so config lists are
-- applied at most once per database; afterwards the DB is the truth.
create table if not exists public.panel_seed (
  key        text primary key,
  seeded_at  timestamptz not null default now()
);

create index if not exists panel_api_keys_hash_idx
  on public.panel_api_keys (key_hash);
create index if not exists panel_audit_log_ts_idx
  on public.panel_audit_log (ts desc, id desc);

-- ---- Functions (all SECURITY DEFINER, RPC-locked below) ------------------

-- Every key row, newest first, as a JSON array (camelCase keys are the
-- wire contract the node's store maps 1:1).
create or replace function public.panel_list_keys()
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    jsonb_agg(t.row order by t.created_at desc, t.id desc),
    '[]'::jsonb)
  from (
    select jsonb_build_object(
        'id', k.id,
        'label', k.label,
        'keyHash', k.key_hash,
        'keyPrefix', k.key_prefix,
        'createdByDid', k.created_by_did,
        'createdAt', k.created_at,
        'revokedAt', k.revoked_at,
        'maxRooms', k.max_rooms,
        'templates', k.templates,
        'roomsCreated', k.rooms_created,
        'tokensMinted', k.tokens_minted
      ) as row,
      k.created_at, k.id
    from public.panel_api_keys k
  ) t;
$$;

-- Creates a key row. The node generates the key material (id, full
-- key, hash, prefix) and sends the hash/prefix only; the plaintext
-- never leaves the node process.
create or replace function public.panel_create_key(
  p_id text,
  p_label text,
  p_key_hash text,
  p_key_prefix text,
  p_created_by_did text,
  p_max_rooms integer default null,
  p_templates text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  created public.panel_api_keys;
begin
  if p_id is null or p_id !~ '^ak_[A-Za-z0-9_-]+$' then
    raise exception 'invalid key id'
      using errcode = '22023';
  end if;
  if coalesce(btrim(p_label), '') = '' or length(p_label) > 64 then
    raise exception 'invalid label'
      using errcode = '22023';
  end if;
  if p_max_rooms is not null and p_max_rooms < 0 then
    raise exception 'max_rooms must be >= 0'
      using errcode = '22023';
  end if;
  insert into public.panel_api_keys
    (id, label, key_hash, key_prefix, created_by_did, max_rooms, templates)
  values
    (p_id, p_label, p_key_hash, p_key_prefix, p_created_by_did, p_max_rooms, p_templates)
  returning * into created;
  return jsonb_build_object(
    'id', created.id,
    'label', created.label,
    'keyHash', created.key_hash,
    'keyPrefix', created.key_prefix,
    'createdByDid', created.created_by_did,
    'createdAt', created.created_at,
    'revokedAt', created.revoked_at,
    'maxRooms', created.max_rooms,
    'templates', created.templates,
    'roomsCreated', created.rooms_created,
    'tokensMinted', created.tokens_minted);
end;
$$;

-- Revokes a key. False for unknown or already-revoked ids.
create or replace function public.panel_revoke_key(p_id text)
returns boolean
language sql
security definer
set search_path = public
as $$
  update public.panel_api_keys
     set revoked_at = now()
   where id = p_id and revoked_at is null
  returning true;
$$;

-- Room-create accounting: enforces the key's scopes atomically and
-- increments rooms_created. Returns {ok:true, roomsCreated} or
-- {ok:false, code:'room_limit'|'template_not_allowed'|'unknown_key'}.
-- The node also checks scopes from its in-memory cache before creating
-- the room; this is the durable, race-free guard behind it.
create or replace function public.panel_consume_room(p_id text, p_template text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.panel_api_keys;
begin
  select * into k from public.panel_api_keys
   where id = p_id and revoked_at is null
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'unknown_key');
  end if;
  if k.max_rooms is not null and k.rooms_created >= k.max_rooms then
    return jsonb_build_object('ok', false, 'code', 'room_limit',
      'maxRooms', k.max_rooms, 'roomsCreated', k.rooms_created);
  end if;
  if k.templates is not null and not (p_template = any (k.templates)) then
    return jsonb_build_object('ok', false, 'code', 'template_not_allowed',
      'template', p_template);
  end if;
  update public.panel_api_keys
     set rooms_created = rooms_created + 1
   where id = p_id
   returning rooms_created into k.rooms_created;
  return jsonb_build_object('ok', true, 'roomsCreated', k.rooms_created);
end;
$$;

-- Token-mint accounting: increments tokens_minted (best-effort).
create or replace function public.panel_consume_token(p_id text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  update public.panel_api_keys
     set tokens_minted = tokens_minted + 1
   where id = p_id
   returning jsonb_build_object('ok', true, 'tokensMinted', tokens_minted);
$$;

-- One-shot seeding of panel_admins from node.json adminDids: inserts
-- the marker row first, so this only ever acts on a fresh database.
-- Existing DIDs (including revoked admins) are never re-added; after
-- seeding the database is the source of truth and the config list is
-- ignored until a fresh database.
create or replace function public.panel_seed_admins(
  p_dids text[],
  p_actor text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.panel_seed (key) values ('admins')
  on conflict (key) do nothing;
  if not found then
    return jsonb_build_object('seeded', false);
  end if;
  insert into public.panel_admins (did, added_by_did)
  select d, p_actor
    from unnest(coalesce(p_dids, '{}'::text[])) as d
  on conflict (did) do nothing;
  return jsonb_build_object('seeded', true, 'dids', coalesce(p_dids, '{}'::text[]));
end;
$$;

-- All admin rows (revoked included; the panel shows history).
create or replace function public.panel_list_admins()
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    jsonb_agg(t.row order by t.revoked_at nulls first, t.created_at, t.did),
    '[]'::jsonb)
  from (
    select jsonb_build_object(
        'did', a.did,
        'addedByDid', a.added_by_did,
        'createdAt', a.created_at,
        'revokedAt', a.revoked_at
      ) as row,
      a.revoked_at, a.created_at, a.did
    from public.panel_admins a
  ) t;
$$;

-- Promotes a DID to admin (re-activating a revoked row when present).
create or replace function public.panel_promote_admin(
  p_did text,
  p_actor text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.panel_admins;
begin
  if p_did is null or p_did !~ '^did:[a-z]+:.+' then
    return jsonb_build_object('ok', false, 'code', 'invalid_did');
  end if;
  insert into public.panel_admins (did, added_by_did)
  values (p_did, p_actor)
  on conflict (did) do update
    set revoked_at = null, added_by_did = excluded.added_by_did
  returning * into a;
  return jsonb_build_object('ok', true,
    'admin', jsonb_build_object(
      'did', a.did,
      'addedByDid', a.added_by_did,
      'createdAt', a.created_at,
      'revokedAt', a.revoked_at));
end;
$$;

-- Revokes an admin. Guards: never yourself, never the last active
-- admin. The advisory lock serializes concurrent revokes so two admins
-- cannot empty the list in one race.
create or replace function public.panel_revoke_admin(
  p_did text,
  p_actor text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.panel_admins;
begin
  perform pg_advisory_xact_lock(hashtext('openfire.panel_admins'));
  if p_did = p_actor then
    return jsonb_build_object('ok', false, 'code', 'self');
  end if;
  select * into a from public.panel_admins
   where did = p_did and revoked_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;
  if (select count(*) from public.panel_admins where revoked_at is null) <= 1 then
    return jsonb_build_object('ok', false, 'code', 'last_admin');
  end if;
  update public.panel_admins set revoked_at = now()
   where did = p_did
   returning * into a;
  return jsonb_build_object('ok', true,
    'admin', jsonb_build_object(
      'did', a.did,
      'addedByDid', a.added_by_did,
      'createdAt', a.created_at,
      'revokedAt', a.revoked_at));
end;
$$;

-- Appends one audit row (one per mutating panel action).
create or replace function public.panel_audit(
  p_actor_did text,
  p_action text,
  p_target_type text default null,
  p_target_id text default null,
  p_details jsonb default null
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.panel_audit_log (actor_did, action, target_type, target_id, details)
  values (p_actor_did, p_action, p_target_type, p_target_id,
          coalesce(p_details, '{}'::jsonb));
$$;

-- Recent audit rows, newest first (limit clamped to 1..500).
create or replace function public.panel_list_audit(p_limit integer default 50)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    jsonb_agg(t.row order by t.ts desc, t.id desc),
    '[]'::jsonb)
  from (
    select jsonb_build_object(
        'id', l.id,
        'ts', l.ts,
        'actorDid', l.actor_did,
        'action', l.action,
        'targetType', l.target_type,
        'targetId', l.target_id,
        'details', l.details
      ) as row,
      l.ts, l.id
    from public.panel_audit_log l
    order by l.ts desc, l.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 500)
  ) t;
$$;

-- ---- RPC locks ------------------------------
-- Supabase grants EXECUTE on new public functions to PUBLIC (hence to
-- anon/authenticated) by default; stripping PUBLIC alone is not enough.
-- Every function above: anon/authenticated/PUBLIC denied, service_role
-- allowed. Tables and sequences: anon/authenticated denied outright
-- (PostgREST would expose them otherwise); the definer functions are
-- the only door in.

revoke execute on function
    public.panel_list_keys(),
    public.panel_create_key(text, text, text, text, text, integer, text[]),
    public.panel_revoke_key(text),
    public.panel_consume_room(text, text),
    public.panel_consume_token(text),
    public.panel_seed_admins(text[], text),
    public.panel_list_admins(),
    public.panel_promote_admin(text, text),
    public.panel_revoke_admin(text, text),
    public.panel_audit(text, text, text, text, jsonb),
    public.panel_list_audit(integer)
  from anon, authenticated, public;

grant execute on function
    public.panel_list_keys(),
    public.panel_create_key(text, text, text, text, text, integer, text[]),
    public.panel_revoke_key(text),
    public.panel_consume_room(text, text),
    public.panel_consume_token(text),
    public.panel_seed_admins(text[], text),
    public.panel_list_admins(),
    public.panel_promote_admin(text, text),
    public.panel_revoke_admin(text, text),
    public.panel_audit(text, text, text, text, jsonb),
    public.panel_list_audit(integer)
  to service_role;

revoke all on table
    public.panel_admins,
    public.panel_api_keys,
    public.panel_audit_log,
    public.panel_seed
  from anon, authenticated, public;

revoke all on sequence public.panel_audit_log_id_seq
  from anon, authenticated, public;
