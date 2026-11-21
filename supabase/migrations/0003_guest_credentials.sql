-- 0003 — guest credentials for the guest identity ladder
-- (docs/identity.md → /ident/*, site docs → "Identity ladder").
--
-- Live-confirmed against a stock reference PDS (0.4.5051): guest
-- account creation requires an admin-minted invite code
-- (com.atproto.server.createInviteCode, basic auth admin:<PDS admin
-- password>) and createAccount with {handle, password, inviteCode}.
-- The node generates the password and must PERSIST it — it is the
-- credential for later repo writes as the guest (createSession).
--
-- Same conventions as 0001/0002: camelCase wire rows, SECURITY
-- DEFINER, RPC locks (REVOKE anon/authenticated/
-- PUBLIC, GRANT service_role; table locked too).

create table if not exists public.guest_credentials (
  did        text primary key,
  handle     text not null,
  password   text not null,
  created_at timestamptz not null default now()
);

comment on table public.guest_credentials is
  'Openfire guest identity ladder: the generated app password per '
  'device-account DID — the credential the node uses to write into '
  'the guest repo (createSession). Operator-held secret; see the '
  'trust note in the identity ladder docs.';

-- Upsert: latest credentials win (the node writes as the guest with
-- whatever password created the account it knows).
create or replace function public.panel_upsert_guest_credential(
  p_did text,
  p_handle text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
begin
  insert into public.guest_credentials (did, handle, password)
  values (p_did, p_handle, p_password)
  on conflict (did) do update set
    handle = excluded.handle,
    password = excluded.password,
    created_at = now()
  returning jsonb_build_object(
      'did', guest_credentials.did,
      'handle', guest_credentials.handle,
      'password', guest_credentials.password,
      'createdAt', guest_credentials.created_at
    )
    into v_row;
  return v_row;
end;
$$;

-- The stored credential for a DID, or null.
create or replace function public.panel_get_guest_credential(p_did text)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object(
      'did', c.did,
      'handle', c.handle,
      'password', c.password,
      'createdAt', c.created_at
    )
  from public.guest_credentials c
  where c.did = p_did;
$$;

-- ---- RPC locks (as in 0001/0002) -------------

revoke execute on function
  public.panel_upsert_guest_credential(text, text, text)
  from anon, authenticated, public;
grant execute on function
  public.panel_upsert_guest_credential(text, text, text)
  to service_role;

revoke execute on function public.panel_get_guest_credential(text)
  from anon, authenticated, public;
grant execute on function public.panel_get_guest_credential(text)
  to service_role;

revoke all on public.guest_credentials from anon, authenticated, public;
grant all on public.guest_credentials to service_role;
