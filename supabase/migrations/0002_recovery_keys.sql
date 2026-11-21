-- 0002 — recovery keys for the guest identity ladder
-- (docs/identity.md → /ident/*, site docs → "Identity ladder").
--
-- Same conventions as 0001_panel_platform.sql:
-- - camelCase JSON keys are the wire contract the Dart store maps 1:1,
-- - every function is SECURITY DEFINER + RPC-locked: REVOKE EXECUTE
--   from anon/authenticated/PUBLIC, GRANT to service_role only — the
--   node reaches them over PostgREST through Kong with the service key,
--   and nothing else can.
--
-- One row per device-account DID: the client-held recovery public key
-- (ES256 JWK). The JWK is public key material, so it is stored as jsonb
-- for verification; pubkey_hash (SHA-256 of the canonical JWK text) is
-- the integrity/display form. `guest` keeps the /ident/device-account
-- namespace distinguishable from upgraded accounts later.

create table if not exists public.recovery_keys (
  did         text primary key,
  pubkey_hash text not null,
  pubkey_jwk  jsonb not null,
  guest       boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint recovery_keys_pubkey_hash_nonempty
    check (length(pubkey_hash) > 0)
);

comment on table public.recovery_keys is
  'Openfire guest identity ladder: the client-held recovery public key '
  'per device-account DID. App-level recovery only — the PDS-level '
  'rotation key stays with the node operator (see the trust note in the '
  'identity ladder docs).';

create index if not exists recovery_keys_created_idx
  on public.recovery_keys (created_at desc);

-- Register a recovery key. Returns the row when inserted, null when the
-- DID already has one (v1: one key per DID, no rotation yet).
create or replace function public.panel_register_recovery_key(
  p_did text,
  p_pubkey_hash text,
  p_pubkey_jwk jsonb,
  p_guest boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
begin
  insert into public.recovery_keys (did, pubkey_hash, pubkey_jwk, guest)
  values (p_did, p_pubkey_hash, p_pubkey_jwk, p_guest)
  on conflict (did) do nothing
  returning jsonb_build_object(
      'did', recovery_keys.did,
      'pubkeyHash', recovery_keys.pubkey_hash,
      'pubkeyJwk', recovery_keys.pubkey_jwk,
      'guest', recovery_keys.guest,
      'createdAt', recovery_keys.created_at
    )
    into v_row;
  return v_row;
end;
$$;

-- The stored recovery key for a DID, or null.
create or replace function public.panel_get_recovery_key(p_did text)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object(
      'did', k.did,
      'pubkeyHash', k.pubkey_hash,
      'pubkeyJwk', k.pubkey_jwk,
      'guest', k.guest,
      'createdAt', k.created_at
    )
  from public.recovery_keys k
  where k.did = p_did;
$$;

-- ---- RPC locks (as in 0001) ------------------

revoke execute on function
  public.panel_register_recovery_key(text, text, jsonb, boolean)
  from anon, authenticated, public;
grant execute on function
  public.panel_register_recovery_key(text, text, jsonb, boolean)
  to service_role;

revoke execute on function public.panel_get_recovery_key(text)
  from anon, authenticated, public;
grant execute on function public.panel_get_recovery_key(text)
  to service_role;

revoke all on public.recovery_keys from anon, authenticated, public;
grant all on public.recovery_keys to service_role;
