create schema if not exists api;
create schema if not exists private;

revoke all on schema api, private from public, anon, authenticated;
grant usage on schema api to anon, authenticated, service_role;
alter default privileges in schema api revoke all on tables from public, anon, authenticated;
alter default privileges in schema api revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;

create type api.media_kind as enum ('movie', 'show');
create type private.audience as enum ('only_me', 'followers', 'public');

create table api.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  handle text not null unique check (handle ~ '^[a-z0-9_]{3,24}$'),
  display_name text check (display_name = btrim(display_name) and char_length(display_name) between 1 and 80)
);

create table private.profile_settings (
  user_id uuid primary key references api.profiles on delete cascade,
  lifecycle text not null default 'ready' check (lifecycle in ('ready', 'deleting')),
  profile_private boolean not null default false,
  library_audience private.audience not null default 'only_me',
  tracking_activity boolean not null default false,
  timezone text,
  market text check (market ~ '^[A-Z]{2}$'),
  bio text check (char_length(bio) <= 500)
);

create table private.blocks (
  blocker_id uuid not null references api.profiles on delete cascade,
  blocked_id uuid not null references api.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_reverse on private.blocks (blocked_id, blocker_id);

create function private.profile_visible(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.profile_settings s
    where s.user_id = target and s.lifecycle = 'ready'
  ) and not exists (
    select 1 from private.blocks b
    where (b.blocker_id = target and b.blocked_id = (select auth.uid()))
       or (b.blocked_id = target and b.blocker_id = (select auth.uid()))
  );
$$;
grant execute on function private.profile_visible(uuid) to anon, authenticated;

create function private.ready_user() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
  if actor is null or not exists (
    select 1 from private.profile_settings s join auth.users u on u.id = s.user_id
    where s.user_id = actor and s.lifecycle = 'ready' and u.email_confirmed_at is not null
  ) then
    raise exception using errcode = '42501', message = 'profile_required';
  end if;
  return actor;
end;
$$;

alter table api.profiles enable row level security;
create policy profiles_read on api.profiles for select to anon, authenticated
using (private.profile_visible(user_id));
create policy profiles_update on api.profiles for update to authenticated
using (user_id = (select auth.uid()) and private.profile_visible(user_id))
with check (user_id = (select auth.uid()) and private.profile_visible(user_id));
grant select on api.profiles to anon, authenticated;
grant update (display_name) on api.profiles to authenticated;

create function api.claim_profile(requested_handle text) returns api.profiles
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  handle_value text := lower(btrim(requested_handle));
  result api.profiles;
begin
  if actor is null or not exists (
    select 1 from auth.users where id = actor and email_confirmed_at is not null
  ) then
    raise exception using errcode = '42501', message = 'verification_required';
  end if;

  select * into result from api.profiles where user_id = actor;
  if found then
    perform private.ready_user();
    return result;
  end if;
  if handle_value is null or handle_value !~ '^[a-z0-9_]{3,24}$'
    or handle_value in ('admin', 'support', 'taspa') then
    raise exception using errcode = '22023', message = 'invalid_handle';
  end if;

  insert into api.profiles (user_id, handle) values (actor, handle_value)
  on conflict (user_id) do nothing;
  insert into private.profile_settings (user_id) values (actor)
  on conflict (user_id) do nothing;
  select * into result from api.profiles where user_id = actor;
  perform private.ready_user();
  return result;
end;
$$;
grant execute on function api.claim_profile(text) to authenticated;

create table api.titles (
  id uuid primary key default gen_random_uuid(),
  kind api.media_kind not null,
  tmdb_id bigint not null check (tmdb_id > 0),
  display_title text not null check (char_length(display_title) between 1 and 300),
  original_title text,
  overview text,
  poster_path text,
  backdrop_path text,
  first_release_day date,
  runtime_minutes smallint check (runtime_minutes > 0),
  source_release_status text,
  catalog_state text not null default 'available' check (catalog_state in ('available', 'withdrawn')),
  catalog_revision bigint not null default 1 check (catalog_revision > 0),
  updated_at timestamptz not null default now(),
  unique (kind, tmdb_id),
  unique (id, kind)
);
create index titles_public_release on api.titles (kind, first_release_day desc, id)
where catalog_state = 'available';
alter table api.titles enable row level security;
create policy titles_read on api.titles for select to anon, authenticated
using (catalog_state = 'available');
grant select on api.titles to anon, authenticated;
grant select, insert, update on api.titles to service_role;
