-- M0b tenancy: organizations, users, memberships, portfolios, RLS helpers and policies.
-- Model: docs/DOMAIN.md §3.1. Security: docs/ARCHITECTURE.md §5, ADR-0011.
--
-- Tenant = servicer organization (Collectoo). Client organizations (creditors, later funds)
-- belong to one servicer. Internal staff read their servicer's data only at MFA level aal2.
-- Client users read their own organization's portfolios. Anonymous users read nothing.

------------------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------------------

create table public.organization (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in (
    'servicer', 'creditor_client', 'fund', 'fct', 'management_company', 'depositary')),
  servicer_organization_id uuid references public.organization (id),
  legal_name text not null check (length(btrim(legal_name)) > 0),
  siren text check (siren ~ '^[0-9]{9}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_servicer_is_root
    check ((kind = 'servicer') = (servicer_organization_id is null))
);
create index organization_servicer_idx on public.organization (servicer_organization_id);
comment on table public.organization is
  'Servicer (tenant) and the organizations it serves: creditor clients, later funds/FCTs.';

create table public.app_user (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.app_user is 'Profile of an auth user (staff or client user).';

create table public.membership (
  user_id uuid not null references public.app_user (id) on delete cascade,
  organization_id uuid not null references public.organization (id) on delete cascade,
  role text not null check (role in (
    'admin', 'ops_manager', 'collector', 'client_admin', 'client_viewer')),
  created_at timestamptz not null default now(),
  primary key (user_id, organization_id)
);
create index membership_org_idx on public.membership (organization_id);

create table public.portfolio (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  name text not null check (length(btrim(name)) > 0),
  default_claim_type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (client_organization_id, name)
);
create index portfolio_org_idx on public.portfolio (organization_id);
create index portfolio_client_org_idx on public.portfolio (client_organization_id);
comment on column public.portfolio.organization_id is 'Servicer tenant that services the portfolio.';

-- Optional narrowing: a user with at least one row here sees only those portfolios.
create table public.portfolio_access (
  user_id uuid not null references public.app_user (id) on delete cascade,
  portfolio_id uuid not null references public.portfolio (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, portfolio_id)
);
create index portfolio_access_portfolio_idx on public.portfolio_access (portfolio_id);

-- Idempotency for command functions (BRIEF §7).
create table private.command_log (
  command text not null,
  idempotency_key text not null check (length(idempotency_key) between 8 and 200),
  actor_id uuid,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (command, idempotency_key)
);

create trigger organization_touch before update on public.organization
  for each row execute function private.touch_updated_at();
create trigger app_user_touch before update on public.app_user
  for each row execute function private.touch_updated_at();
create trigger portfolio_touch before update on public.portfolio
  for each row execute function private.touch_updated_at();

------------------------------------------------------------------------------------------
-- Integrity triggers (cross-row rules a CHECK cannot express)
------------------------------------------------------------------------------------------

-- Internal roles only in a servicer; client roles only in a client-side organization.
create or replace function private.check_membership_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_kind text;
begin
  select kind into v_kind from public.organization where id = new.organization_id;
  if v_kind = 'servicer' and new.role not in ('admin', 'ops_manager', 'collector') then
    raise exception 'role % is not allowed in a servicer organization', new.role
      using errcode = 'check_violation';
  end if;
  if v_kind <> 'servicer' and new.role not in ('client_admin', 'client_viewer') then
    raise exception 'role % is only allowed in a servicer organization', new.role
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger membership_role_check before insert or update on public.membership
  for each row execute function private.check_membership_role();

-- A portfolio is serviced by a servicer, for one of that servicer's client organizations.
create or replace function private.check_portfolio_orgs()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.organization where id = new.organization_id and kind = 'servicer'
  ) then
    raise exception 'portfolio.organization_id must be a servicer' using errcode = 'check_violation';
  end if;
  if not exists (
    select 1 from public.organization
    where id = new.client_organization_id and servicer_organization_id = new.organization_id
  ) then
    raise exception 'client organization does not belong to this servicer'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger portfolio_orgs_check before insert or update on public.portfolio
  for each row execute function private.check_portfolio_orgs();

-- Profile row for every auth user.
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.app_user (id, email) values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;
create trigger on_auth_user_created after insert or update of email on auth.users
  for each row execute function private.handle_new_auth_user();

------------------------------------------------------------------------------------------
-- RLS helpers (SECURITY DEFINER so they can read membership without recursion;
-- search_path pinned; they read tables, not JWT claims, so revocation is immediate)
------------------------------------------------------------------------------------------

create or replace function private.is_aal2()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false);
$$;

-- Servicer organizations where the caller is internal staff, only at aal2.
create or replace function private.staff_org_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.organization_id), '{}')
  from public.membership m
  join public.organization o on o.id = m.organization_id and o.kind = 'servicer'
  where m.user_id = (select auth.uid())
    and (select private.is_aal2());
$$;

-- Client-side organizations where the caller is a member.
create or replace function private.client_org_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.organization_id), '{}')
  from public.membership m
  join public.organization o on o.id = m.organization_id and o.kind <> 'servicer'
  where m.user_id = (select auth.uid());
$$;

-- True if the caller has one of the roles in the organization (staff roles need aal2).
create or replace function private.has_role(p_organization_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.membership m
    join public.organization o on o.id = m.organization_id
    where m.user_id = (select auth.uid())
      and m.organization_id = p_organization_id
      and m.role = any (p_roles)
      and (o.kind <> 'servicer' or (select private.is_aal2()))
  );
$$;

create or replace function private.can_read_org(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_organization_id = any (private.client_org_ids())
      or p_organization_id = any (private.staff_org_ids())
      or exists (
        select 1 from public.organization o
        where o.id = p_organization_id
          and o.servicer_organization_id = any (private.staff_org_ids())
      );
$$;

create or replace function private.can_read_portfolio(p_portfolio_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.portfolio p
    where p.id = p_portfolio_id
      and (
        p.organization_id = any (private.staff_org_ids())
        or p.client_organization_id = any (private.client_org_ids())
      )
      and (
        not exists (select 1 from public.portfolio_access a where a.user_id = (select auth.uid()))
        or exists (
          select 1 from public.portfolio_access a
          where a.user_id = (select auth.uid()) and a.portfolio_id = p.id
        )
      )
  );
$$;

-- Who may see a membership row or a user profile: oneself, admins of that client
-- organization, and staff of the servicer (aal2).
create or replace function private.can_see_members_of(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select private.has_role(p_organization_id, array['client_admin']))
      or p_organization_id = any (private.staff_org_ids())
      or exists (
        select 1 from public.organization o
        where o.id = p_organization_id
          and o.servicer_organization_id = any (private.staff_org_ids())
      );
$$;

grant usage on schema private to authenticated;
grant execute on function
  private.is_aal2(), private.staff_org_ids(), private.client_org_ids(),
  private.has_role(uuid, text[]), private.can_read_org(uuid), private.can_read_portfolio(uuid),
  private.can_see_members_of(uuid)
  to authenticated;

------------------------------------------------------------------------------------------
-- RLS: read policies only. No insert/update/delete policies: writes go through the worker
-- (service_role) or SECURITY DEFINER command functions.
------------------------------------------------------------------------------------------

alter table public.organization enable row level security;
alter table public.app_user enable row level security;
alter table public.membership enable row level security;
alter table public.portfolio enable row level security;
alter table public.portfolio_access enable row level security;
alter table private.command_log enable row level security;

grant select on public.organization, public.app_user, public.membership, public.portfolio,
  public.portfolio_access to authenticated;

create policy organization_read on public.organization for select to authenticated
  using ((select private.can_read_org(id)));

create policy app_user_read on public.app_user for select to authenticated
  using (
    id = (select auth.uid())
    or exists (
      select 1 from public.membership m
      where m.user_id = app_user.id and (select private.can_see_members_of(m.organization_id))
    )
  );

create policy membership_read on public.membership for select to authenticated
  using (user_id = (select auth.uid()) or (select private.can_see_members_of(organization_id)));

create policy portfolio_read on public.portfolio for select to authenticated
  using ((select private.can_read_portfolio(id)));

create policy portfolio_access_read on public.portfolio_access for select to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.portfolio p
      where p.id = portfolio_access.portfolio_id
        and p.organization_id = any (private.staff_org_ids())
    )
  );

------------------------------------------------------------------------------------------
-- Custom access token hook: adds hints for the UI. RLS never trusts these claims.
------------------------------------------------------------------------------------------

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_user uuid := (event ->> 'user_id')::uuid;
  v_claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  v_org_ids jsonb;
  v_roles jsonb;
  v_internal boolean;
begin
  select
    coalesce(jsonb_agg(distinct m.organization_id), '[]'::jsonb),
    coalesce(jsonb_agg(distinct m.role), '[]'::jsonb),
    coalesce(bool_or(o.kind = 'servicer'), false)
  into v_org_ids, v_roles, v_internal
  from public.membership m
  join public.organization o on o.id = m.organization_id
  where m.user_id = v_user;

  v_claims := v_claims
    || jsonb_build_object('org_ids', v_org_ids, 'app_roles', v_roles, 'is_internal', v_internal);
  return jsonb_set(event, '{claims}', v_claims);
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant select on public.membership, public.organization to supabase_auth_admin;
create policy membership_auth_hook_read on public.membership for select to supabase_auth_admin
  using (true);
create policy organization_auth_hook_read on public.organization for select to supabase_auth_admin
  using (true);

------------------------------------------------------------------------------------------
-- Command pattern (M0-11): SECURITY DEFINER, pinned search_path, role check, idempotency key.
------------------------------------------------------------------------------------------

create or replace function public.create_portfolio(
  p_idempotency_key text,
  p_client_organization_id uuid,
  p_name text,
  p_default_claim_type text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_servicer uuid;
  v_existing jsonb;
  v_id uuid;
begin
  select result into v_existing from private.command_log
  where command = 'create_portfolio' and idempotency_key = p_idempotency_key;
  if found then
    return (v_existing ->> 'portfolio_id')::uuid;
  end if;

  select servicer_organization_id into v_servicer
  from public.organization where id = p_client_organization_id;
  if v_servicer is null
     or not private.has_role(v_servicer, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;

  insert into public.portfolio (organization_id, client_organization_id, name, default_claim_type)
  values (v_servicer, p_client_organization_id, p_name, p_default_claim_type)
  returning id into v_id;

  insert into private.command_log (command, idempotency_key, actor_id, result)
  values ('create_portfolio', p_idempotency_key, auth.uid(), jsonb_build_object('portfolio_id', v_id));
  return v_id;
end;
$$;
grant execute on function public.create_portfolio(text, uuid, text, text) to authenticated;
