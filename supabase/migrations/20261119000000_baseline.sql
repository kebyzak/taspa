-- Taspa database, whole schema in one file: run once on an empty Supabase project (SQL Editor) to get the
-- same database as production. It is the former migrations concatenated in their original order, so later
-- sections replace functions defined earlier on purpose. New changes go into new migration files after this one.
--
-- Afterwards, outside SQL: set Edge Function secrets TMDB_READ_ACCESS_TOKEN, OMDB_API_KEY, TASPA_WORKER_KEY and
-- FCM_SERVICE_ACCOUNT_JSON; add vault secrets taspa_project_url and taspa_worker_key for the cron jobs, deploy the functions.

-- ===== 20261118000100_foundation.sql =====

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
  library_audience private.audience not null default 'followers',
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


-- ===== 20261118000200_movie_library.sql =====

create table private.wanted_entries (
  user_id uuid not null references api.profiles on delete cascade,
  title_id uuid not null references api.titles,
  added_at timestamptz,
  revision bigint not null check (revision > 0),
  primary key (user_id, title_id)
);
create index wanted_active on private.wanted_entries (user_id, added_at desc, title_id)
where added_at is not null;

create table private.movie_viewings (
  id uuid primary key,
  user_id uuid not null references api.profiles on delete cascade,
  movie_id uuid not null,
  kind api.media_kind generated always as ('movie'::api.media_kind) stored,
  watched_on date,
  logged_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null check (revision > 0),
  foreign key (movie_id, kind) references api.titles (id, kind),
  check (deleted_at is null or watched_on is null)
);
create index movie_owner_active on private.movie_viewings (user_id, movie_id, logged_at desc, id)
where deleted_at is null;

create table private.tracking_operations (
  user_id uuid not null references api.profiles on delete cascade,
  operation_id uuid not null,
  title_id uuid not null references api.titles,
  request_hash text not null,
  receipt jsonb,
  undo_of uuid,
  created_at timestamptz not null default now(),
  primary key (user_id, operation_id),
  unique (user_id, undo_of)
);
create index tracking_operation_age on private.tracking_operations (created_at);

create function private.movie_snapshot(actor uuid, title uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'title_id', title,
    'wanted', coalesce(w.added_at is not null, false),
    'wanted_revision', coalesce(w.revision, 0),
    'viewing_count', (select count(*) from private.movie_viewings v
      where v.user_id = actor and v.movie_id = title and v.deleted_at is null)
  )
  from (select 1) as base
  left join private.wanted_entries w on w.user_id = actor and w.title_id = title;
$$;

create function api.tracking_snapshot(title_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select private.movie_snapshot(private.ready_user(), title_id);
$$;
grant execute on function api.tracking_snapshot(uuid) to authenticated;

create function api.viewing_history(title_id uuid, page_size int default 20,
  before_logged_at timestamptz default null, before_id uuid default null)
returns table (id uuid, watched_on date, logged_at timestamptz, revision bigint)
language sql stable security definer set search_path = '' as $$
  select v.id, v.watched_on, v.logged_at, v.revision
  from private.movie_viewings v
  where v.user_id = (select private.ready_user()) and v.movie_id = title_id and v.deleted_at is null
    and (before_logged_at is null or (v.logged_at, v.id) < (before_logged_at, before_id))
  order by v.logged_at desc, v.id desc
  limit greatest(1, least(page_size, 50));
$$;
grant execute on function api.viewing_history(uuid, int, timestamptz, uuid) to authenticated;

create function api.library_page(section text, media api.media_kind default null,
  page_size int default 20, before_time timestamptz default null, before_title uuid default null)
returns table (title jsonb, activity_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with viewer as materialized (select private.ready_user() as id),
  entries as (
    select w.title_id as id, w.added_at as at
    from private.wanted_entries w join viewer on viewer.id = w.user_id
    where section = 'wanted' and w.added_at is not null
    union all
    select v.movie_id, max(v.logged_at)
    from private.movie_viewings v join viewer on viewer.id = v.user_id
    where section = 'watched_movies' and v.deleted_at is null
    group by v.movie_id
  )
  select to_jsonb(t) - 'overview' - 'backdrop_path', e.at
  from entries e join api.titles t on t.id = e.id
  where (media is null or media = t.kind)
    and (before_time is null or (e.at, e.id) < (before_time, before_title))
  order by e.at desc, e.id desc
  limit greatest(1, least(page_size, 50));
$$;
grant execute on function api.library_page(text, api.media_kind, int, timestamptz, uuid) to authenticated;

create function api.apply_tracking(operation_id uuid, submitted_at timestamptz, title_id uuid,
  action text, payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  fingerprint text := md5(jsonb_build_array(submitted_at, title_id, action, payload)::text);
  previous private.tracking_operations;
  candidate api.titles;
  wanted private.wanted_entries;
  viewing private.movie_viewings;
  viewing_id uuid := (payload->>'viewing_id')::uuid;
  watch_date date := (payload->>'watched_on')::date;
  tz text := coalesce(payload->>'timezone', 'UTC');
  watching boolean;
  desired boolean := (payload->>'wanted')::boolean;
  receipt jsonb;
begin
  if operation_id is null or submitted_at is null or title_id is null or action is null
    or payload is null or jsonb_typeof(payload) <> 'object' or octet_length(payload::text) > 4096 then
    raise exception using errcode = '22023', message = 'invalid_operation';
  end if;
  select * into candidate from api.titles t where t.id = title_id for share;
  if not found then
    raise exception using errcode = '22023', message = 'unavailable';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || title_id::text, 0));
  select * into previous from private.tracking_operations o
  where o.user_id = actor and o.operation_id = apply_tracking.operation_id;
  if found then
    if previous.request_hash <> fingerprint then
      raise exception using errcode = '22023', message = 'operation_identity_reused';
    end if;
    return private.movie_snapshot(actor, title_id) || jsonb_build_object(
      'result', 'applied', 'operation_id', operation_id,
      'can_undo', previous.receipt is not null and previous.created_at >= now() - interval '24 hours');
  end if;
  if submitted_at < now() - interval '30 days' or submitted_at > now() + interval '5 minutes' then
    return jsonb_build_object('result', 'expired');
  end if;
  if watch_date is not null and (
    not exists (select 1 from pg_timezone_names where name = tz)
      or watch_date > (now() at time zone tz)::date
  ) then
    raise exception using errcode = '22023', message = 'invalid_watch_date';
  end if;
  select * into wanted from private.wanted_entries w where w.user_id = actor and w.title_id = apply_tracking.title_id;
  select exists (select 1 from private.movie_viewings v
    where v.user_id = actor and v.movie_id = title_id and v.deleted_at is null) into watching;
  if action in ('set_wanted', 'mark_movie_watched')
    and (payload->>'wanted_revision')::bigint is distinct from coalesce(wanted.revision, 0) then
    return private.movie_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
  end if;

  case action
    when 'set_wanted' then
      if desired is null or (desired and (watching or candidate.catalog_state <> 'available')) then
        raise exception using errcode = '22023', message = 'wanted_ineligible';
      end if;
      if desired <> (wanted.added_at is not null) then
        insert into private.wanted_entries (user_id, title_id, added_at, revision)
        values (actor, apply_tracking.title_id, case when desired then now() end, 1)
        on conflict on constraint wanted_entries_pkey do update
        set added_at = excluded.added_at, revision = wanted_entries.revision + 1;
        receipt := jsonb_build_object('wanted_before', wanted.added_at, 'wanted_after', coalesce(wanted.revision, 0) + 1);
      end if;
    when 'mark_movie_watched', 'log_rewatch' then
      if candidate.kind <> 'movie' or candidate.catalog_state <> 'available' or candidate.first_release_day > current_date
        or viewing_id is null or ((action = 'log_rewatch') <> watching) then
        raise exception using errcode = '22023', message = 'viewing_ineligible';
      end if;
      insert into private.movie_viewings (id, user_id, movie_id, watched_on, revision)
      values (viewing_id, actor, title_id, watch_date, 1);
      receipt := jsonb_build_object('id', viewing_id, 'viewing_after', 1, 'inserted', true);
      if wanted.added_at is not null then
        update private.wanted_entries w set added_at = null, revision = revision + 1
        where w.user_id = actor and w.title_id = apply_tracking.title_id;
        receipt := receipt || jsonb_build_object('wanted_before', wanted.added_at, 'wanted_after', wanted.revision + 1);
      end if;
    when 'edit_movie_viewing', 'delete_movie_viewing' then
      select * into viewing from private.movie_viewings v
      where v.id = viewing_id and v.user_id = actor and v.movie_id = title_id;
      if viewing.revision is null or viewing.deleted_at is not null
        or viewing.revision is distinct from (payload->>'revision')::bigint then
        return private.movie_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
      end if;
      update private.movie_viewings v set
        watched_on = case when action = 'edit_movie_viewing' then watch_date end,
        deleted_at = case when action = 'delete_movie_viewing' then now() end,
        revision = revision + 1 where v.id = viewing_id;
      receipt := jsonb_build_object('id', viewing_id, 'viewing_after', viewing.revision + 1, 'date_before', viewing.watched_on);
    else raise exception using errcode = '22023', message = 'unsupported_action';
  end case;

  insert into private.tracking_operations (user_id, operation_id, title_id, request_hash, receipt)
  values (actor, operation_id, title_id, fingerprint, receipt);
  return private.movie_snapshot(actor, title_id) || jsonb_build_object(
    'result', 'applied', 'operation_id', operation_id, 'can_undo', receipt is not null);
end;
$$;
grant execute on function api.apply_tracking(uuid, timestamptz, uuid, text, jsonb) to authenticated;

create function api.undo_tracking(operation_id uuid, submitted_at timestamptz, original_operation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  original private.tracking_operations;
  viewing private.movie_viewings;
  wanted private.wanted_entries;
  restored_wanted timestamptz;
  drop_viewing boolean;
begin
  if operation_id is null or submitted_at is null or original_operation_id is null or operation_id = original_operation_id then
    raise exception using errcode = '22023', message = 'invalid_operation';
  end if;
  select * into original from private.tracking_operations o
  where o.user_id = actor and o.operation_id = original_operation_id;
  if original.receipt is null or original.created_at < now() - interval '24 hours'
    or submitted_at > now() + interval '5 minutes' or submitted_at < now() - interval '30 days' then
    return jsonb_build_object('result', 'expired');
  end if;
  perform 1 from api.titles t where t.id = original.title_id for share;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || original.title_id::text, 0));
  if exists (select 1 from private.tracking_operations o where o.user_id = actor and o.undo_of = original_operation_id) then
    return private.movie_snapshot(actor, original.title_id) || jsonb_build_object('result', 'applied');
  end if;
  if original.receipt ? 'id' then
    select * into viewing from private.movie_viewings v where v.id = (original.receipt->>'id')::uuid and v.user_id = actor;
    if viewing.revision is distinct from (original.receipt->>'viewing_after')::bigint then
      return private.movie_snapshot(actor, original.title_id) || jsonb_build_object('result', 'conflict');
    end if;
  end if;
  drop_viewing := coalesce((original.receipt->>'inserted')::boolean, false);
  select * into wanted from private.wanted_entries w where w.user_id = actor and w.title_id = original.title_id;
  if original.receipt ? 'wanted_after' then
    restored_wanted := (original.receipt->>'wanted_before')::timestamptz;
    if wanted.revision is distinct from (original.receipt->>'wanted_after')::bigint
      or (restored_wanted is not null and exists (select 1 from private.movie_viewings v
        where v.user_id = actor and v.movie_id = original.title_id and v.deleted_at is null
          and (not drop_viewing or v.id <> viewing.id))) then
      return private.movie_snapshot(actor, original.title_id) || jsonb_build_object('result', 'conflict');
    end if;
    update private.wanted_entries w set added_at = restored_wanted, revision = revision + 1
    where w.user_id = actor and w.title_id = original.title_id;
  end if;
  if viewing.id is not null then
    if not drop_viewing and wanted.added_at is not null then
      return private.movie_snapshot(actor, original.title_id) || jsonb_build_object('result', 'conflict');
    end if;
    update private.movie_viewings v set
      watched_on = case when not drop_viewing then (original.receipt->>'date_before')::date end,
      deleted_at = case when drop_viewing then now() end, revision = revision + 1 where v.id = viewing.id;
  end if;
  insert into private.tracking_operations (user_id, operation_id, title_id, request_hash, undo_of)
  values (actor, operation_id, original.title_id, md5(original_operation_id::text), original_operation_id);
  return private.movie_snapshot(actor, original.title_id) || jsonb_build_object('result', 'applied');
end;
$$;
grant execute on function api.undo_tracking(uuid, timestamptz, uuid) to authenticated;


-- ===== 20261118000300_catalog_gateway.sql =====

create table private.catalog_cache (
  cache_key text primary key,
  value jsonb,
  fetched_at timestamptz,
  expires_at timestamptz,
  lease_id uuid,
  lease_until timestamptz,
  touched_at timestamptz not null default now()
);
create index catalog_cache_touch on private.catalog_cache (touched_at);

create table private.rate_limits (
  bucket text not null,
  window_start timestamptz not null,
  hits int not null,
  primary key (bucket, window_start)
);
create index rate_limits_age on private.rate_limits (window_start);

create function private.take_catalog_budget(bucket_key text, max_hits int) returns boolean
language plpgsql set search_path = '' as $$
declare
  outcome int;
begin
  insert into private.rate_limits as limits (bucket, window_start, hits)
  values (bucket_key, date_trunc('minute', now()), 1)
  on conflict (bucket, window_start) do update set hits = limits.hits + 1
  where limits.hits < max_hits returning hits into outcome;
  return outcome is not null;
end;
$$;

create function api.catalog_claim(request_key text, requester text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  entry private.catalog_cache;
  lease uuid;
  cached jsonb;
begin
  if request_key !~ '^[a-f0-9]{64}$' or requester !~ '^[a-f0-9]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_catalog_key';
  end if;
  if not private.take_catalog_budget('catalog', 900)
    or not private.take_catalog_budget(requester, 60) then
    return jsonb_build_object('state', 'limited');
  end if;
  delete from private.rate_limits where (bucket, window_start) in (
    select bucket, window_start from private.rate_limits
    where window_start < now() - interval '1 hour' order by window_start limit 25
  );
  delete from private.catalog_cache where cache_key in (
    select cache_key from private.catalog_cache where touched_at < now() - interval '7 days'
    order by touched_at limit 25
  );
  insert into private.catalog_cache (cache_key) values (request_key) on conflict do nothing;
  select * into entry from private.catalog_cache where cache_key = request_key for update;
  cached := jsonb_build_object('value', entry.value, 'fetched_at', entry.fetched_at);
  if entry.expires_at > now() then
    return cached || jsonb_build_object('state', 'fresh');
  end if;
  if entry.lease_until > now() then
    return cached || jsonb_build_object('state', 'busy');
  end if;
  if not private.take_catalog_budget('tmdb', 60) then
    return cached || jsonb_build_object('state', 'limited');
  end if;
  lease := gen_random_uuid();
  update private.catalog_cache set lease_id = lease, lease_until = now() + interval '15 seconds', touched_at = now()
  where cache_key = request_key;
  return cached || jsonb_build_object('state', 'leased', 'lease', lease);
end;
$$;
grant execute on function api.catalog_claim(text, text) to service_role;

create function api.catalog_finish(request_key text, lease uuid, ttl_seconds int, result jsonb, hydrated jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  title_uuid uuid;
begin
  perform 1 from private.catalog_cache
  where cache_key = request_key and lease_id = lease and lease_until >= now() for update;
  if not found then
    raise exception using errcode = '22023', message = 'catalog_lease_expired';
  end if;
  if ttl_seconds is null or ttl_seconds not between 60 and 86400 or octet_length(result::text) > 200000 then
    raise exception using errcode = '22023', message = 'invalid_catalog_result';
  end if;
  if hydrated is not null then
    insert into api.titles as existing (
      kind, tmdb_id, display_title, original_title, overview, poster_path, backdrop_path,
      first_release_day, runtime_minutes, source_release_status
    )
    values (
      (hydrated->>'kind')::api.media_kind, (hydrated->>'tmdb_id')::bigint,
      hydrated->>'display_title', hydrated->>'original_title', hydrated->>'overview',
      hydrated->>'poster_path', hydrated->>'backdrop_path',
      (hydrated->>'first_release_day')::date, (hydrated->>'runtime_minutes')::smallint, hydrated->>'source_release_status'
    )
    on conflict (kind, tmdb_id) do update set
      display_title = excluded.display_title, original_title = excluded.original_title, overview = excluded.overview,
      poster_path = excluded.poster_path, backdrop_path = excluded.backdrop_path, first_release_day = excluded.first_release_day,
      runtime_minutes = excluded.runtime_minutes, source_release_status = excluded.source_release_status,
      catalog_revision = existing.catalog_revision + 1, updated_at = now()
    where existing.catalog_state = 'available'
    returning id into title_uuid;
    if title_uuid is null then
      raise exception using errcode = '22023', message = 'unavailable';
    end if;
    result := result || jsonb_build_object('id', title_uuid);
  end if;
  update private.catalog_cache
    set value = result, fetched_at = now(), expires_at = now() + make_interval(secs => ttl_seconds),
      lease_id = null, lease_until = null, touched_at = now()
  where cache_key = request_key;
  return result;
end;
$$;
grant execute on function api.catalog_finish(text, uuid, int, jsonb, jsonb) to service_role;


-- ===== 20261118000350_function_grants.sql =====

-- A schema-level default revoke cannot override PostgreSQL's global PUBLIC
-- EXECUTE default. Restrict existing RPCs and require a grant on new functions.
alter default privileges revoke execute on functions from public, anon, authenticated;
revoke execute on all functions in schema api, private from public;
revoke execute on function api.catalog_claim(text,text) from anon, authenticated;
revoke execute on function api.catalog_finish(text,uuid,int,jsonb,jsonb) from anon, authenticated;


-- ===== 20261118000400_show_catalog.sql =====

create table api.seasons (
  id uuid primary key default gen_random_uuid(),
  show_id uuid not null,
  kind api.media_kind generated always as ('show'::api.media_kind) stored,
  tmdb_id bigint not null unique check (tmdb_id > 0),
  season_number int not null check (season_number >= 0),
  display_title text not null,
  expected_episodes int not null check (expected_episodes >= 0),
  first_release_day date,
  loaded_at timestamptz,
  available boolean not null default true,
  unique (id, show_id),
  foreign key (show_id, kind) references api.titles (id, kind)
);
create unique index season_available_number on api.seasons (show_id, season_number) where available;
create table api.episodes (
  id uuid primary key default gen_random_uuid(),
  show_id uuid not null,
  season_id uuid not null,
  tmdb_id bigint not null unique check (tmdb_id > 0),
  episode_number int not null check (episode_number > 0),
  display_title text not null,
  runtime_minutes smallint check (runtime_minutes > 0),
  release_day date,
  available boolean not null default true,
  unique (id, show_id),
  foreign key (season_id, show_id) references api.seasons (id, show_id)
);
create unique index episode_available_number on api.episodes (season_id, episode_number) where available;
create index episodes_by_show on api.episodes (show_id, season_id, episode_number) where available;

alter table api.seasons enable row level security;
alter table api.episodes enable row level security;
create policy season_read on api.seasons for select to anon, authenticated
using (available and exists (select 1 from api.titles t where t.id = show_id));
create policy episode_read on api.episodes for select to anon, authenticated
using (available and exists (select 1 from api.seasons s where s.id = season_id));
grant select on api.seasons, api.episodes to anon, authenticated;

create function api.import_show_seasons(show_uuid uuid, rows jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if jsonb_typeof(rows) <> 'array' or jsonb_array_length(rows) > 120 then
    raise exception using errcode = '22023', message = 'invalid_seasons';
  end if;
  perform 1 from api.titles t where t.id = show_uuid and t.kind = 'show' and t.catalog_state = 'available' for update;
  if not found then raise exception using errcode = '22023', message = 'unavailable'; end if;
  update api.seasons set available = false where show_id = show_uuid and available;
  insert into api.seasons as existing (show_id, tmdb_id, season_number, display_title, expected_episodes, first_release_day)
  select show_uuid, x.tmdb_id, x.season_number, x.display_title, x.expected_episodes, x.first_release_day
  from jsonb_to_recordset(rows) as x(tmdb_id bigint, season_number int, display_title text, expected_episodes int, first_release_day date)
  on conflict (tmdb_id) do update set
    season_number = excluded.season_number, display_title = excluded.display_title,
    expected_episodes = excluded.expected_episodes, first_release_day = excluded.first_release_day, available = true
  where existing.show_id = show_uuid;
  update api.titles set catalog_revision = catalog_revision + 1 where id = show_uuid;
end;
$$;
grant execute on function api.import_show_seasons(uuid, jsonb) to service_role;

create function api.import_show_episodes(show_tmdb bigint, season_tmdb bigint, rows jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  parent uuid;
  season_uuid uuid;
begin
  if jsonb_typeof(rows) <> 'array' or jsonb_array_length(rows) > 1200 then
    raise exception using errcode = '22023', message = 'invalid_episodes';
  end if;
  select id into parent from api.titles
  where kind = 'show' and tmdb_id = show_tmdb and catalog_state = 'available' for update;
  select id into season_uuid from api.seasons where show_id = parent and tmdb_id = season_tmdb and available;
  if season_uuid is null then raise exception using errcode = '22023', message = 'unavailable'; end if;

  update api.episodes set available = false where season_id = season_uuid and available;
  insert into api.episodes as existing (show_id, season_id, tmdb_id, episode_number, display_title, runtime_minutes, release_day)
  select parent, season_uuid, x.tmdb_id, x.episode_number, x.display_title, x.runtime_minutes, x.release_day
  from jsonb_to_recordset(rows) as x(tmdb_id bigint, episode_number int, display_title text, runtime_minutes smallint, release_day date)
  on conflict (tmdb_id) do update set
    season_id = excluded.season_id, episode_number = excluded.episode_number,
    display_title = excluded.display_title, runtime_minutes = excluded.runtime_minutes,
    release_day = excluded.release_day, available = true
  where existing.show_id = parent;
  update api.seasons set loaded_at = now() where id = season_uuid;
  update api.titles set catalog_revision = catalog_revision + 1 where id = parent;
end;
$$;
grant execute on function api.import_show_episodes(bigint, bigint, jsonb) to service_role;

create function api.catalog_finish_show(request_key text, lease uuid, ttl_seconds int, result jsonb,
  hydrated jsonb, show_tmdb bigint, season_tmdb bigint, children jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  saved jsonb;
begin
  saved := api.catalog_finish(request_key, lease, ttl_seconds, result, hydrated);
  if season_tmdb is null then
    perform api.import_show_seasons((saved->>'id')::uuid, children);
  else
    perform api.import_show_episodes(show_tmdb, season_tmdb, children);
  end if;
  return saved;
end;
$$;
grant execute on function api.catalog_finish_show(text, uuid, int, jsonb, jsonb, bigint, bigint, jsonb) to service_role;


-- ===== 20261118000500_show_tracking.sql =====

create table private.tracked_shows (
  user_id uuid not null references api.profiles on delete cascade,
  show_id uuid not null,
  kind api.media_kind generated always as ('show'::api.media_kind) stored,
  intent text check (intent in ('watching', 'on_hold', 'dropped')),
  last_activity_at timestamptz not null default now(),
  revision bigint not null check (revision > 0),
  primary key (user_id, show_id),
  foreign key (show_id, kind) references api.titles (id, kind)
);
create index tracked_active on private.tracked_shows (user_id, last_activity_at desc, show_id) where intent is not null;

create table private.episode_marks (
  user_id uuid not null,
  show_id uuid not null,
  episode_id uuid not null,
  watched boolean not null,
  watched_on date,
  revision bigint not null check (revision > 0),
  primary key (user_id, episode_id),
  foreign key (user_id, show_id) references private.tracked_shows on delete cascade,
  foreign key (episode_id, show_id) references api.episodes (id, show_id),
  check (watched or watched_on is null)
);
create index episode_watches_by_show on private.episode_marks (user_id, show_id, episode_id) where watched;

create function private.episode_released(day_value date) returns boolean
language sql stable set search_path = '' as $$
  -- A date without an authoritative time can still be airing across time zones.
  select coalesce(day_value < (now() at time zone 'UTC')::date - 1, false);
$$;

create function private.show_snapshot(actor uuid, title uuid) returns jsonb
language sql stable set search_path = '' as $$
  with regular as (
    select s.id, s.season_number, s.first_release_day, s.loaded_at, s.expected_episodes,
      count(*) filter (where e.id is not null) as known_count,
      count(*) filter (where private.episode_released(e.release_day)) as released,
      count(*) filter (where private.episode_released(e.release_day) and m.watched) as watched
    from api.seasons s
    left join api.episodes e on e.season_id = s.id and e.available
    left join private.episode_marks m on m.user_id = actor and m.episode_id = e.id
    where s.show_id = title and s.available and s.season_number > 0
    group by s.id
  ), totals as (
    select coalesce(sum(released), 0) as released, coalesce(sum(watched), 0) as watched,
      count(*) filter (where released > 0) as seasons_released,
      coalesce(bool_and(loaded_at is not null and known_count >= expected_episodes), false) as coverage,
      coalesce(bool_and(released >= expected_episodes and known_count = released), false) as all_released,
      coalesce(bool_and(
        (loaded_at is not null and known_count >= expected_episodes)
        or (first_release_day is not null and not private.episode_released(first_release_day))
      ), false) as released_coverage
    from regular
  ), next_up as (
    select e.id, e.display_title, r.season_number, e.episode_number, coalesce(m.revision, 0) as revision
    from regular r
    join api.episodes e on e.season_id = r.id and e.available and private.episode_released(e.release_day)
    left join private.episode_marks m on m.user_id = actor and m.episode_id = e.id
    where not coalesce(m.watched, false)
      and not exists (select 1 from regular older
        where older.season_number < r.season_number
          and (older.loaded_at is null or older.known_count < older.expected_episodes))
    order by r.season_number, e.episode_number, e.id limit 1
  )
  select private.movie_snapshot(actor, title) || jsonb_build_object(
    'intent', tracked.intent,
    'show_revision', coalesce(tracked.revision, 0),
    'status', case when tracked.intent = 'watching' and totals.watched > 0 and totals.watched = totals.released
      and totals.coverage and totals.all_released and t.source_release_status in ('Ended', 'Canceled')
      then 'completed' else tracked.intent end,
    'released', totals.released,
    'watched', totals.watched,
    'seasons_released', totals.seasons_released,
    'seasons_completed', (select count(*) from regular r where r.released > 0 and r.released = r.watched
       and r.loaded_at is not null and r.known_count = r.released and r.released >= r.expected_episodes
       and (t.source_release_status in ('Ended', 'Canceled') or exists (
         select 1 from regular later where later.season_number > r.season_number and later.released > 0))),
    'coverage', totals.released_coverage,
    'next', case when tracked.intent = 'watching' then (select to_jsonb(next_up) from next_up) end,
    'upcoming_day', (select min(e.release_day) from regular r join api.episodes e on e.season_id = r.id
      where e.available and e.release_day >= (now() at time zone 'UTC')::date)
  )
  from totals join api.titles t on t.id = title
  left join private.tracked_shows tracked on tracked.user_id = actor and tracked.show_id = title;
$$;

create or replace function api.tracking_snapshot(title_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case t.kind when 'show' then private.show_snapshot(private.ready_user(), t.id)
    else private.movie_snapshot(private.ready_user(), t.id) end
  from api.titles t where t.id = title_id;
$$;

create function api.show_episode_page(title_id uuid, selected_season uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('episodes', coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'number', e.episode_number, 'title', e.display_title, 'released', private.episode_released(e.release_day),
    'release_day', e.release_day, 'watched', coalesce(m.watched, false), 'watched_on', m.watched_on,
    'revision', coalesce(m.revision, 0)
  ) order by e.episode_number, e.id), '[]'::jsonb))
  from api.episodes e
  join api.seasons s on s.id = e.season_id and s.available
  join api.titles t on t.id = e.show_id and t.catalog_state = 'available'
  left join private.episode_marks m on m.user_id = (select auth.uid()) and m.episode_id = e.id
    and private.profile_visible(m.user_id)
  where e.show_id = title_id and e.season_id = selected_season and e.available;
$$;
grant execute on function api.show_episode_page(uuid, uuid) to anon, authenticated;

create function private.show_batch_scope(actor uuid, title uuid, scope text, season uuid, episode uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  anchor_season int;
  anchor_episode int;
  targets jsonb;
begin
  if scope in ('mark_season_watched', 'mark_season_unwatched') then
    select season_number into anchor_season from api.seasons s
    where s.id = season and s.show_id = title and s.available and s.season_number > 0;
  elsif scope = 'mark_through' then
    select s.season_number, e.episode_number into anchor_season, anchor_episode
    from api.episodes e join api.seasons s on s.id = e.season_id
    where e.id = episode and e.show_id = title and e.available and s.available
      and s.season_number > 0 and private.episode_released(e.release_day);
  elsif scope = 'mark_ended_show_watched' then
    if not exists (select 1 from api.titles t where t.id = title and t.source_release_status in ('Ended', 'Canceled')) then
      raise exception using errcode = '22023', message = 'show_not_ended';
    end if;
  elsif scope <> 'remove_show' or scope is null then
    raise exception using errcode = '22023', message = 'unsupported_batch';
  end if;
  if scope in ('mark_season_watched', 'mark_season_unwatched', 'mark_through') and anchor_season is null then
    raise exception using errcode = '22023', message = 'invalid_batch_scope';
  end if;
  if scope in ('mark_season_watched', 'mark_through', 'mark_ended_show_watched') and exists (
    select 1 from api.seasons s
    where s.show_id = title and s.available and s.season_number > 0
      and (scope = 'mark_ended_show_watched' or (scope = 'mark_season_watched' and s.id = season)
        or (scope = 'mark_through' and s.season_number <= anchor_season))
      and (s.loaded_at is null or (select count(*) from api.episodes e where e.season_id = s.id and e.available) < s.expected_episodes)
  ) then raise exception using errcode = '22023', message = 'batch_catalog_incomplete'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'revision', coalesce(m.revision, 0)) order by e.id), '[]'::jsonb)
  into targets
  from api.episodes e join api.seasons s on s.id = e.season_id
  left join private.episode_marks m on m.user_id = actor and m.episode_id = e.id
  where e.show_id = title and case
    when scope = 'remove_show' then coalesce(m.watched, false)
    when scope = 'mark_season_unwatched' then s.id = season and coalesce(m.watched, false)
    else e.available and s.available and s.season_number > 0 and private.episode_released(e.release_day)
      and not coalesce(m.watched, false) and
      (scope = 'mark_ended_show_watched' or (scope = 'mark_season_watched' and s.id = season)
        or (scope = 'mark_through' and (s.season_number, e.episode_number) <= (anchor_season, anchor_episode)))
    end;
  if jsonb_array_length(targets) > 300 then
    raise exception using errcode = '22023', message = 'batch_limit';
  end if;
  return targets;
end;
$$;

create function api.tracking_preview(title_id uuid, scope text, season_id uuid default null, episode_id uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('catalog_revision', t.catalog_revision,
    'episodes', private.show_batch_scope(private.ready_user(), t.id, scope, season_id, episode_id))
  from api.titles t where t.id = title_id and t.kind = 'show' and t.catalog_state = 'available';
$$;
grant execute on function api.tracking_preview(uuid, text, uuid, uuid) to authenticated;

create function private.apply_show_tracking(operation_id uuid, submitted_at timestamptz, title_id uuid,
  action text, payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  fingerprint text := md5(jsonb_build_array(submitted_at, title_id, action, payload)::text);
  previous private.tracking_operations;
  tracked private.tracked_shows;
  wanted private.wanted_entries;
  mark private.episode_marks;
  episode api.episodes;
  desired boolean;
  date_value date := (payload->>'watched_on')::date;
  requested_intent text := payload->>'intent';
  episode_uuid uuid := (payload->>'episode_id')::uuid;
  current_state jsonb;
  receipt jsonb;
  batch_scope text := payload->>'scope';
  targets jsonb;
  previous_marks jsonb;
begin
  if operation_id is null or submitted_at is null or action is null or jsonb_typeof(payload) is distinct from 'object'
    or octet_length(payload::text) > (case when action = 'apply_show_batch' then 32768 else 4096 end) then
    raise exception using errcode = '22023', message = 'invalid_operation';
  end if;
  perform 1 from api.titles t where t.id = title_id and t.kind = 'show' and t.catalog_state = 'available' for share;
  if not found then raise exception using errcode = '22023', message = 'unavailable'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || title_id::text, 0));
  select * into previous from private.tracking_operations o
  where o.user_id = actor and o.operation_id = apply_show_tracking.operation_id;
  if found then
    if previous.request_hash is distinct from fingerprint then
      raise exception using errcode = '22023', message = 'operation_identity_reused';
    end if;
    return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'applied',
      'can_undo', previous.receipt is not null and previous.created_at >= now() - interval '24 hours');
  end if;
  if submitted_at < now() - interval '30 days' or submitted_at > now() + interval '5 minutes' then
    return jsonb_build_object('result', 'expired');
  end if;
  if date_value is not null and date_value > (now() at time zone 'UTC')::date then
    raise exception using errcode = '22023', message = 'invalid_watch_date';
  end if;
  select * into tracked from private.tracked_shows s where s.user_id = actor and s.show_id = title_id;
  select * into wanted from private.wanted_entries w where w.user_id = actor and w.title_id = apply_show_tracking.title_id;
  if action in ('set_wanted', 'start_show')
    and (payload->>'wanted_revision')::bigint is distinct from coalesce(wanted.revision, 0) then
    return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
  end if;

  if action = 'set_wanted' then
    desired := (payload->>'wanted')::boolean;
    if desired is null or (desired and tracked.intent is not null) then
      raise exception using errcode = '22023', message = 'wanted_ineligible';
    end if;
    if desired <> (wanted.added_at is not null) then
      insert into private.wanted_entries (user_id, title_id, added_at, revision)
      values (actor, title_id, case when desired then now() end, 1)
      on conflict on constraint wanted_entries_pkey do update
      set added_at = excluded.added_at, revision = wanted_entries.revision + 1;
      receipt := jsonb_build_object('wanted_before', wanted.added_at, 'wanted_after', coalesce(wanted.revision, 0) + 1);
    end if;
  elsif action in ('start_show', 'set_show_intent') then
    if (payload->>'show_revision')::bigint is distinct from coalesce(tracked.revision, 0) then
      return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
    end if;
    if action = 'start_show' then
      if tracked.intent is not null or not exists (
        select 1 from api.episodes e join api.seasons s on s.id = e.season_id
        where e.show_id = title_id and e.available and s.available and s.season_number > 0
          and private.episode_released(e.release_day)
      ) then raise exception using errcode = '22023', message = 'show_ineligible'; end if;
      insert into private.tracked_shows (user_id, show_id, intent, revision)
      values (actor, title_id, 'watching', 1)
      on conflict on constraint tracked_shows_pkey do update
      set intent = 'watching', last_activity_at = now(), revision = tracked_shows.revision + 1;
      receipt := jsonb_build_object('show_before', tracked.intent, 'show_after', coalesce(tracked.revision, 0) + 1);
      update private.wanted_entries w set added_at = null, revision = revision + 1
      where w.user_id = actor and w.title_id = apply_show_tracking.title_id and w.added_at is not null;
      if wanted.added_at is not null then
        receipt := receipt || jsonb_build_object('wanted_before', wanted.added_at, 'wanted_after', wanted.revision + 1);
      end if;
    else
      if tracked.intent is null or requested_intent is null or requested_intent not in ('watching', 'on_hold', 'dropped') then
        raise exception using errcode = '22023', message = 'invalid_show_intent';
      end if;
      update private.tracked_shows set intent = requested_intent, revision = revision + 1, last_activity_at = now()
      where user_id = actor and show_id = title_id and intent is distinct from requested_intent;
      if found then receipt := jsonb_build_object('show_before', tracked.intent, 'show_after', tracked.revision + 1); end if;
    end if;
  elsif action = 'apply_show_batch' then
    targets := private.show_batch_scope(actor, title_id, batch_scope,
      (payload->>'season_id')::uuid, (payload->>'episode_id')::uuid);
    if targets is distinct from payload->'episodes'
      or (payload->>'catalog_revision')::bigint is distinct from (select catalog_revision from api.titles where id = title_id)
      or (payload->>'show_revision')::bigint is distinct from coalesce(tracked.revision, 0) then
      return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
    end if;
    desired := batch_scope not in ('mark_season_unwatched', 'remove_show');
    if tracked.intent is null and jsonb_array_length(targets) > 0 then
      if not desired or (payload->>'wanted_revision')::bigint is distinct from coalesce(wanted.revision, 0) then
        return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
      end if;
      insert into private.tracked_shows (user_id, show_id, intent, revision)
      values (actor, title_id, 'watching', 1)
      on conflict on constraint tracked_shows_pkey do update
      set intent = 'watching', last_activity_at = now(), revision = tracked_shows.revision + 1;
      receipt := jsonb_build_object('show_before', null, 'show_after', coalesce(tracked.revision, 0) + 1);
      if wanted.added_at is not null then
        update private.wanted_entries w set added_at = null, revision = revision + 1
        where w.user_id = actor and w.title_id = apply_show_tracking.title_id;
        receipt := receipt || jsonb_build_object('wanted_before', wanted.added_at, 'wanted_after', wanted.revision + 1);
      end if;
    end if;
    if jsonb_array_length(targets) > 0 then
      select jsonb_agg(jsonb_build_object('id', x.id, 'after', x.revision + 1,
        'watched', coalesce(m.watched, false), 'day', m.watched_on))
      into previous_marks from jsonb_to_recordset(targets) as x(id uuid, revision bigint)
      left join private.episode_marks m on m.user_id = actor and m.episode_id = x.id;
      insert into private.episode_marks (user_id, show_id, episode_id, watched, revision)
      select actor, title_id, x.id, desired, 1 from jsonb_to_recordset(targets) as x(id uuid)
      on conflict on constraint episode_marks_pkey do update
      set watched = excluded.watched, watched_on = null, revision = episode_marks.revision + 1;
      update private.tracked_shows set last_activity_at = now() where user_id = actor and show_id = title_id;
      receipt := coalesce(receipt, '{}'::jsonb) || jsonb_build_object('batch', previous_marks);
    end if;
    if batch_scope = 'remove_show' and tracked.intent is not null then
      update private.tracked_shows set intent = null, revision = revision + 1, last_activity_at = now()
      where user_id = actor and show_id = title_id;
      receipt := coalesce(receipt, '{}'::jsonb) ||
        jsonb_build_object('show_before', tracked.intent, 'show_after', tracked.revision + 1);
    end if;
  elsif action in ('set_episode_watched', 'edit_episode_watch_date') then
    select e.* into episode from api.episodes e join api.seasons s on s.id = e.season_id
    where e.id = episode_uuid and e.show_id = title_id and e.available and s.available;
    if not found then
      raise exception using errcode = '22023', message = 'episode_ineligible';
    end if;
    select * into mark from private.episode_marks m where m.user_id = actor and m.episode_id = episode_uuid;
    if (payload->>'revision')::bigint is distinct from coalesce(mark.revision, 0) then
      return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
    end if;
    desired := case when action = 'edit_episode_watch_date' then mark.watched else (payload->>'watched')::boolean end;
    if desired is null or (desired and not coalesce(mark.watched, false) and not private.episode_released(episode.release_day))
      or (action = 'edit_episode_watch_date' and desired is not true) then
      raise exception using errcode = '22023', message = 'episode_ineligible';
    end if;
    if tracked.intent is null then
      if not desired or not exists (select 1 from api.seasons s where s.id = episode.season_id and s.season_number > 0) then
        raise exception using errcode = '22023', message = 'show_ineligible';
      end if;
      if (payload->>'wanted_revision')::bigint is distinct from coalesce(wanted.revision, 0)
        or (payload->>'show_revision')::bigint is distinct from coalesce(tracked.revision, 0) then
        return private.show_snapshot(actor, title_id) || jsonb_build_object('result', 'conflict');
      end if;
      insert into private.tracked_shows (user_id, show_id, intent, revision)
      values (actor, title_id, 'watching', 1)
      on conflict on constraint tracked_shows_pkey do update
      set intent = 'watching', last_activity_at = now(), revision = tracked_shows.revision + 1;
      receipt := jsonb_build_object('show_before', null, 'show_after', coalesce(tracked.revision, 0) + 1);
      if wanted.added_at is not null then
        update private.wanted_entries w set added_at = null, revision = revision + 1
        where w.user_id = actor and w.title_id = apply_show_tracking.title_id;
        receipt := receipt || jsonb_build_object('wanted_before', wanted.added_at, 'wanted_after', wanted.revision + 1);
      end if;
    end if;
    if desired is distinct from coalesce(mark.watched, false)
      or (action = 'edit_episode_watch_date' and date_value is distinct from mark.watched_on) then
      insert into private.episode_marks (user_id, show_id, episode_id, watched, watched_on, revision)
      values (actor, title_id, episode_uuid, desired, case when desired then date_value end, 1)
      on conflict on constraint episode_marks_pkey do update
      set watched = excluded.watched, watched_on = excluded.watched_on, revision = episode_marks.revision + 1;
      update private.tracked_shows set last_activity_at = now() where user_id = actor and show_id = title_id;
      receipt := coalesce(receipt, '{}'::jsonb) || jsonb_build_object('episode_id', episode_uuid, 'episode_after', coalesce(mark.revision, 0) + 1,
        'episode_watched_before', coalesce(mark.watched, false), 'episode_day_before', mark.watched_on);
    end if;
  else
    raise exception using errcode = '22023', message = 'unsupported_action';
  end if;
  insert into private.tracking_operations (user_id, operation_id, title_id, request_hash, receipt)
  values (actor, operation_id, title_id, fingerprint, receipt);
  current_state := private.show_snapshot(actor, title_id);
  return current_state || jsonb_build_object('result', 'applied', 'can_undo', receipt is not null);
end;
$$;

alter function api.apply_tracking(uuid, timestamptz, uuid, text, jsonb) rename to apply_movie_tracking;
do $$
begin
  execute replace(
    pg_get_functiondef('api.apply_movie_tracking(uuid,timestamptz,uuid,text,jsonb)'::regprocedure),
    'apply_tracking.', 'apply_movie_tracking.');
end;
$$;
revoke execute on function api.apply_movie_tracking(uuid, timestamptz, uuid, text, jsonb) from authenticated;
create function api.apply_tracking(operation_id uuid, submitted_at timestamptz, title_id uuid, action text, payload jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  select case when exists (select 1 from api.titles t where t.id = title_id and t.kind = 'show')
    then private.apply_show_tracking(operation_id, submitted_at, title_id, action, payload)
    else api.apply_movie_tracking(operation_id, submitted_at, title_id, action, payload) end;
$$;
grant execute on function api.apply_tracking(uuid, timestamptz, uuid, text, jsonb) to authenticated;

create function private.undo_show_tracking(operation_id uuid, submitted_at timestamptz, original_operation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  original private.tracking_operations;
  prior_operation private.tracking_operations;
  tracked private.tracked_shows;
  wanted private.wanted_entries;
  mark private.episode_marks;
  skipped integer := 0;
  restored integer;
begin
  if operation_id is null or submitted_at is null or original_operation_id is null or operation_id = original_operation_id then
    raise exception using errcode = '22023', message = 'invalid_operation';
  end if;
  select * into original from private.tracking_operations o where o.user_id = actor and o.operation_id = original_operation_id;
  if original.receipt is null or original.created_at < now() - interval '24 hours'
    or submitted_at < now() - interval '30 days' or submitted_at > now() + interval '5 minutes' then
    return jsonb_build_object('result', 'expired');
  end if;
  perform 1 from api.titles t where t.id = original.title_id for share;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || original.title_id::text, 0));
  select * into prior_operation from private.tracking_operations o where o.user_id = actor and o.operation_id = undo_show_tracking.operation_id;
  if found then
    if prior_operation.undo_of is distinct from original_operation_id then
      raise exception using errcode = '22023', message = 'operation_identity_reused';
    end if;
    return private.show_snapshot(actor, original.title_id) || jsonb_build_object('result', 'applied');
  end if;
  if exists (select 1 from private.tracking_operations o where o.user_id = actor and o.undo_of = original_operation_id) then
    return private.show_snapshot(actor, original.title_id) || jsonb_build_object('result', 'applied');
  end if;
  select * into tracked from private.tracked_shows s where s.user_id = actor and s.show_id = original.title_id;
  select * into wanted from private.wanted_entries w where w.user_id = actor and w.title_id = original.title_id;
  select * into mark from private.episode_marks m where m.user_id = actor and m.episode_id = (original.receipt->>'episode_id')::uuid;
  if (original.receipt ? 'episode_after' and (tracked.intent is null or
      mark.revision is distinct from (original.receipt->>'episode_after')::bigint))
    or (original.receipt ? 'show_after' and (
      tracked.revision is distinct from (original.receipt->>'show_after')::bigint
      or (original.receipt->>'show_before' is null and exists (
        select 1 from private.episode_marks m where m.user_id = actor and m.show_id = original.title_id and m.watched
          and m.episode_id is distinct from mark.episode_id and not exists (
            select 1 from jsonb_to_recordset(original.receipt->'batch') as x(id uuid, after bigint)
            where x.id = m.episode_id and x.after = m.revision)))))
    or (original.receipt ? 'wanted_after' and (
      wanted.revision is distinct from (original.receipt->>'wanted_after')::bigint
      or (original.receipt->>'wanted_before' is not null and tracked.intent is not null
        and (not (original.receipt ? 'show_after') or original.receipt->>'show_before' is not null)))) then
    return private.show_snapshot(actor, original.title_id) || jsonb_build_object('result', 'conflict');
  end if;
  if original.receipt ? 'episode_after' then
    update private.episode_marks set watched = (original.receipt->>'episode_watched_before')::boolean,
      watched_on = (original.receipt->>'episode_day_before')::date, revision = revision + 1
    where user_id = actor and episode_id = mark.episode_id;
  end if;
  if original.receipt ? 'show_after' then
    update private.tracked_shows set intent = original.receipt->>'show_before', revision = revision + 1,
      last_activity_at = now() where user_id = actor and show_id = original.title_id;
  end if;
  if original.receipt ? 'batch' then
    if tracked.intent is null and not (original.receipt ? 'show_after') then
      return private.show_snapshot(actor, original.title_id) || jsonb_build_object('result', 'conflict');
    end if;
    update private.episode_marks m set watched = x.watched, watched_on = x.day, revision = m.revision + 1
    from jsonb_to_recordset(original.receipt->'batch') as x(id uuid, after bigint, watched boolean, day date)
    where m.user_id = actor and m.episode_id = x.id and m.revision = x.after;
    get diagnostics restored = row_count;
    skipped := jsonb_array_length(original.receipt->'batch') - restored;
  end if;
  if original.receipt ? 'wanted_after' then
    update private.wanted_entries w set added_at = (original.receipt->>'wanted_before')::timestamptz,
      revision = revision + 1 where w.user_id = actor and w.title_id = original.title_id;
  end if;
  insert into private.tracking_operations (user_id, operation_id, title_id, request_hash, undo_of)
  values (actor, operation_id, original.title_id, md5(original_operation_id::text), original_operation_id);
  return private.show_snapshot(actor, original.title_id) || jsonb_build_object('result', 'applied', 'undo_skipped', skipped);
end;
$$;

alter function api.undo_tracking(uuid, timestamptz, uuid) rename to undo_movie_tracking;
revoke execute on function api.undo_movie_tracking(uuid, timestamptz, uuid) from authenticated;
create function api.undo_tracking(operation_id uuid, submitted_at timestamptz, original_operation_id uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select case when exists (select 1 from private.tracking_operations o join api.titles t on t.id = o.title_id
    where o.user_id = private.ready_user() and o.operation_id = original_operation_id and t.kind = 'show')
    then private.undo_show_tracking(operation_id, submitted_at, original_operation_id)
    else api.undo_movie_tracking(operation_id, submitted_at, original_operation_id) end;
$$;
grant execute on function api.undo_tracking(uuid, timestamptz, uuid) to authenticated;

create or replace function api.library_page(section text, media api.media_kind default null,
  page_size int default 20, before_time timestamptz default null, before_title uuid default null)
returns table (title jsonb, activity_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with viewer as materialized (select private.ready_user() as id),
  entries as (
    select w.title_id as id, w.added_at as at from private.wanted_entries w
    join viewer on viewer.id = w.user_id where section = 'wanted' and w.added_at is not null
    union all
    select v.movie_id, max(v.logged_at) from private.movie_viewings v
    join viewer on viewer.id = v.user_id where section = 'watched_movies' and v.deleted_at is null group by v.movie_id
    union all
    select s.show_id, s.last_activity_at from private.tracked_shows s
    join viewer on viewer.id = s.user_id where section = 'watched_shows' and s.intent is not null
  ), page as (
    select t, t.id as title_id, t.kind, e.at from entries e join api.titles t on t.id = e.id
    where (media is null or media = t.kind)
      and (before_time is null or (e.at, e.id) < (before_time, before_title))
    order by e.at desc, e.id desc limit greatest(1, least(page_size, 50))
  )
  select to_jsonb(page.t) - 'overview' - 'backdrop_path' ||
    case when page.kind = 'show' then jsonb_build_object('progress', private.show_snapshot(viewer.id, page.title_id))
      else '{}'::jsonb end, page.at
  from page cross join viewer order by page.at desc, page.title_id desc;
$$;


-- ===== 20261118000600_tracking_retention.sql =====

create function private.prune_tracking_receipts() returns void
language sql set search_path = '' as $$
  update private.tracking_operations set receipt = null
  where (user_id, operation_id) in (
    select user_id, operation_id from private.tracking_operations
    where receipt is not null and created_at < now() - interval '24 hours'
    order by created_at limit 1000
  );
  delete from private.tracking_operations
  where (user_id, operation_id) in (
    select user_id, operation_id from private.tracking_operations
    where created_at < now() - interval '35 days'
    order by created_at limit 1000
  );
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('taspa-prune-tracking-receipts', '17 * * * *',
      'select private.prune_tracking_receipts()');
  end if;
end;
$$;


-- ===== 20261118000700_social_and_opinions.sql =====

create table private.follows (
  follower_id uuid not null references api.profiles on delete cascade,
  followed_id uuid not null references api.profiles on delete cascade,
  state text not null check (state in ('pending', 'accepted')),
  requested_at timestamptz not null default now(),
  primary key (follower_id, followed_id),
  check (follower_id <> followed_id)
);
create index follows_incoming on private.follows (followed_id, state, follower_id);

create table private.ratings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references api.profiles on delete cascade,
  title_id uuid not null references api.titles,
  season_id uuid,
  -- 0.5–10 in half-point steps (7.5); drawn as five stars, two points each.
  score numeric(3,1) check (score between 0.5 and 10 and score * 2 = trunc(score * 2)),
  audience private.audience not null,
  revision bigint not null check (revision > 0),
  unique nulls not distinct (user_id, title_id, season_id),
  foreign key (season_id, title_id) references api.seasons (id, show_id)
);
create index ratings_public on private.ratings (title_id, season_id, user_id) where audience = 'public' and score is not null;

create table private.reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references api.profiles on delete cascade,
  title_id uuid not null references api.titles,
  season_id uuid,
  discussion_id uuid unique,
  body text check (body is null or char_length(body) between 1 and 5000),
  spoiler boolean not null default false,
  audience private.audience not null,
  published_at timestamptz,
  moderation_hidden boolean not null default false,
  revision bigint not null check (revision > 0),
  unique nulls not distinct (user_id, title_id, season_id),
  foreign key (season_id, title_id) references api.seasons (id, show_id),
  check ((discussion_id is null) = (published_at is null))
);
create index reviews_by_title on private.reviews (title_id, season_id, published_at desc, discussion_id) where published_at is not null;
create index reviews_by_author on private.reviews (user_id, published_at desc, discussion_id) where published_at is not null;

create table private.review_likes (
  review_id uuid not null references private.reviews(discussion_id) on delete cascade,
  user_id uuid not null references api.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (review_id, user_id)
);
create table private.review_comments (
  id uuid primary key,
  review_id uuid not null references private.reviews(discussion_id) on delete cascade,
  user_id uuid not null references api.profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  spoiler boolean not null,
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  revision bigint not null default 1 check (revision > 0)
);
create index review_comment_feed on private.review_comments (review_id, created_at, id) where not hidden;

create table private.activity (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references api.profiles on delete cascade,
  kind text not null check (kind in ('review', 'rating', 'first_movie', 'first_show')),
  title_id uuid not null references api.titles,
  season_id uuid,
  review_id uuid references private.reviews(discussion_id) on delete cascade,
  rating_id uuid references private.ratings on delete cascade,
  audience private.audience not null,
  created_at timestamptz not null default now(),
  source_key text not null unique,
  foreign key (season_id, title_id) references api.seasons (id, show_id)
);
create index activity_by_actor on private.activity (actor_id, created_at desc, id desc);

create table private.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references api.profiles on delete set null,
  target_id uuid not null,
  target_type text not null check (target_type in ('profile', 'review', 'comment')),
  reason text not null check (char_length(reason) between 1 and 300),
  state text not null default 'open' check (state in ('open', 'resolved', 'dismissed')),
  created_at timestamptz not null default now(),
  unique (reporter_id, target_type, target_id)
);
create index report_queue on private.reports (created_at, id) where state = 'open';

create table private.notification_preferences (
  user_id uuid not null references api.profiles on delete cascade,
  category text not null check (category in ('social', 'episodes', 'wanted')),
  inbox boolean not null default true,
  push boolean not null default false,
  primary key (user_id, category)
);
create table private.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references api.profiles on delete cascade,
  kind text not null check (kind in ('follow', 'follow_request', 'follow_accepted', 'like', 'comment', 'episode', 'wanted_release')),
  group_key text not null,
  actor_id uuid references api.profiles on delete cascade,
  target_id uuid not null,
  event_at timestamptz not null default now(),
  read_at timestamptz,
  generation bigint not null default 1,
  unique (recipient_id, kind, group_key)
);
create index inbox_by_owner on private.notifications (recipient_id, event_at desc, id desc);

create function private.can_see(subject uuid, allowed private.audience) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.profile_visible(subject) and (
    subject = (select auth.uid())
    or (allowed = 'public' and exists (select 1 from private.profile_settings s where s.user_id = subject and not s.profile_private))
    or (allowed in ('followers', 'public') and exists (select 1 from private.follows f
        where f.followed_id = subject and f.follower_id = (select auth.uid()) and f.state = 'accepted'))
  );
$$;

create function private.season_reveal_required(season uuid) returns boolean
language sql stable set search_path = '' as $$
  select season is not null and not exists (
    select 1 from api.seasons s join api.titles t on t.id = s.show_id
    where s.id = season and s.available and s.season_number > 0 and s.loaded_at is not null
     and (t.source_release_status in ('Ended', 'Canceled') or exists (
       select 1 from api.seasons later where later.show_id = s.show_id and later.available
       and later.season_number > s.season_number and private.episode_released(later.first_release_day)
     ))
     and (select count(*) from api.episodes e where e.season_id = season and e.available) >= greatest(1, s.expected_episodes)
     and not exists (select 1 from api.episodes e left join private.episode_marks m
       on m.episode_id = e.id and m.user_id = (select auth.uid())
       where e.season_id = season and e.available and (not private.episode_released(e.release_day) or not coalesce(m.watched, false)))
  );
$$;

create function private.review_visible(review private.reviews) returns boolean
language sql stable set search_path = '' as $$
  select review.discussion_id is not null and not review.moderation_hidden
    and private.can_see(review.user_id, review.audience);
$$;

create function private.notify(recipient uuid, event_kind text, subject uuid, sender uuid, group_value text)
returns void language sql set search_path = '' as $$
  insert into private.notifications as n (recipient_id, kind, group_key, actor_id, target_id)
  select recipient, event_kind, group_value, sender, subject
  where (sender is null or sender <> recipient) and coalesce((
    select p.inbox from private.notification_preferences p where p.user_id = recipient and p.category =
      case event_kind when 'episode' then 'episodes' when 'wanted_release' then 'wanted' else 'social' end
  ), true)
  on conflict (recipient_id, kind, group_key) do update
  set event_at = now(), read_at = null, generation = n.generation + 1, actor_id = excluded.actor_id;
$$;

create function api.profile_page(target uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('user_id', p.user_id, 'handle', p.handle, 'display_name', p.display_name,
    'private', s.profile_private, 'own', p.user_id = (select auth.uid()),
    'can_read', private.can_see(p.user_id, 'public'),
    'can_read_library', private.can_see(p.user_id, s.library_audience),
    'relationship', (select f.state from private.follows f where f.follower_id = (select auth.uid()) and f.followed_id = p.user_id))
  || case when private.can_see(p.user_id, 'public') then jsonb_build_object('bio', s.bio,
    'followers', (select count(*) from private.follows f where f.followed_id = p.user_id and f.state = 'accepted' and private.profile_visible(f.follower_id)),
    'following', (select count(*) from private.follows f where f.follower_id = p.user_id and f.state = 'accepted' and private.profile_visible(f.followed_id)))
    else '{}'::jsonb end
  || case when private.can_see(p.user_id, s.library_audience) then jsonb_build_object(
    'movies', (select count(distinct movie_id) from private.movie_viewings where user_id = p.user_id and deleted_at is null),
    'shows', (select count(distinct show_id) from private.episode_marks where user_id = p.user_id and watched),
    'episodes', (select count(*) from private.episode_marks where user_id = p.user_id and watched))
    else '{}'::jsonb end
  || case when p.user_id = (select auth.uid()) then jsonb_build_object(
    'library_audience', s.library_audience, 'tracking_activity', s.tracking_activity, 'market', s.market, 'timezone', s.timezone)
    else '{}'::jsonb end
  from api.profiles p join private.profile_settings s using (user_id)
  where p.user_id = target and private.profile_visible(p.user_id);
$$;
grant execute on function api.profile_page(uuid) to anon, authenticated;

create function api.profile_update(fields jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  settings private.profile_settings;
  new_private boolean;
  new_audience private.audience;
begin
  if jsonb_typeof(fields) is distinct from 'object' or octet_length(fields::text) > 4096
    or (fields ? 'timezone' and fields->>'timezone' is not null
        and not exists (select 1 from pg_timezone_names where name = fields->>'timezone')) then
    raise exception using errcode = '22023', message = 'invalid_profile_settings';
  end if;
  select * into settings from private.profile_settings s where s.user_id = actor for update;
  new_private := coalesce((fields->>'private')::boolean, settings.profile_private);
  new_audience := coalesce((fields->>'library_audience')::private.audience, settings.library_audience);
  if new_private and new_audience = 'public' then new_audience := 'followers'; end if;
  update private.profile_settings set
    bio = case when fields ? 'bio' then nullif(btrim(fields->>'bio'), '') else settings.bio end,
    profile_private = new_private, library_audience = new_audience,
    tracking_activity = coalesce((fields->>'tracking_activity')::boolean, settings.tracking_activity),
    market = case when fields ? 'market' then fields->>'market' else settings.market end,
    timezone = case when fields ? 'timezone' then fields->>'timezone' else settings.timezone end
  where user_id = actor;
  if new_private and not settings.profile_private then
    update private.ratings set audience = 'followers', revision = revision + 1 where user_id = actor and audience = 'public';
    update private.reviews set audience = 'followers', revision = revision + 1 where user_id = actor and audience = 'public';
    update private.activity set audience = 'followers' where actor_id = actor and audience = 'public';
  end if;
  if fields ? 'display_name' then
    update api.profiles set display_name = nullif(btrim(fields->>'display_name'), '') where user_id = actor;
  end if;
  return api.profile_page(actor);
end;
$$;
grant execute on function api.profile_update(jsonb) to authenticated;

create function api.relationship_page(target uuid, list_type text, before_handle text default '',
  page_size int default 20) returns table (user_id uuid, handle text, display_name text)
language sql stable security definer set search_path = '' as $$
  select p.user_id, p.handle, p.display_name
  from private.follows f join api.profiles p on p.user_id = case
    when list_type = 'following' then f.followed_id else f.follower_id end
  where ((list_type = 'following' and f.follower_id = target and f.state = 'accepted')
    or (list_type = 'followers' and f.followed_id = target and f.state = 'accepted')
    or (list_type = 'requests' and f.followed_id = target and f.state = 'pending' and target = (select auth.uid())))
    and private.can_see(target, 'public') and private.profile_visible(p.user_id) and p.handle > before_handle
  order by p.handle limit greatest(1, least(page_size, 50));
$$;
grant execute on function api.relationship_page(uuid, text, text, int) to anon, authenticated;

create function private.lock_pair(first_user uuid, second_user uuid) returns void
language sql set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('social:' || least(first_user, second_user)::text || ':' || greatest(first_user, second_user)::text, 0));
$$;

create function api.set_follow(target uuid, follow boolean) returns text
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); outcome text;
begin
  if target is null or target = actor or follow is null then raise exception using errcode = '22023', message = 'invalid_follow'; end if;
  perform private.lock_pair(actor, target);
  if not private.profile_visible(target) then raise exception using errcode = '42501', message = 'unavailable'; end if;
  if not follow then
    delete from private.follows where follower_id = actor and followed_id = target;
    return null;
  end if;
  insert into private.follows (follower_id, followed_id, state)
  select actor, target, case when profile_private then 'pending' else 'accepted' end
  from private.profile_settings where user_id = target
  on conflict do nothing returning state into outcome;
  if outcome is not null then
    perform private.notify(target, case outcome when 'pending' then 'follow_request' else 'follow' end,
      actor, actor, actor::text);
  else
    select state into outcome from private.follows where follower_id = actor and followed_id = target;
  end if;
  return outcome;
end;
$$;
grant execute on function api.set_follow(uuid, boolean) to authenticated;

create function api.resolve_follow_request(target uuid, decision text) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user();
begin
  if target is null or target = actor then raise exception using errcode = '22023', message = 'invalid_follow'; end if;
  perform private.lock_pair(actor, target);
  if not private.profile_visible(target) then raise exception using errcode = '42501', message = 'unavailable'; end if;
  if decision = 'approve' then
    update private.follows set state = 'accepted' where follower_id = target and followed_id = actor and state = 'pending';
    if found then perform private.notify(target, 'follow_accepted', actor, actor, actor::text); end if;
  elsif decision in ('decline', 'remove') then
    delete from private.follows where follower_id = target and followed_id = actor
      and state = case decision when 'decline' then 'pending' else 'accepted' end;
  else
    raise exception using errcode = '22023', message = 'invalid_follow_decision';
  end if;
end;
$$;
grant execute on function api.resolve_follow_request(uuid, text) to authenticated;

create function api.set_block(target uuid, blocked boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user();
begin
  if target is null or target = actor or blocked is null then raise exception using errcode = '22023', message = 'invalid_block'; end if;
  perform private.lock_pair(actor, target);
  if blocked then
    if not private.profile_visible(target) and not exists (
      select 1 from private.blocks b where b.blocker_id = actor and b.blocked_id = target
    ) then raise exception using errcode = '42501', message = 'unavailable'; end if;
    insert into private.blocks (blocker_id, blocked_id) values (actor, target) on conflict do nothing;
    delete from private.follows where (follower_id = actor and followed_id = target) or (follower_id = target and followed_id = actor);
  else
    delete from private.blocks where blocker_id = actor and blocked_id = target;
  end if;
end;
$$;
grant execute on function api.set_block(uuid, boolean) to authenticated;

create function api.blocked_profiles() returns table (user_id uuid, handle text)
language sql stable security definer set search_path = '' as $$
  select p.user_id, p.handle from private.blocks b join api.profiles p on p.user_id = b.blocked_id
  where b.blocker_id = private.ready_user() order by p.handle;
$$;
grant execute on function api.blocked_profiles() to authenticated;


-- ===== 20261118000800_notifications.sql =====

create table private.device_tokens (
  installation_id uuid primary key,
  user_id uuid not null references api.profiles on delete cascade,
  token text not null check (char_length(token) between 20 and 4096),
  binding_secret_hash text not null check (char_length(binding_secret_hash) = 64),
  revision bigint not null default 1,
  lease_expires_at timestamptz not null,
  disabled_at timestamptz
);
create unique index device_active_token on private.device_tokens(token) where disabled_at is null;
create index device_owner on private.device_tokens(user_id, lease_expires_at) where disabled_at is null;

create table private.push_deliveries (
  notification_id uuid not null references private.notifications on delete cascade,
  installation_id uuid not null references private.device_tokens on delete cascade,
  generation bigint not null,
  binding_revision bigint not null,
  attempts int not null default 0,
  due_at timestamptz not null default now(),
  lease_id uuid,
  lease_until timestamptz,
  completed_at timestamptz,
  outcome text,
  primary key (notification_id, installation_id, generation)
);
create index push_pending on private.push_deliveries(due_at, notification_id) where completed_at is null;

create function api.register_device(installation uuid, binding_secret text, registration_token text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  verifier text := encode(sha256(convert_to(binding_secret, 'UTF8')), 'hex');
begin
  if installation is null or binding_secret is null or binding_secret !~ '^[a-f0-9]{64}$'
    or registration_token is null or char_length(registration_token) not between 20 and 4096
    or registration_token ~ '[[:space:]]' then
    raise exception using errcode = '22023', message = 'invalid_device';
  end if;
  insert into private.device_tokens as d (installation_id, user_id, token, binding_secret_hash, lease_expires_at)
  values (installation, actor, registration_token, verifier, now() + interval '30 days')
  on conflict (installation_id) do update set
    user_id = excluded.user_id, token = excluded.token, lease_expires_at = excluded.lease_expires_at,
    revision = case when d.user_id = excluded.user_id and d.token = excluded.token and d.disabled_at is null
      then d.revision else d.revision + 1 end, disabled_at = null
  where d.binding_secret_hash = verifier;
  if not found then raise exception using errcode = '42501', message = 'device_binding_mismatch'; end if;
end;
$$;
grant execute on function api.register_device(uuid, text, text) to authenticated;

create function api.unregister_device(installation uuid, binding_secret text)
returns void language sql security definer set search_path = '' as $$
  update private.device_tokens set disabled_at = now(), revision = revision + 1
  where installation_id = installation and user_id = (select auth.uid()) and disabled_at is null
  and binding_secret_hash = encode(sha256(convert_to(binding_secret, 'UTF8')), 'hex');
$$;
grant execute on function api.unregister_device(uuid, text) to authenticated;

create function private.notification_category(kind_value text) returns text
language sql immutable set search_path = '' as $$
  select case kind_value when 'episode' then 'episodes' when 'wanted_release' then 'wanted' else 'social' end;
$$;

create function private.notification_valid(n private.notifications) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from private.profile_settings s where s.user_id = n.recipient_id and s.lifecycle = 'ready')
    and (n.actor_id is null or (not exists (
      select 1 from private.blocks b
      where (b.blocker_id, b.blocked_id) in ((n.actor_id,n.recipient_id),(n.recipient_id,n.actor_id))
    ) and exists (select 1 from private.profile_settings s where s.user_id = n.actor_id and s.lifecycle = 'ready')))
    and case n.kind
      when 'follow' then exists (select 1 from private.follows f where f.follower_id = n.actor_id and f.followed_id = n.recipient_id and f.state = 'accepted')
      when 'follow_request' then exists (select 1 from private.follows f where f.follower_id = n.actor_id and f.followed_id = n.recipient_id and f.state = 'pending')
      when 'follow_accepted' then exists (select 1 from private.follows f where f.follower_id = n.recipient_id and f.followed_id = n.actor_id and f.state = 'accepted')
      when 'like' then exists (
        select 1 from private.reviews r join private.review_likes l on l.review_id = r.discussion_id
        where r.discussion_id = n.target_id and r.user_id = n.recipient_id and not r.moderation_hidden
          and l.user_id = n.actor_id and (r.audience = 'public' or (r.audience = 'followers' and exists (
            select 1 from private.follows f where f.follower_id = n.actor_id and f.followed_id = n.recipient_id and f.state = 'accepted')))
      )
      when 'comment' then exists (
        select 1 from private.reviews r join private.review_comments c on c.review_id = r.discussion_id
        where r.discussion_id = n.target_id and r.user_id = n.recipient_id and not r.moderation_hidden
          and c.user_id = n.actor_id and not c.hidden and (r.audience = 'public' or (r.audience = 'followers' and exists (
            select 1 from private.follows f where f.follower_id = n.actor_id and f.followed_id = n.recipient_id and f.state = 'accepted')))
      )
      when 'episode' then exists (select 1 from private.tracked_shows s where s.user_id = n.recipient_id and s.show_id = n.target_id and s.intent = 'watching')
      when 'wanted_release' then exists (select 1 from private.wanted_entries w where w.user_id = n.recipient_id and w.title_id = n.target_id and w.added_at is not null)
      else false
    end;
$$;

create function api.notification_preferences() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_object_agg(c.name, jsonb_build_object('inbox', coalesce(p.inbox, true), 'push', coalesce(p.push, false)))
  from (values ('social'), ('episodes'), ('wanted')) c(name)
  left join private.notification_preferences p on p.user_id = (select private.ready_user()) and p.category = c.name;
$$;
grant execute on function api.notification_preferences() to authenticated;

create function api.set_notification_preferences(category_name text, inbox_enabled boolean, push_enabled boolean)
returns void language sql security definer set search_path = '' as $$
  insert into private.notification_preferences (user_id, category, inbox, push)
  values (private.ready_user(), category_name, inbox_enabled, push_enabled)
  on conflict (user_id,category) do update set inbox = excluded.inbox, push = excluded.push;
$$;
grant execute on function api.set_notification_preferences(text, boolean, boolean) to authenticated;


create function api.mark_inbox_read(item_id uuid default null, through_time timestamptz default null, through_id uuid default null)
returns void language sql security definer set search_path = '' as $$
  update private.notifications n set read_at = now()
  where n.recipient_id = (select private.ready_user()) and n.read_at is null
    and ((item_id is not null and n.id = item_id)
      or (item_id is null and (n.event_at,n.id) <= (through_time,through_id)));
$$;
grant execute on function api.mark_inbox_read(uuid, timestamptz, uuid) to authenticated;

create function api.push_claim() returns table (notification_id uuid, installation_id uuid, generation bigint, lease_id uuid)
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.push_deliveries (notification_id, installation_id, generation, binding_revision)
  select n.id, d.installation_id, n.generation, d.revision
  from private.notifications n
  join private.notification_preferences p on p.user_id = n.recipient_id and p.category = private.notification_category(n.kind) and p.inbox and p.push
  join private.device_tokens d on d.user_id = n.recipient_id and d.disabled_at is null and d.lease_expires_at > now()
  where n.event_at >= now() - interval '2 hours' and n.read_at is null and private.notification_valid(n)
   and not exists (select 1 from private.push_deliveries q
     where (q.notification_id,q.installation_id,q.generation) = (n.id,d.installation_id,n.generation))
  order by n.event_at limit 100
  on conflict on constraint push_deliveries_pkey do nothing;

  return query with batch as (
    select q.notification_id,q.installation_id,q.generation
    from private.push_deliveries q where q.completed_at is null and q.due_at <= now()
      and (q.lease_until is null or q.lease_until < now())
    order by q.due_at limit 20 for update skip locked
  ) update private.push_deliveries q set lease_id = gen_random_uuid(), lease_until = now() + interval '2 minutes', attempts = attempts + 1
  from batch b where (q.notification_id,q.installation_id,q.generation) = (b.notification_id,b.installation_id,b.generation)
  returning q.notification_id,q.installation_id,q.generation,q.lease_id;
end;
$$;
grant execute on function api.push_claim() to service_role;

create function api.push_destination(claim uuid) returns text
language sql stable security definer set search_path = '' as $$
  select d.token from private.push_deliveries q
  join private.device_tokens d on d.installation_id = q.installation_id and d.revision = q.binding_revision
  join private.notifications n on n.id = q.notification_id and n.recipient_id = d.user_id and n.generation = q.generation
  join private.notification_preferences p on p.user_id = d.user_id and p.category = private.notification_category(n.kind) and p.inbox and p.push
  where q.lease_id = claim and q.lease_until >= now() and q.completed_at is null
    and d.disabled_at is null and d.lease_expires_at > now()
    and n.read_at is null and n.event_at >= now() - interval '2 hours' and private.notification_valid(n);
$$;
grant execute on function api.push_destination(uuid) to service_role;

create function api.push_finish(claim uuid, result_code text) returns void
language plpgsql security definer set search_path = '' as $$
declare delivery private.push_deliveries;
begin
  if result_code is null or result_code not in ('sent','skipped','unregistered','rejected','retry') then
    raise exception using errcode = '22023', message = 'invalid_delivery_result';
  end if;
  select * into delivery from private.push_deliveries q where q.lease_id = claim and q.completed_at is null for update;
  if not found then return; end if;
  if result_code = 'unregistered' then
    update private.device_tokens d set disabled_at = now(), revision = revision + 1
    where d.installation_id = delivery.installation_id and d.revision = delivery.binding_revision;
  end if;
  update private.push_deliveries set lease_id = null, lease_until = null, outcome = result_code,
    due_at = now() + make_interval(mins => least(60, 2 ^ least(delivery.attempts,5))::int),
    completed_at = case when result_code <> 'retry' or delivery.attempts >= 6 then now() end
  where lease_id = claim;
end;
$$;
grant execute on function api.push_finish(uuid, text) to service_role;


-- ===== 20261118000900_maintenance_schedule.sql =====

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
    and exists (select 1 from pg_available_extensions where name = 'pg_net')
    and exists (select 1 from pg_available_extensions where name = 'supabase_vault') then
    create extension if not exists pg_cron;
    create extension if not exists pg_net;
    create extension if not exists supabase_vault;
    perform cron.schedule('taspa-push-outbox', '*/5 * * * *', $task$
      select net.http_post(
        url := base.decrypted_secret || '/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type','application/json','x-taspa-worker',worker.decrypted_secret),
        body := '{"job":"push"}'::jsonb,
        timeout_milliseconds := 60000
      )
      from vault.decrypted_secrets base, vault.decrypted_secrets worker
      where base.name = 'taspa_project_url' and worker.name = 'taspa_worker_key';
    $task$);
  end if;
end;
$$;


-- ===== 20261118001000_opinion_and_social_api.sql =====

create function private.allowed_audience(actor uuid, choice private.audience) returns private.audience
language sql stable set search_path = '' as $$
  select case when choice = 'public' and s.profile_private then 'followers'::private.audience
              else choice end
  from private.profile_settings s where s.user_id = actor;
$$;

create function private.check_opinion_target(title uuid, season uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not exists (select 1 from api.titles t where t.id = title and t.catalog_state = 'available')
    or (season is not null and not exists (select 1 from api.seasons s where s.id = season and s.show_id = title and s.available)) then
    raise exception using errcode = '22023', message = 'opinion_target_unavailable';
  end if;
end;
$$;

create function api.title_opinions(title uuid, season uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('rating_count', (
      select count(*) from private.ratings r join private.profile_settings s on s.user_id = r.user_id
      where r.title_id = title and r.season_id is not distinct from season and r.score is not null
        and r.audience = 'public' and s.lifecycle = 'ready' and not s.profile_private
    ), 'average', (
      select case when count(*) >= 5 then round(avg(r.score) / 2, 1) end
      from private.ratings r join private.profile_settings s on s.user_id = r.user_id
      where r.title_id = title and r.season_id is not distinct from season and r.score is not null
        and r.audience = 'public' and s.lifecycle = 'ready' and not s.profile_private
    ), 'my_rating', (
      select jsonb_build_object('score', r.score, 'audience', r.audience, 'revision', r.revision)
      from private.ratings r
      where r.user_id = (select auth.uid()) and private.profile_visible(r.user_id)
        and r.title_id = title and r.season_id is not distinct from season
    ), 'my_review', (
      select jsonb_build_object('body', r.body, 'audience', r.audience, 'spoiler', r.spoiler,
        'discussion_id', r.discussion_id, 'revision', r.revision)
      from private.reviews r
      where r.user_id = (select auth.uid()) and private.profile_visible(r.user_id)
        and r.title_id = title and r.season_id is not distinct from season
    ))
  where exists (select 1 from api.titles t where t.id = title and t.catalog_state = 'available');
$$;
grant execute on function api.title_opinions(uuid, uuid) to anon, authenticated;

create function api.set_rating(title uuid, season uuid, score_value numeric, audience_value text,
  observed_revision bigint, share boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); current_rating private.ratings; effective private.audience;
begin
  perform private.check_opinion_target(title, season);
  perform 1 from private.profile_settings where user_id = actor for update;
  effective := private.allowed_audience(actor, audience_value::private.audience);
  select * into current_rating from private.ratings r where r.user_id = actor and r.title_id = title and r.season_id is not distinct from season;
  if coalesce(current_rating.revision, 0) is distinct from observed_revision then
    raise exception using errcode = '40001', message = 'opinion_conflict';
  end if;
  insert into private.ratings as r (user_id,title_id,season_id,score,audience,revision)
  values (actor,title,season,score_value,effective,1)
  on conflict (user_id,title_id,season_id) do update set
    score = excluded.score, audience = excluded.audience, revision = r.revision + 1
  returning * into current_rating;
  if share and score_value is not null and effective <> 'only_me' then
    insert into private.activity(actor_id,kind,title_id,season_id,rating_id,audience,source_key)
    values(actor,'rating',title,season,current_rating.id,effective,'rating:' || current_rating.id)
    on conflict (source_key) do update set audience = excluded.audience;
  end if;
  return api.title_opinions(title, season);
end;
$$;
grant execute on function api.set_rating(uuid, uuid, numeric, text, bigint, boolean) to authenticated;

create function api.save_review(title uuid, season uuid, content text, has_spoiler boolean,
  audience_value text, observed_revision bigint, discussion uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  old private.reviews;
  effective private.audience;
  discussion_value uuid;
  public_at timestamptz;
begin
  perform private.check_opinion_target(title, season);
  perform 1 from private.profile_settings where user_id = actor for update;
  effective := private.allowed_audience(actor, audience_value::private.audience);
  select * into old from private.reviews r where r.user_id = actor and r.title_id = title and r.season_id is not distinct from season;
  if coalesce(old.revision, 0) is distinct from observed_revision then
    raise exception using errcode = '40001', message = 'opinion_conflict';
  end if;
  content := nullif(btrim(content), '');
  if content is not null and effective <> 'only_me' then
    discussion_value := coalesce(old.discussion_id, discussion);
    if discussion_value is null then raise exception using errcode = '22023', message = 'discussion_required'; end if;
    public_at := coalesce(old.published_at, now());
  end if;
  if old.discussion_id is not null and discussion_value is null then
    delete from private.activity where review_id = old.discussion_id;
    delete from private.review_comments where review_id = old.discussion_id;
    delete from private.review_likes where review_id = old.discussion_id;
  end if;
  insert into private.reviews as r(user_id,title_id,season_id,discussion_id,body,spoiler,audience,published_at,revision)
  values(actor,title,season,discussion_value,content,coalesce(has_spoiler,false),effective,public_at,1)
  on conflict (user_id,title_id,season_id) do update set
    discussion_id = excluded.discussion_id, body = excluded.body, spoiler = excluded.spoiler,
    audience = excluded.audience, published_at = excluded.published_at, revision = r.revision + 1;
  if discussion_value is not null then
    insert into private.activity(actor_id,kind,title_id,season_id,review_id,audience,source_key,created_at)
    values(actor,'review',title,season,discussion_value,effective,'review:' || discussion_value,public_at)
    on conflict (source_key) do update set audience = excluded.audience;
  end if;
  return api.title_opinions(title, season);
end;
$$;
grant execute on function api.save_review(uuid, uuid, text, boolean, text, bigint, uuid) to authenticated;

create function private.review_card(r private.reviews, reveal boolean default false) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', r.discussion_id, 'author_id', r.user_id,
    'handle', p.handle, 'title_id', r.title_id, 'title', t.display_title, 'season_id', r.season_id,
    'season', s.display_title, 'published_at', r.published_at, 'protected', r.spoiler or private.season_reveal_required(r.season_id),
    'body', case when reveal or not r.spoiler and not private.season_reveal_required(r.season_id) then r.body end,
    'score', (select score from private.ratings rate where rate.user_id = r.user_id and rate.title_id = r.title_id
      and rate.season_id is not distinct from r.season_id and private.can_see(rate.user_id,rate.audience)),
    'likes', (select count(*) from private.review_likes l where l.review_id = r.discussion_id and private.profile_visible(l.user_id)),
    'liked', exists (select 1 from private.review_likes l where l.review_id = r.discussion_id and l.user_id = (select auth.uid())),
    'public', r.audience = 'public' and not settings.profile_private
  )
  from api.profiles p join private.profile_settings settings on settings.user_id = p.user_id
  join api.titles t on t.id = r.title_id
  left join api.seasons s on s.id = r.season_id
  where p.user_id = r.user_id and t.catalog_state = 'available';
$$;

create function api.opinion_page(title uuid default null, season uuid default null, author uuid default null,
  before_time timestamptz default null, before_id uuid default null) returns setof jsonb
language sql stable security definer set search_path = '' as $$
  select private.review_card(r)
  from private.reviews r join api.titles t on t.id = r.title_id and t.catalog_state = 'available'
  where private.review_visible(r) and (title is not null or author is not null)
    and (title is null or (r.title_id = title and r.season_id is not distinct from season))
    and (author is null or r.user_id = author)
    and (before_time is null or (r.published_at,r.discussion_id) < (before_time,before_id))
  order by r.published_at desc,r.discussion_id desc limit 20;
$$;
grant execute on function api.opinion_page(uuid, uuid, uuid, timestamptz, uuid) to anon, authenticated;

create function api.review_detail(review uuid, reveal boolean default false, reveal_comment uuid default null,
  after_time timestamptz default null, after_id uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select private.review_card(r,reveal) || jsonb_build_object('comments',
    case when reveal or (not r.spoiler and not private.season_reveal_required(r.season_id)) then (
      select coalesce(jsonb_agg(row_data order by created_at,id),'[]'::jsonb) from (
        select c.created_at,c.id,jsonb_build_object('id',c.id,'author_id',c.user_id,'handle',p.handle,
          'body',case when not c.spoiler or c.id = reveal_comment then c.body end,
          'spoiler',c.spoiler,'created_at',c.created_at,'revision',c.revision) as row_data
        from private.review_comments c join api.profiles p on p.user_id = c.user_id
        where c.review_id = r.discussion_id and not c.hidden and private.profile_visible(c.user_id)
          and (after_time is null or (c.created_at,c.id) > (after_time,after_id))
        order by c.created_at,c.id limit 30
      ) comments
    ) else '[]'::jsonb end)
  from private.reviews r where r.discussion_id = review and private.review_visible(r);
$$;
grant execute on function api.review_detail(uuid, boolean, uuid, timestamptz, uuid) to anon, authenticated;

create function api.set_review_like(review uuid, liked boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); target private.reviews;
begin
  select * into target from private.reviews where discussion_id = review;
  if not found or liked is null then raise exception using errcode = '42501', message = 'unavailable'; end if;
  perform private.lock_pair(actor,target.user_id);
  select * into target from private.reviews where discussion_id = review for share;
  if not found or not private.review_visible(target) then raise exception using errcode = '42501', message = 'unavailable'; end if;
  if liked then
    insert into private.review_likes (review_id,user_id) values (review,actor) on conflict do nothing;
    if found then perform private.notify(target.user_id,'like',review,actor,review::text); end if;
  else
    delete from private.review_likes where review_id = review and user_id = actor;
  end if;
end;
$$;
grant execute on function api.set_review_like(uuid, boolean) to authenticated;

create function api.set_comment(review uuid, comment uuid, action text, content text default null,
  spoiler boolean default false, observed_revision bigint default null, reveal boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); target private.reviews;
begin
  select * into target from private.reviews where discussion_id = review;
  if not found or comment is null then raise exception using errcode = '42501', message = 'unavailable'; end if;
  perform private.lock_pair(actor,target.user_id);
  select * into target from private.reviews where discussion_id = review for share;
  if not found or not private.review_visible(target)
    or (not reveal and (target.spoiler or private.season_reveal_required(target.season_id))) then
    raise exception using errcode = '42501', message = 'unavailable';
  end if;
  if action = 'add' then
    insert into private.review_comments(id,review_id,user_id,body,spoiler)
    values(comment,review,actor,btrim(content),spoiler) on conflict do nothing;
    if found then perform private.notify(target.user_id,'comment',review,actor,comment::text); end if;
  elsif action = 'edit' then
    update private.review_comments c set body = btrim(content), spoiler = set_comment.spoiler, revision = c.revision + 1
    where c.id = comment and c.review_id = review and c.user_id = actor and c.revision = observed_revision and not c.hidden;
    if not found then raise exception using errcode = '40001', message = 'comment_conflict'; end if;
  elsif action = 'remove' then
    delete from private.review_comments c where c.id = comment and c.review_id = review and c.user_id = actor and c.revision = observed_revision;
  elsif action = 'hide' and target.user_id = actor then
    update private.review_comments c set hidden = true, revision = c.revision + 1
    where c.id = comment and c.review_id = review and c.revision = observed_revision
      and private.profile_visible(c.user_id);
  else raise exception using errcode = '42501', message = 'unavailable';
  end if;
end;
$$;
grant execute on function api.set_comment(uuid, uuid, text, text, boolean, bigint, boolean) to authenticated;

create function api.submit_report(target uuid, kind_value text, reason_value text) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user();
begin
  if not (case kind_value when 'profile' then private.profile_visible(target)
    when 'review' then exists (select 1 from private.reviews r where r.discussion_id = target and private.review_visible(r))
    when 'comment' then exists (select 1 from private.review_comments c join private.reviews r on r.discussion_id = c.review_id
      where c.id = target and private.profile_visible(c.user_id) and not c.hidden and private.review_visible(r))
    else false end) then raise exception using errcode = '42501', message = 'unavailable'; end if;
  if (select count(*) from private.reports where reporter_id = actor and created_at > now() - interval '1 hour') >= 10 then
    raise exception using errcode = '22023', message = 'report_limit';
  end if;
  insert into private.reports(reporter_id,target_id,target_type,reason)
  values(actor,target,kind_value,btrim(reason_value)) on conflict do nothing;
end;
$$;
grant execute on function api.submit_report(uuid, text, text) to authenticated;

create function api.following_feed(before_time timestamptz default null, before_id uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id',a.id,'created_at',a.created_at,'kind',a.kind,'actor_id',a.actor_id,
    'handle',p.handle,'title_id',t.id,'title',t.display_title,'tmdb_id',t.tmdb_id,'media',t.kind,
    'season',s.display_title,'review',case when a.kind = 'review' then private.review_card(r) end,
    'score',case when a.kind = 'rating' then rating.score end)
  from private.activity a
  join private.follows f on f.followed_id = a.actor_id and f.follower_id = (select private.ready_user()) and f.state = 'accepted'
  join api.profiles p on p.user_id = a.actor_id
  join api.titles t on t.id = a.title_id and t.catalog_state = 'available'
  join private.profile_settings settings on settings.user_id = a.actor_id
  left join private.reviews r on r.discussion_id = a.review_id
  left join private.ratings rating on rating.id = a.rating_id
  left join api.seasons s on s.id = a.season_id
  where private.can_see(a.actor_id,a.audience)
    and case a.kind
      when 'review' then private.review_visible(r)
      when 'rating' then rating.score is not null and private.can_see(rating.user_id,rating.audience)
      when 'first_movie' then settings.tracking_activity and private.can_see(a.actor_id,settings.library_audience)
        and exists (select 1 from private.movie_viewings m where m.user_id = a.actor_id and m.movie_id = a.title_id and m.deleted_at is null)
      when 'first_show' then settings.tracking_activity and private.can_see(a.actor_id,settings.library_audience)
        and exists (select 1 from private.tracked_shows sh where sh.user_id = a.actor_id and sh.show_id = a.title_id and sh.intent is not null)
      else false end
    and (before_time is null or (a.created_at,a.id) < (before_time,before_id))
  order by a.created_at desc,a.id desc limit 20;
$$;
grant execute on function api.following_feed(timestamptz, uuid) to authenticated;


-- ===== 20261118001100_public_library_and_activity.sql =====

create function api.profile_library(owner_id uuid, section text, sort text default 'activity',
  ascending boolean default false, before_value numeric default null, before_title uuid default null)
returns table (title jsonb, activity_at timestamptz, sort_value numeric)
language sql stable security definer set search_path = '' as $$
  with owner_allowed as materialized (
    select s.user_id from private.profile_settings s
    where s.user_id = owner_id and private.can_see(s.user_id, s.library_audience)
  ), entries as (
    select w.title_id as id, w.added_at as at from private.wanted_entries w
    join owner_allowed a on a.user_id = w.user_id where section = 'wanted' and w.added_at is not null
    union all
    select v.movie_id, max(v.logged_at) from private.movie_viewings v
    join owner_allowed a on a.user_id = v.user_id where section = 'watched_movies' and v.deleted_at is null group by v.movie_id
    union all
    select s.show_id, s.last_activity_at from private.tracked_shows s
    join owner_allowed a on a.user_id = s.user_id where section = 'watched_shows' and s.intent is not null
  ), data as (
    select t, e.id, e.at,
      -- Only a score the viewer may see; a hidden one must not leak through the order.
      (select r.score from private.ratings r
        where r.user_id = owner_id and r.title_id = e.id and r.season_id is null and r.score is not null
          and private.can_see(r.user_id, r.audience)) as score,
      case sort
        when 'activity' then extract(epoch from e.at)::numeric
        when 'imdb' then (select (m.details->'rating'->>'value')::numeric from private.title_metadata m where m.title_id = e.id)
        when 'release' then extract(epoch from t.first_release_day)::numeric
        when 'episodes' then (select sum(s.expected_episodes) from api.seasons s
          where s.show_id = e.id and s.available and s.season_number > 0)
      end as raw
    from entries e join api.titles t on t.id = e.id and t.catalog_state = 'available'
    where sort in ('activity','rating','imdb','release','episodes')
  ), keyed as (
    -- One ascending key for either direction; titles without a value always go last.
    select *, coalesce(case when ascending then 1 else -1 end * case when sort = 'rating' then score else raw end, 1e15) as value_key
    from data
  )
  select to_jsonb(k.t) - 'overview' - 'backdrop_path' ||
    case when (k.t).kind = 'show' and section = 'watched_shows' then jsonb_build_object('progress',
      private.show_snapshot(owner_id,k.id) - 'next' - 'show_revision' - 'wanted_revision' - 'wanted' - 'viewing_count')
      else '{}'::jsonb end
    || case when k.score is not null then jsonb_build_object('score', k.score) else '{}'::jsonb end,
    k.at, k.value_key
  from keyed k
  where before_title is null or (k.value_key, k.id) > (before_value, before_title)
  order by k.value_key, k.id limit 20;
$$;
grant execute on function api.profile_library(uuid,text,text,boolean,numeric,uuid) to anon, authenticated;

alter function api.apply_tracking(uuid,timestamptz,uuid,text,jsonb) rename to apply_library_tracking;
revoke execute on function api.apply_library_tracking(uuid,timestamptz,uuid,text,jsonb) from authenticated;

create function api.apply_tracking(operation_id uuid, submitted_at timestamptz, title_id uuid, action text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  candidate api.titles;
  settings private.profile_settings;
  response jsonb;
  first_tracking boolean;
  existing_receipt boolean;
begin
  select * into settings from private.profile_settings s where s.user_id = actor for share;
  select * into candidate from api.titles t where t.id = title_id for share;
  if candidate.id is null or title_id is null then
    raise exception using errcode = '22023', message = 'title_unavailable';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text || ':' || title_id::text, 0));
  select exists (select 1 from private.tracking_operations o where o.user_id = actor and o.operation_id = apply_tracking.operation_id) into existing_receipt;
  first_tracking := candidate.kind = 'show' and not exists (
    select 1 from private.tracked_shows sh where sh.user_id = actor and sh.show_id = candidate.id
  ) or candidate.kind = 'movie' and not exists (
    select 1 from private.movie_viewings v where v.user_id = actor and v.movie_id = candidate.id
  );
  response := api.apply_library_tracking(operation_id,submitted_at,title_id,action,payload);
  if not existing_receipt and first_tracking and settings.tracking_activity and settings.library_audience <> 'only_me'
    and response->>'result' = 'applied'
    and (candidate.kind = 'show' and response->>'intent' is not null
      or candidate.kind = 'movie' and action = 'mark_movie_watched' and (response->>'viewing_count')::int = 1) then
    insert into private.activity(actor_id,kind,title_id,audience,source_key)
    values (actor,case candidate.kind when 'movie' then 'first_movie' else 'first_show' end,
      candidate.id, settings.library_audience,'first:' || actor || ':' || candidate.id)
    on conflict do nothing;
  end if;
  return response;
end;
$$;
grant execute on function api.apply_tracking(uuid,timestamptz,uuid,text,jsonb) to authenticated;

create function api.public_share(kind_value text, target uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case kind_value
    when 'title' then (select jsonb_build_object('label',t.display_title,'id',t.id,'media',t.kind,'tmdb_id',t.tmdb_id)
      from api.titles t where t.id = target and t.catalog_state = 'available')
    when 'review' then (select jsonb_build_object('label','Taspa review','id',r.discussion_id)
      from private.reviews r join private.profile_settings s on s.user_id = r.user_id
      join api.titles t on t.id = r.title_id and t.catalog_state = 'available'
      where r.discussion_id = target and not r.moderation_hidden
        and r.audience = 'public' and not s.profile_private and s.lifecycle = 'ready')
    else null end;
$$;
grant execute on function api.public_share(text,uuid) to anon, authenticated;


-- ===== 20261118001200_catalog_metadata_and_releases.sql =====

create table private.title_metadata (
  title_id uuid primary key references api.titles on delete cascade,
  details jsonb not null
);

create table private.title_releases (
  title_id uuid not null references api.titles on delete cascade,
  market text not null check (market ~ '^[A-Z]{2}$'),
  release_kind smallint not null check (release_kind in (2,3,4)),
  release_day date not null,
  primary key (title_id,market,release_kind)
);
create index title_release_day on private.title_releases(market,release_day,title_id);

alter function api.catalog_finish(text,uuid,int,jsonb,jsonb) rename to catalog_finish_base;
revoke execute on function api.catalog_finish_base(text,uuid,int,jsonb,jsonb) from service_role;
create function api.catalog_finish(request_key text, lease uuid, ttl_seconds int, result jsonb, hydrated jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare saved jsonb; title_uuid uuid;
begin
  saved := api.catalog_finish_base(request_key,lease,ttl_seconds,result,hydrated);
  if hydrated is not null then
    title_uuid := (saved->>'id')::uuid;
    insert into private.title_metadata(title_id,details) values (title_uuid,coalesce(saved->'details','{}'::jsonb))
    on conflict (title_id) do update set details = excluded.details;
    if jsonb_typeof(saved->'regional_releases') = 'array' then
      delete from private.title_releases where title_id = title_uuid;
      insert into private.title_releases(title_id,market,release_kind,release_day)
      select title_uuid, r.market, r.release_kind, min(r.release_day)
      from jsonb_to_recordset(saved->'regional_releases') as r(market text,release_kind smallint,release_day date)
      group by r.market,r.release_kind;
    end if;
  end if;
  return saved;
end;
$$;
grant execute on function api.catalog_finish(text,uuid,int,jsonb,jsonb) to service_role;

create function api.title_metadata(title uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select d.details from private.title_metadata d join api.titles t on t.id = d.title_id and t.catalog_state = 'available'
  where d.title_id = title;
$$;
grant execute on function api.title_metadata(uuid) to anon, authenticated;

alter table private.tracked_shows add column tracking_started_at timestamptz not null default now();
alter table private.notifications add column release_day date;
alter table private.notifications add column release_market text;
alter table private.notifications add column release_kind smallint;

create table private.release_events (
  recipient_id uuid not null references api.profiles on delete cascade,
  episode_id uuid not null references api.episodes,
  created_at timestamptz not null default now(),
  primary key (recipient_id,episode_id)
);
create index release_events_age on private.release_events(created_at);

create function private.wanted_notification_valid(n private.notifications) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from private.wanted_entries w
    join private.profile_settings s on s.user_id = w.user_id and s.market = n.release_market and s.timezone is not null
    join private.title_releases r on r.title_id = w.title_id and r.market = s.market
      and r.release_day = n.release_day and r.release_kind = n.release_kind
    where w.user_id = n.recipient_id and w.title_id = n.target_id and w.added_at is not null
      and r.release_day > (now() at time zone s.timezone)::date
  );
$$;
alter function private.notification_valid(private.notifications) rename to notification_valid_base;
create function private.notification_valid(n private.notifications) returns boolean
language sql stable set search_path = '' as $$
  select private.notification_valid_base(n)
    and case when n.kind = 'wanted_release' then private.wanted_notification_valid(n) else true end;
$$;

create function private.sync_release_notifications() returns void
language plpgsql set search_path = '' as $$
declare item record;
begin
  for item in with candidates as (
    select sh.user_id, e.id as episode_id, e.show_id, e.release_day
    from api.episodes e join api.seasons season on season.id = e.season_id and season.available and season.season_number > 0
    join api.titles t on t.id = e.show_id and t.catalog_state = 'available'
    join private.tracked_shows sh on sh.show_id = e.show_id and sh.intent = 'watching'
    join private.profile_settings ps on ps.user_id = sh.user_id and ps.lifecycle = 'ready'
    left join private.notification_preferences p on p.user_id = sh.user_id and p.category = 'episodes'
    where e.available and private.episode_released(e.release_day)
      and e.release_day >= (now() at time zone 'UTC')::date - 3
      and sh.tracking_started_at::date <= e.release_day and coalesce(p.inbox,true)
      and not exists (select 1 from private.release_events x where x.recipient_id = sh.user_id and x.episode_id = e.id)
    order by e.release_day,e.id,sh.user_id limit 100
  ), inserted as (
    insert into private.release_events(recipient_id,episode_id)
    select user_id,episode_id from candidates on conflict do nothing
    returning recipient_id,episode_id
  )
  select distinct c.user_id,c.show_id,c.release_day from candidates c
  join inserted i on i.recipient_id = c.user_id and i.episode_id = c.episode_id
  loop
    perform private.notify(item.user_id,'episode',item.show_id,null,item.show_id || ':' || item.release_day);
  end loop;

  insert into private.notifications(recipient_id,kind,group_key,target_id,release_day,release_market,release_kind)
  select w.user_id,'wanted_release',w.title_id || ':' || r.market || ':' || r.release_day,
    w.title_id,r.release_day,r.market,r.release_kind
  from private.wanted_entries w
  join private.profile_settings ps on ps.user_id = w.user_id and ps.lifecycle = 'ready' and ps.timezone is not null
  join api.titles t on t.id = w.title_id and t.catalog_state = 'available'
  join lateral (
    select r.* from private.title_releases r where r.title_id = w.title_id and r.market = ps.market
      and r.release_day = (now() at time zone ps.timezone)::date + 1
    order by r.release_kind limit 1
  ) r on true
  left join private.notification_preferences p on p.user_id = w.user_id and p.category = 'wanted'
  where w.added_at is not null and coalesce(p.inbox,true)
    and (now() at time zone ps.timezone)::time >= time '09:00'
    and not exists (select 1 from private.notifications n where n.recipient_id = w.user_id and n.kind = 'wanted_release'
       and n.group_key = w.title_id || ':' || r.market || ':' || r.release_day)
  order by r.release_day,w.user_id,w.title_id limit 100 on conflict do nothing;
end;
$$;

create function api.catalog_refresh_targets() returns table (kind api.media_kind, tmdb_id bigint, season_number int)
language sql stable security definer set search_path = '' as $$
  with active as (
    select t.id,t.kind,t.tmdb_id,t.updated_at from api.titles t
    where t.catalog_state = 'available'
      and (exists (select 1 from private.wanted_entries w where w.title_id = t.id and w.added_at is not null)
        or exists (select 1 from private.tracked_shows s where s.show_id = t.id and s.intent = 'watching'))
  ), title_jobs as (
    select a.kind,a.tmdb_id,null::int as season_number from active a
    where a.updated_at < now() - interval '24 hours' order by a.updated_at limit 3
  ), season_jobs as (
    select a.kind,a.tmdb_id,s.season_number from active a join api.seasons s on s.show_id = a.id and s.available
    where s.season_number > 0 and s.first_release_day <= current_date
      and (s.loaded_at is null or s.loaded_at < now() - interval '3 hours'
        and (s.first_release_day > current_date - 90 or exists (
          select 1 from api.episodes e where e.season_id = s.id and e.available and e.release_day >= current_date - 3)))
    order by s.loaded_at nulls first,s.first_release_day desc limit 3
  )
  select * from title_jobs union all select * from season_jobs;
$$;
grant execute on function api.catalog_refresh_targets() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('taspa-release-notices','12 * * * *','select private.sync_release_notifications()');
    perform cron.schedule('taspa-catalog-refresh','*/15 * * * *',$task$
      select net.http_post(
        url := base.decrypted_secret || '/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type','application/json','x-taspa-worker',worker.decrypted_secret),
        body := '{"job":"refresh"}'::jsonb, timeout_milliseconds := 60000)
      from vault.decrypted_secrets base,vault.decrypted_secrets worker
      where base.name = 'taspa_project_url' and worker.name = 'taspa_worker_key';
    $task$);
  end if;
end;
$$;


-- ===== 20261118001300_account_storage.sql =====

alter table private.profile_settings add column avatar_path text;

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values ('avatars','avatars',false,1048576,array['image/png'])
    on conflict (id) do nothing;
  end if;
end;
$$;

create function api.avatar_path(target uuid) returns text
language sql stable security definer set search_path = '' as $$
  select s.avatar_path from private.profile_settings s where s.user_id = target and private.can_see(target,'public');
$$;
grant execute on function api.avatar_path(uuid) to anon, authenticated;

create function api.avatar_swap(actor uuid, path_value text) returns text
language plpgsql security definer set search_path = '' as $$
declare prior text;
begin
  if path_value is not null and path_value !~ ('^' || actor || '/[0-9a-f-]{36}\.png$') then
    raise exception using errcode = '22023', message = 'invalid_avatar';
  end if;
  select s.avatar_path into prior from private.profile_settings s
  where s.user_id = actor and s.lifecycle = 'ready' for update;
  if not found then raise exception using errcode = '42501', message = 'unavailable'; end if;
  update private.profile_settings set avatar_path = path_value where user_id = actor;
  return prior;
end;
$$;
grant execute on function api.avatar_swap(uuid,text) to service_role;

create table private.account_deletion_jobs (
  user_id uuid primary key,
  due_at timestamptz not null default now(),
  attempts int not null default 0,
  finished_at timestamptz
);
create index account_deletion_pending on private.account_deletion_jobs(due_at) where finished_at is null;

create function api.request_account_deletion(actor uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update private.profile_settings set lifecycle = 'deleting' where user_id = actor;
  if not found then raise exception using errcode = '42501', message = 'unavailable'; end if;
  update private.device_tokens set disabled_at = now(), revision = revision + 1 where user_id = actor and disabled_at is null;
  insert into private.account_deletion_jobs(user_id) values(actor) on conflict do nothing;
end;
$$;
grant execute on function api.request_account_deletion(uuid) to service_role;

create function api.claim_account_deletions() returns table(user_id uuid)
language sql security definer set search_path = '' as $$
  with work as (
    select j.user_id from private.account_deletion_jobs j where j.finished_at is null and j.due_at <= now()
    order by j.due_at limit 4 for update skip locked
  ) update private.account_deletion_jobs j set attempts = j.attempts + 1,
    due_at = now() + make_interval(mins => least(360, (2 ^ least(j.attempts+1,8))::int))
  from work where j.user_id = work.user_id returning j.user_id;
$$;
grant execute on function api.claim_account_deletions() to service_role;

create function api.finish_account_deletion(actor uuid) returns void
language sql security definer set search_path = '' as $$
  update private.account_deletion_jobs set finished_at = now() where user_id = actor;
$$;
grant execute on function api.finish_account_deletion(uuid) to service_role;


-- ===== 20261118001400_account_cleanup_schedule.sql =====

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('taspa-account-cleanup','*/5 * * * *',$task$
      select net.http_post(
        url := base.decrypted_secret || '/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type','application/json','x-taspa-worker',worker.decrypted_secret),
        body := '{"job":"deletions"}'::jsonb, timeout_milliseconds := 60000)
      from vault.decrypted_secrets base,vault.decrypted_secrets worker
      where base.name = 'taspa_project_url' and worker.name = 'taspa_worker_key'
        and exists (select 1 from private.account_deletion_jobs j where j.finished_at is null and j.due_at <= now());
    $task$);
  end if;
end;
$$;


-- ===== 20261118001500_library_sorting.sql =====

create function api.library_page_v2(section text, media api.media_kind default null,
  sort text default 'activity', genre text default null, minimum_rating int default null,
  status_filter text default null, before_text text default null, before_value numeric default null,
  before_title uuid default null, page_size int default 20)
returns table (title jsonb, activity_at timestamptz, sort_text text, sort_value numeric)
language sql stable security definer set search_path = '' as $$
  with viewer as materialized (select private.ready_user() as id),
  entries as (
    select w.title_id as id, w.added_at as at, null::date as watch_day
    from private.wanted_entries w join viewer on viewer.id = w.user_id
    where section = 'wanted' and w.added_at is not null
    union all
    select v.movie_id, max(v.logged_at), max(v.watched_on)
    from private.movie_viewings v join viewer on viewer.id = v.user_id
    where section = 'watched_movies' and v.deleted_at is null group by v.movie_id
    union all
    select s.show_id, s.last_activity_at, null::date
    from private.tracked_shows s join viewer on viewer.id = s.user_id
    where section = 'watched_shows' and s.intent is not null
  ), data as (
    select t, t.id as id, t.kind, e.at, e.watch_day, r.score, m.details,
      case when t.kind = 'show' and section = 'watched_shows'
        then private.show_snapshot(viewer.id, t.id) end as progress,
      case when sort = 'title' then lower(t.display_title) else '' end as name_key
    from entries e cross join viewer join api.titles t on t.id = e.id
    left join private.ratings r on r.user_id = viewer.id and r.title_id = t.id and r.season_id is null
    left join private.title_metadata m on m.title_id = t.id
    where (media is null or media = t.kind)
      and (genre is null or (m.details->'genres') ? genre)
      and (minimum_rating is null or r.score >= minimum_rating)
      and sort in ('activity','title','viewing','rating','release')
  ), ordered as (
    select *, case sort
      when 'title' then 0
      when 'rating' then -coalesce(score,0)::numeric
      when 'viewing' then -coalesce(extract(epoch from watch_day),-100000000000)
      when 'release' then -coalesce(extract(epoch from (t).first_release_day),-100000000000)
      else -extract(epoch from at) + case when section = 'watched_shows' and
        (progress->'next' is null or progress->'next' = 'null'::jsonb) then 100000000000 else 0 end
      end as value_key
    from data
    where status_filter is null or progress->>'status' = status_filter
  )
  select to_jsonb(t) - 'overview' - 'backdrop_path' ||
    jsonb_build_object('personal_rating', score, 'last_watched_on', watch_day, 'genres', coalesce(details->'genres','[]'::jsonb)) ||
    case when kind = 'show' then jsonb_build_object('progress',
      coalesce(progress,private.show_snapshot((select viewer.id from viewer),id))) else '{}'::jsonb end,
    at, name_key, value_key
  from ordered
  where before_title is null or (name_key, value_key, id) > (before_text, before_value, before_title)
  order by name_key, value_key, id
  limit greatest(1, least(page_size,50));
$$;
grant execute on function api.library_page_v2(text,api.media_kind,text,text,int,text,text,numeric,uuid,int) to authenticated;

create function api.viewing_history_v2(title_id uuid, page_size int default 20,
  before_day date default null, before_logged_at timestamptz default null, before_id uuid default null)
returns table (id uuid, watched_on date, logged_at timestamptz, revision bigint)
language sql stable security definer set search_path = '' as $$
  select v.id, v.watched_on, v.logged_at, v.revision
  from private.movie_viewings v
  where v.user_id = (select private.ready_user()) and v.movie_id = title_id and v.deleted_at is null
    and (before_id is null or (coalesce(v.watched_on,'-infinity'),v.logged_at,v.id) <
      (coalesce(before_day,'-infinity'),before_logged_at,before_id))
  order by v.watched_on desc nulls last, v.logged_at desc, v.id desc
  limit greatest(1,least(page_size,50));
$$;
grant execute on function api.viewing_history_v2(uuid,int,date,timestamptz,uuid) to authenticated;


-- ===== 20261118001600_followed_recommendations.sql =====

create function private.followed_activity(before_time timestamptz, before_id uuid, target uuid, opinions_only boolean)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id',a.id,'created_at',a.created_at,'kind',a.kind,'actor_id',a.actor_id,
    'handle',p.handle,'title_id',t.id,'title',t.display_title,'tmdb_id',t.tmdb_id,'media',t.kind,'poster',t.poster_path,
    'season',s.display_title,'review',case when a.kind = 'review' then private.review_card(r) end,
    'score',case when a.kind = 'rating' then rating.score end)
  from private.activity a
  join private.follows f on f.followed_id = a.actor_id and f.follower_id = (select private.ready_user()) and f.state = 'accepted'
  join api.profiles p on p.user_id = a.actor_id
  join api.titles t on t.id = a.title_id and t.catalog_state = 'available'
  join private.profile_settings settings on settings.user_id = a.actor_id
  left join private.reviews r on r.discussion_id = a.review_id
  left join private.ratings rating on rating.id = a.rating_id
  left join api.seasons s on s.id = a.season_id
  where private.can_see(a.actor_id,a.audience)
    and case a.kind
      when 'review' then private.review_visible(r)
      when 'rating' then rating.score is not null and private.can_see(rating.user_id,rating.audience)
      when 'first_movie' then settings.tracking_activity and private.can_see(a.actor_id,settings.library_audience)
        and exists (select 1 from private.movie_viewings m where m.user_id = a.actor_id and m.movie_id = a.title_id and m.deleted_at is null)
      when 'first_show' then settings.tracking_activity and private.can_see(a.actor_id,settings.library_audience)
        and exists (select 1 from private.tracked_shows sh where sh.user_id = a.actor_id and sh.show_id = a.title_id and sh.intent is not null)
      else false end
    and (target is null or a.title_id = target)
    and (not opinions_only or a.kind in ('review','rating'))
    and (before_time is null or (a.created_at,a.id) < (before_time,before_id))
  order by a.created_at desc,a.id desc limit 20;
$$;

create or replace function api.following_feed(before_time timestamptz default null, before_id uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  select * from private.followed_activity(before_time,before_id,null,false);
$$;

-- Following activity on a title page reads the library of the viewer and of each followed person, not the activity log,
-- so imported and older viewings count too. One row per person (the viewer first): review, else rating, else watched / started.
create function api.followed_recommendations(target uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  with people as (
    select (select private.ready_user()) as user_id, true as own
    union all
    select f.followed_id, false from private.follows f
    where f.follower_id = (select private.ready_user()) and f.state = 'accepted'
  )
  select x.item from (
    select jsonb_build_object('id', pe.user_id, 'actor_id', pe.user_id, 'own', pe.own, 'handle', p.handle,
        'title_id', t.id, 'title', t.display_title, 'tmdb_id', t.tmdb_id, 'media', t.kind, 'poster', t.poster_path,
        'kind', case when rv.discussion_id is not null then 'review' when rt.score is not null then 'rating'
          when t.kind = 'show' then 'first_show' else 'first_movie' end,
        'review', case when rv.discussion_id is not null then private.review_card(rv) end,
        'score', rt.score) as item,
      pe.own,
      greatest(rv.published_at, v.at, sh.tracking_started_at) as at,
      rv.discussion_id is not null or rt.score is not null or v.n > 0 or sh.show_id is not null as present
    from people pe
    join api.profiles p on p.user_id = pe.user_id
    join private.profile_settings s on s.user_id = pe.user_id
    join api.titles t on t.id = target and t.catalog_state = 'available'
    left join lateral (select r.* from private.reviews r
      where r.user_id = pe.user_id and r.title_id = t.id and r.season_id is null
        and r.published_at is not null and private.review_visible(r)) rv on true
    left join private.ratings rt on rt.user_id = pe.user_id and rt.title_id = t.id and rt.season_id is null
      and rt.score is not null and private.can_see(rt.user_id, rt.audience)
    left join lateral (select count(*) as n, max(m.logged_at) as at from private.movie_viewings m
      where m.user_id = pe.user_id and m.movie_id = t.id and m.deleted_at is null
        and private.can_see(pe.user_id, s.library_audience)) v on true
    left join private.tracked_shows sh on sh.user_id = pe.user_id and sh.show_id = t.id and sh.intent is not null
      and private.can_see(pe.user_id, s.library_audience)
  ) x
  where x.present
  order by x.own desc, x.at desc nulls last
  limit 20;
$$;
grant execute on function api.followed_recommendations(uuid) to authenticated;


-- ===== 20261118001800_for_you.sql =====

-- Personal "For you" shelf for Discover. Built only from TMDB "similar" lists already stored in
-- private.title_metadata, so it costs one cheap query and no catalog/TMDB calls.
create or replace function api.for_you() returns setof jsonb
language sql stable security definer set search_path = '' as $$
  with me as (select (select private.ready_user()) as id),
  engaged as (
    select v.movie_id as title_id, v.logged_at as seen_at
    from me join private.movie_viewings v on v.user_id = me.id and v.deleted_at is null
    union all
    select sh.show_id, sh.last_activity_at
    from me join private.tracked_shows sh on sh.user_id = me.id and sh.intent is not null
  ),
  -- Recent titles the viewer did not rate below 3 stars seed the picks.
  seeds as (
    select t.id, t.display_title, max(e.seen_at) as seen_at
    from engaged e
    join api.titles t on t.id = e.title_id and t.catalog_state = 'available'
    left join private.ratings r on r.user_id = (select id from me) and r.title_id = t.id and r.season_id is null
    where coalesce(r.score, 6) >= 6
    group by t.id, t.display_title
    order by max(e.seen_at) desc
    limit 12
  ),
  known as (
    select t.kind::text as kind, t.tmdb_id from api.titles t
    where t.id in (select title_id from engaged)
       or t.id in (select w.title_id from me join private.wanted_entries w on w.user_id = me.id and w.added_at is not null)
  ),
  picks as (
    select distinct on (e.item->>'kind', (e.item->>'tmdb_id')::int)
      e.item || jsonb_build_object('details', jsonb_build_object('reason', 'Because you watched ' || s.display_title)) as item,
      s.seen_at, e.pos
    from seeds s
    join private.title_metadata d on d.title_id = s.id
    cross join lateral jsonb_array_elements(coalesce(d.details->'similar', '[]'::jsonb)) with ordinality as e(item, pos)
    where e.item ? 'tmdb_id'
      and not exists (select 1 from known k where k.kind = e.item->>'kind' and k.tmdb_id = (e.item->>'tmdb_id')::int)
    order by e.item->>'kind', (e.item->>'tmdb_id')::int, e.pos, s.seen_at desc
  )
  -- Interleave seeds: the top similar title of each seed first, then the next ones.
  select item from picks order by pos, seen_at desc limit 20;
$$;
grant execute on function api.for_you() to authenticated;


-- ===== 20261118001900_full_show_progress.sql =====

-- Show progress counts every aired season, not only seasons whose episodes were already hydrated.
-- An unloaded season that has started airing contributes its expected episode count, so a show
-- with seasons 1–2 watched and season 3 never opened reads 16/24 instead of looking caught up.
-- 'pending_season' names the first aired season that still needs hydrating; the client hydrates it
-- before a one-tap "mark next episode" when 'next' is null.
create or replace function private.show_snapshot(actor uuid, title uuid) returns jsonb
language sql stable set search_path = '' as $$
  with base as (
    select s.id, s.season_number, s.first_release_day, s.loaded_at, s.expected_episodes,
      count(*) filter (where e.id is not null) as known_count,
      count(*) filter (where private.episode_released(e.release_day)) as known_released,
      count(*) filter (where private.episode_released(e.release_day) and m.watched) as watched
    from api.seasons s
    left join api.episodes e on e.season_id = s.id and e.available
    left join private.episode_marks m on m.user_id = actor and m.episode_id = e.id
    where s.show_id = title and s.available and s.season_number > 0
    group by s.id
  ), regular as (
    select b.*,
      (b.loaded_at is not null and b.known_count >= b.expected_episodes) as complete,
      case when b.loaded_at is not null and b.known_count >= b.expected_episodes then b.known_released
        when private.episode_released(b.first_release_day) then greatest(b.known_released, b.expected_episodes)
        else b.known_released end as released
    from base b
  ), totals as (
    select coalesce(sum(released), 0) as released, coalesce(sum(watched), 0) as watched,
      count(*) filter (where released > 0) as seasons_released,
      coalesce(bool_and(complete), false) as coverage,
      coalesce(bool_and(released >= expected_episodes and known_count = released), false) as all_released,
      coalesce(bool_and(complete or (first_release_day is not null and not private.episode_released(first_release_day))), false)
        as released_coverage
    from regular
  ), next_up as (
    select e.id, e.display_title, r.season_number, e.episode_number, coalesce(m.revision, 0) as revision
    from regular r
    join api.episodes e on e.season_id = r.id and e.available and private.episode_released(e.release_day)
    left join private.episode_marks m on m.user_id = actor and m.episode_id = e.id
    where not coalesce(m.watched, false)
      and not exists (select 1 from regular older
        where older.season_number < r.season_number and not older.complete)
    order by r.season_number, e.episode_number, e.id limit 1
  )
  select private.movie_snapshot(actor, title) || jsonb_build_object(
    'intent', tracked.intent,
    'show_revision', coalesce(tracked.revision, 0),
    'status', case when tracked.intent = 'watching' and totals.watched > 0 and totals.watched = totals.released
      and totals.coverage and totals.all_released and t.source_release_status in ('Ended', 'Canceled')
      then 'completed' else tracked.intent end,
    'released', totals.released,
    'watched', totals.watched,
    'seasons_released', totals.seasons_released,
    'seasons_completed', (select count(*) from regular r where r.released > 0 and r.released = r.watched
       and r.complete and r.known_count = r.released
       and (t.source_release_status in ('Ended', 'Canceled') or exists (
         select 1 from regular later where later.season_number > r.season_number and later.released > 0))),
    'coverage', totals.released_coverage,
    'next', case when tracked.intent = 'watching' then (select to_jsonb(next_up) from next_up) end,
    'pending_season', (select min(r.season_number) from regular r
      where not r.complete and private.episode_released(r.first_release_day) and r.watched < r.released),
    'upcoming_day', (select min(e.release_day) from regular r join api.episodes e on e.season_id = r.id
      where e.available and e.release_day >= (now() at time zone 'UTC')::date)
  )
  from totals join api.titles t on t.id = title
  left join private.tracked_shows tracked on tracked.user_id = actor and tracked.show_id = title;
$$;


-- ===== 20261118002100_ten_point_average.sql =====

-- Ratings are shown on a 1–10 scale (stored scores were always 1–10); the community average follows.
create or replace function api.title_opinions(title uuid, season uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('rating_count', (
      select count(*) from private.ratings r join private.profile_settings s on s.user_id = r.user_id
      where r.title_id = title and r.season_id is not distinct from season and r.score is not null
        and r.audience = 'public' and s.lifecycle = 'ready' and not s.profile_private
    ), 'average', (
      select case when count(*) >= 5 then round(avg(r.score), 1) end
      from private.ratings r join private.profile_settings s on s.user_id = r.user_id
      where r.title_id = title and r.season_id is not distinct from season and r.score is not null
        and r.audience = 'public' and s.lifecycle = 'ready' and not s.profile_private
    ), 'my_rating', (
      select jsonb_build_object('score', r.score, 'audience', r.audience, 'revision', r.revision)
      from private.ratings r
      where r.user_id = (select auth.uid()) and private.profile_visible(r.user_id)
        and r.title_id = title and r.season_id is not distinct from season
    ), 'my_review', (
      select jsonb_build_object('body', r.body, 'audience', r.audience, 'spoiler', r.spoiler,
        'discussion_id', r.discussion_id, 'revision', r.revision)
      from private.reviews r
      where r.user_id = (select auth.uid()) and private.profile_visible(r.user_id)
        and r.title_id = title and r.season_id is not distinct from season
    ))
  where exists (select 1 from api.titles t where t.id = title and t.catalog_state = 'available');
$$;


-- ===== 20261118002200_feed_all_logs.sql =====

-- Feed shows every log (movie viewings, episode marks, show starts, ratings, reviews) of the viewer and of
-- followed people whose library audience lets the viewer see it. The "share first watches" opt-in is gone.

-- Episode marks had no log time; stamp it when an episode becomes watched. Older marks stay null and stay out of the feed.
alter table private.episode_marks add column if not exists marked_at timestamptz;

create or replace function private.stamp_episode_mark() returns trigger language plpgsql set search_path = '' as $$
begin
  if not new.watched then
    new.marked_at := null;
  elsif tg_op = 'INSERT' or not old.watched then
    new.marked_at := now();
  end if;
  return new;
end $$;

drop trigger if exists episode_mark_stamp on private.episode_marks;
create trigger episode_mark_stamp before insert or update of watched on private.episode_marks
for each row execute function private.stamp_episode_mark();

create index if not exists episode_marks_feed on private.episode_marks (user_id, marked_at desc) where watched and marked_at is not null;

create or replace function api.following_feed(before_time timestamptz default null, before_id uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  with me as (select (select private.ready_user()) as id),
  people as (
    select me.id as user_id, true as own from me
    union all
    select f.followed_id, false from me
    join private.follows f on f.follower_id = me.id and f.state = 'accepted'
    join private.profile_settings s on s.user_id = f.followed_id
    where private.can_see(f.followed_id, s.library_audience)
  ),
  logs as (
    select jsonb_build_object('id',v.id,'created_at',v.logged_at,'kind','watched','watched_on',v.watched_on,
        'actor_id',v.user_id,'own',pe.own,'title_id',v.movie_id) as item, v.logged_at as at, v.id
    from people pe join private.movie_viewings v on v.user_id = pe.user_id and v.deleted_at is null
    union all
    select jsonb_build_object('id',md5(m.user_id::text || m.episode_id::text)::uuid,'created_at',m.marked_at,
        'kind','episode','actor_id',m.user_id,'own',pe.own,'title_id',m.show_id,
        'season_number',s.season_number,'episode_number',e.episode_number,'episode',e.display_title),
      m.marked_at, md5(m.user_id::text || m.episode_id::text)::uuid
    from people pe
    join private.episode_marks m on m.user_id = pe.user_id and m.watched and m.marked_at is not null
    join api.episodes e on e.id = m.episode_id
    join api.seasons s on s.id = e.season_id
    union all
    -- tracked_shows has no surrogate key; a stable uuid derived from the pair keeps keyset paging deterministic.
    select jsonb_build_object('id',md5(sh.user_id::text || sh.show_id::text)::uuid,'created_at',sh.tracking_started_at,
        'kind','first_show','actor_id',sh.user_id,'own',pe.own,'title_id',sh.show_id),
      sh.tracking_started_at, md5(sh.user_id::text || sh.show_id::text)::uuid
    from people pe join private.tracked_shows sh on sh.user_id = pe.user_id and sh.intent is not null
    union all
    select jsonb_build_object('id',a.id,'created_at',a.created_at,'kind',a.kind,'actor_id',a.actor_id,
        'own',a.actor_id = (select id from me),'title_id',a.title_id,'season',s.display_title,
        'review',case when a.kind = 'review' then private.review_card(r) end,
        'score',case when a.kind = 'rating' then rating.score end),
      a.created_at, a.id
    from private.activity a
    left join private.reviews r on r.discussion_id = a.review_id
    left join private.ratings rating on rating.id = a.rating_id
    left join api.seasons s on s.id = a.season_id
    where a.kind in ('review','rating')
      and (a.actor_id = (select id from me) or exists (select 1 from private.follows f
        where f.followed_id = a.actor_id and f.follower_id = (select id from me) and f.state = 'accepted'))
      and private.can_see(a.actor_id, a.audience)
      and case a.kind when 'review' then private.review_visible(r)
        else rating.score is not null and private.can_see(rating.user_id, rating.audience) end
  )
  select l.item || jsonb_build_object('handle',p.handle,'title',t.display_title,'tmdb_id',t.tmdb_id,
      'media',t.kind,'poster',t.poster_path)
  from logs l
  join api.profiles p on p.user_id = (l.item->>'actor_id')::uuid
  join api.titles t on t.id = (l.item->>'title_id')::uuid and t.catalog_state = 'available'
  where before_time is null or (l.at, l.id) < (before_time, before_id)
  order by l.at desc, l.id desc
  limit 60;
$$;


-- ===== 20261118002300_must_import.sql =====

-- Import from Must (mustapp.com). The must-import Edge Function reads the public profile once, stores every
-- title as an item, then matches items to TMDB step by step and writes them through api.import_apply.
-- Imported rows are flagged so the Feed shows one "Imported N titles" line instead of hundreds of events.

alter table private.movie_viewings add column if not exists imported boolean not null default false;
alter table private.tracked_shows add column if not exists imported boolean not null default false;
-- Set by the Must import to the added_at it wrote; while they match, the entry is an import and stays out of the Feed.
alter table private.wanted_entries add column if not exists imported_at timestamptz;

create table if not exists private.import_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references api.profiles on delete cascade,
  username text not null,
  state text not null default 'running' check (state in ('running', 'done')),
  total int not null default 0,
  done int not null default 0,
  imported int not null default 0,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create unique index if not exists import_one_running on private.import_jobs (user_id) where state = 'running';
create index if not exists import_jobs_by_user on private.import_jobs (user_id, created_at desc);

-- data: {kind, title, year, lists[], rate, modified_at, episodes, review} as read from Must.
create table if not exists private.import_items (
  job_id uuid not null references private.import_jobs on delete cascade,
  must_id bigint not null,
  data jsonb not null,
  state text not null default 'pending' check (state in ('pending', 'done', 'unmatched')),
  primary key (job_id, must_id)
);
create index if not exists import_items_pending on private.import_items (job_id, must_id) where state = 'pending';

-- Shared Must → TMDB match cache, so a title is searched once for everyone.
create table if not exists private.must_titles (
  must_id bigint primary key,
  kind api.media_kind not null,
  tmdb_id bigint not null
);

alter table private.import_jobs enable row level security;
alter table private.import_items enable row level security;
alter table private.must_titles enable row level security;

create or replace function api.import_start(actor uuid, username text, items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare job private.import_jobs;
begin
  select * into job from private.import_jobs j where j.user_id = actor and j.state = 'running';
  if found then return to_jsonb(job); end if;
  if jsonb_typeof(items) <> 'array' or jsonb_array_length(items) > 20000 then
    raise exception using errcode = '22023', message = 'invalid_import';
  end if;
  insert into private.import_jobs (user_id, username, total) values (actor, username, jsonb_array_length(items))
  returning * into job;
  insert into private.import_items (job_id, must_id, data)
  select job.id, (x->>'must_id')::bigint, x - 'must_id' from jsonb_array_elements(items) x
  on conflict do nothing;
  return to_jsonb(job);
end $$;

create or replace function api.import_next(job uuid, max_items int) returns setof jsonb
language sql stable security definer set search_path = '' as $$
  select i.data || jsonb_build_object('must_id', i.must_id,
      'match', (select jsonb_build_object('kind', m.kind, 'tmdb_id', m.tmdb_id) from private.must_titles m where m.must_id = i.must_id))
  from private.import_items i where i.job_id = job and i.state = 'pending'
  order by i.must_id limit least(max_items, 50);
$$;

-- Marks an item unmatched (no TMDB title) so the app can list it for manual adding.
create or replace function api.import_skip(job uuid, item bigint) returns void
language sql security definer set search_path = '' as $$
  with changed as (
    update private.import_items set state = 'unmatched' where job_id = job and must_id = item and state = 'pending' returning 1
  )
  update private.import_jobs set done = done + (select count(*) from changed) where id = job;
$$;

-- Writes one matched item into the user's library. Existing Taspa data always wins; nothing is overwritten.
create or replace function api.import_apply(job uuid, item bigint, title uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  owner_job private.import_jobs;
  d jsonb;
  t api.titles;
  actor uuid;
  at timestamptz;
  lists jsonb;
  watched_count int;
  score int;
  body text;
  audience private.audience;
begin
  select * into owner_job from private.import_jobs where id = job and state = 'running';
  if not found then return; end if;
  actor := owner_job.user_id;
  select data into d from private.import_items where job_id = job and must_id = item and state = 'pending' for update;
  if not found then return; end if;
  select * into t from api.titles where id = title and catalog_state = 'available';
  if not found then
    perform api.import_skip(job, item);
    return;
  end if;
  insert into private.must_titles (must_id, kind, tmdb_id) values (item, t.kind, t.tmdb_id)
  on conflict (must_id) do update set kind = excluded.kind, tmdb_id = excluded.tmdb_id;

  at := least(coalesce((d->>'modified_at')::timestamptz, now()), now());
  lists := coalesce(d->'lists', '[]'::jsonb);
  watched_count := coalesce((d->>'episodes')::int, 0);
  select private.allowed_audience(actor, s.library_audience) into audience from private.profile_settings s where s.user_id = actor;

  if t.kind = 'movie' and lists ? 'watched' then
    insert into private.movie_viewings (id, user_id, movie_id, watched_on, logged_at, revision, imported)
    select gen_random_uuid(), actor, t.id, at::date, at, 1, true
    where not exists (select 1 from private.movie_viewings v where v.user_id = actor and v.movie_id = t.id and v.deleted_at is null);
    update private.wanted_entries set added_at = null, revision = revision + 1
    where user_id = actor and title_id = t.id and added_at is not null;
  elsif t.kind = 'show' and (watched_count > 0 or lists ? 'shows' or lists ? 'watched') then
    insert into private.tracked_shows (user_id, show_id, intent, revision, last_activity_at, tracking_started_at, imported)
    values (actor, t.id, 'watching', 1, at, at, true)
    on conflict (user_id, show_id) do update set intent = coalesce(tracked_shows.intent, 'watching')
    where tracked_shows.intent is null;
    update private.wanted_entries set added_at = null, revision = revision + 1
    where user_id = actor and title_id = t.id and added_at is not null;
    -- Must keeps only a count, so mark that many released episodes in order; already marked ones stay as they are.
    insert into private.episode_marks (user_id, show_id, episode_id, watched, revision)
    select actor, t.id, e.id, true, 1
    from api.episodes e join api.seasons s on s.id = e.season_id and s.available
    where e.show_id = t.id and e.available and s.season_number > 0
    order by s.season_number, e.episode_number
    limit watched_count
    on conflict (user_id, episode_id) do nothing;
    -- The stamp trigger set marked_at = now() on these inserts; clear it so the Feed does not list them one by one.
    update private.episode_marks set marked_at = null where user_id = actor and show_id = t.id and marked_at = now();
  elsif lists ? 'want' then
    insert into private.wanted_entries (user_id, title_id, added_at, revision, imported_at)
    select actor, t.id, at, 1, at
    where not exists (select 1 from private.movie_viewings v where v.user_id = actor and v.movie_id = t.id and v.deleted_at is null)
      and not exists (select 1 from private.tracked_shows sh where sh.user_id = actor and sh.show_id = t.id and sh.intent is not null)
    on conflict (user_id, title_id) do update set added_at = excluded.added_at, imported_at = excluded.imported_at,
      revision = wanted_entries.revision + 1
    where wanted_entries.added_at is null;
  end if;

  score := round((d->>'rate')::numeric);
  if score > 10 then score := round(score / 10.0); end if;
  if score between 1 and 10 then
    insert into private.ratings (user_id, title_id, season_id, score, audience, revision)
    values (actor, t.id, null, score, audience, 1)
    on conflict (user_id, title_id, season_id) do nothing;
  end if;

  body := nullif(btrim(left(d->>'review', 5000)), '');
  if body is not null then
    insert into private.reviews (user_id, title_id, season_id, discussion_id, body, audience, published_at, revision)
    values (actor, t.id, null, case when audience <> 'only_me' then gen_random_uuid() end, body, audience,
      case when audience <> 'only_me' then at end, 1)
    on conflict (user_id, title_id, season_id) do nothing;
  end if;

  update private.import_items set state = 'done' where job_id = job and must_id = item;
  update private.import_jobs set done = done + 1, imported = imported + 1 where id = job;
end $$;

create or replace function api.import_finish(job uuid) returns jsonb
language sql security definer set search_path = '' as $$
  update private.import_jobs j set state = 'done', finished_at = now()
  where j.id = job and j.state = 'running'
    and not exists (select 1 from private.import_items i where i.job_id = j.id and i.state = 'pending')
  returning to_jsonb(j);
$$;

revoke execute on function api.import_start(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function api.import_next(uuid, int) from public, anon, authenticated;
revoke execute on function api.import_skip(uuid, bigint) from public, anon, authenticated;
revoke execute on function api.import_apply(uuid, bigint, uuid) from public, anon, authenticated;
revoke execute on function api.import_finish(uuid) from public, anon, authenticated;
grant execute on function api.import_start(uuid, text, jsonb) to service_role;
grant execute on function api.import_next(uuid, int) to service_role;
grant execute on function api.import_skip(uuid, bigint) to service_role;
grant execute on function api.import_apply(uuid, bigint, uuid) to service_role;
grant execute on function api.import_finish(uuid) to service_role;

-- The app reads its latest import and the titles that could not be matched.
create or replace function api.import_status() returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(j) || jsonb_build_object('unmatched', coalesce((
      select jsonb_agg(jsonb_build_object('title', i.data->>'title', 'year', i.data->'year', 'kind', i.data->>'kind') order by i.data->>'title')
      from private.import_items i where i.job_id = j.id and i.state = 'unmatched'), '[]'::jsonb))
  from private.import_jobs j
  where j.user_id = (select private.ready_user())
  order by j.created_at desc limit 1;
$$;
grant execute on function api.import_status() to authenticated;

-- Feed: imported viewings and show starts are hidden; a finished import is one line.
-- A watched log or show start carries the actor's own rating of that title, when the viewer may see it.
-- Feed: a rating is not its own entry when the same person logged that title within a day,
-- because the watched / started card already shows their score. Standalone ratings now show their score
-- (the watched-card score lookup no longer overwrites it with null).
create or replace function api.following_feed(before_time timestamptz default null, before_id uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  with me as (select (select private.ready_user()) as id),
  people as (
    select me.id as user_id, true as own from me
    union all
    select f.followed_id, false from me
    join private.follows f on f.follower_id = me.id and f.state = 'accepted'
    join private.profile_settings s on s.user_id = f.followed_id
    where private.can_see(f.followed_id, s.library_audience)
  ),
  logs as (
    select jsonb_build_object('id',v.id,'created_at',v.logged_at,'kind','watched','watched_on',v.watched_on,
        'actor_id',v.user_id,'own',pe.own,'title_id',v.movie_id) as item, v.logged_at as at, v.id
    from people pe join private.movie_viewings v on v.user_id = pe.user_id and v.deleted_at is null and not v.imported
    union all
    select jsonb_build_object('id',md5(m.user_id::text || m.episode_id::text)::uuid,'created_at',m.marked_at,
        'kind','episode','actor_id',m.user_id,'own',pe.own,'title_id',m.show_id,
        'season_number',s.season_number,'episode_number',e.episode_number,'episode',e.display_title),
      m.marked_at, md5(m.user_id::text || m.episode_id::text)::uuid
    from people pe
    join private.episode_marks m on m.user_id = pe.user_id and m.watched and m.marked_at is not null
    join api.episodes e on e.id = m.episode_id
    join api.seasons s on s.id = e.season_id
    union all
    -- tracked_shows has no surrogate key; a stable uuid derived from the pair keeps keyset paging deterministic.
    select jsonb_build_object('id',md5(sh.user_id::text || sh.show_id::text)::uuid,'created_at',sh.tracking_started_at,
        'kind','first_show','actor_id',sh.user_id,'own',pe.own,'title_id',sh.show_id),
      sh.tracking_started_at, md5(sh.user_id::text || sh.show_id::text)::uuid
    from people pe join private.tracked_shows sh on sh.user_id = pe.user_id and sh.intent is not null and not sh.imported
    union all
    select jsonb_build_object('id',md5('want' || w.user_id::text || w.title_id::text)::uuid,'created_at',w.added_at,
        'kind','wanted','actor_id',w.user_id,'own',pe.own,'title_id',w.title_id),
      w.added_at, md5('want' || w.user_id::text || w.title_id::text)::uuid
    from people pe join private.wanted_entries w on w.user_id = pe.user_id and w.added_at is not null
      and w.added_at is distinct from w.imported_at
    union all
    select jsonb_build_object('id',j.id,'created_at',j.finished_at,'kind','import','actor_id',j.user_id,'own',pe.own,
        'count',j.imported,'source','Must'),
      j.finished_at, j.id
    from people pe join private.import_jobs j on j.user_id = pe.user_id and j.state = 'done' and j.imported > 0
    union all
    select jsonb_build_object('id',a.id,'created_at',a.created_at,'kind',a.kind,'actor_id',a.actor_id,
        'own',a.actor_id = (select id from me),'title_id',a.title_id,'season',s.display_title,
        'review',case when a.kind = 'review' then private.review_card(r) end,
        'score',case when a.kind = 'rating' then rating.score end),
      a.created_at, a.id
    from private.activity a
    left join private.reviews r on r.discussion_id = a.review_id
    left join private.ratings rating on rating.id = a.rating_id
    left join api.seasons s on s.id = a.season_id
    where a.kind in ('review','rating')
      and (a.actor_id = (select id from me) or exists (select 1 from private.follows f
        where f.followed_id = a.actor_id and f.follower_id = (select id from me) and f.state = 'accepted'))
      and private.can_see(a.actor_id, a.audience)
      and case a.kind when 'review' then private.review_visible(r)
        else rating.score is not null and private.can_see(rating.user_id, rating.audience) end
      -- Same conditions as the watched / first_show rows above, so the score is never hidden from both.
      and not (a.kind = 'rating' and a.season_id is null
        and exists (select 1 from people pe where pe.user_id = a.actor_id)
        and (exists (select 1 from private.movie_viewings v
               where v.user_id = a.actor_id and v.movie_id = a.title_id and v.deleted_at is null and not v.imported
                 and v.logged_at between a.created_at - interval '1 day' and a.created_at + interval '1 day')
          or exists (select 1 from private.tracked_shows sh
               where sh.user_id = a.actor_id and sh.show_id = a.title_id and sh.intent is not null and not sh.imported
                 and sh.tracking_started_at between a.created_at - interval '1 day' and a.created_at + interval '1 day')))
  )
  select l.item || jsonb_build_object('handle',p.handle)
    || coalesce(jsonb_build_object('title',t.display_title,'tmdb_id',t.tmdb_id,'media',t.kind,'poster',t.poster_path), '{}'::jsonb)
    || jsonb_strip_nulls(jsonb_build_object('score',own_rating.score))
  from logs l
  join api.profiles p on p.user_id = (l.item->>'actor_id')::uuid
  left join api.titles t on t.id = (l.item->>'title_id')::uuid
  left join private.ratings own_rating on l.item->>'kind' in ('watched','first_show')
    and own_rating.user_id = p.user_id and own_rating.title_id = t.id and own_rating.season_id is null
    and own_rating.score is not null and private.can_see(own_rating.user_id, own_rating.audience)
  where (l.item->>'kind' = 'import' or t.catalog_state = 'available')
    and (before_time is null or (l.at, l.id) < (before_time, before_id))
  order by l.at desc, l.id desc
  limit 60;
$$;


-- ===== 20261118002400_must_import_background.sql =====

-- Must imports keep running on the server after the app is closed: pg_cron calls must-import every minute,
-- and a finished import leaves an "import_done" notification (inbox + push) that opens the import page.

alter table private.notifications drop constraint if exists notifications_kind_check;
alter table private.notifications add constraint notifications_kind_check check (kind in
  ('follow', 'follow_request', 'follow_accepted', 'like', 'comment', 'episode', 'wanted_release', 'import_done'));

create or replace function private.notification_valid(n private.notifications) returns boolean
language sql stable set search_path = '' as $$
  select case when n.kind = 'import_done' then
      exists (select 1 from private.profile_settings s where s.user_id = n.recipient_id and s.lifecycle = 'ready')
      and exists (select 1 from private.import_jobs j where j.id = n.target_id and j.user_id = n.recipient_id and j.state = 'done')
    else private.notification_valid_base(n)
      and case when n.kind = 'wanted_release' then private.wanted_notification_valid(n) else true end
  end;
$$;

create or replace function api.import_finish(job uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare finished private.import_jobs;
begin
  update private.import_jobs j set state = 'done', finished_at = now()
  where j.id = job and j.state = 'running'
    and not exists (select 1 from private.import_items i where i.job_id = j.id and i.state = 'pending')
  returning * into finished;
  if found then
    perform private.notify(finished.user_id, 'import_done', finished.id, null, finished.id::text);
  end if;
  return to_jsonb(finished);
end $$;

-- Running imports for the background worker, oldest first.
create or replace function api.import_running() returns setof jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', j.id, 'user_id', j.user_id) from private.import_jobs j
  join private.profile_settings s on s.user_id = j.user_id and s.lifecycle = 'ready'
  where j.state = 'running' order by j.created_at limit 5;
$$;
revoke execute on function api.import_running() from public, anon, authenticated;
grant execute on function api.import_running() to service_role;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
    and exists (select 1 from pg_available_extensions where name = 'pg_net')
    and exists (select 1 from pg_available_extensions where name = 'supabase_vault') then
    create extension if not exists pg_cron;
    create extension if not exists pg_net;
    create extension if not exists supabase_vault;
    -- Cheap when idle: the function returns at once if no import is running.
    perform cron.schedule('taspa-must-import', '* * * * *', $task$
      select net.http_post(
        url := base.decrypted_secret || '/functions/v1/must-import',
        headers := jsonb_build_object('Content-Type','application/json','x-taspa-worker',worker.decrypted_secret),
        body := '{"action":"cron"}'::jsonb,
        timeout_milliseconds := 90000
      )
      from vault.decrypted_secrets base, vault.decrypted_secrets worker
      where base.name = 'taspa_project_url' and worker.name = 'taspa_worker_key'
        and exists (select 1 from private.import_jobs where state = 'running');
    $task$);
  end if;
end;
$$;


-- ===== 20261118002500_import_retry.sql =====

-- Keep why a Must title was skipped, and let the user re-queue skipped titles after a fix.

alter table private.import_items add column if not exists note text;

drop function if exists api.import_skip(uuid, bigint);
create or replace function api.import_skip(job uuid, item bigint, note text default null) returns void
language sql security definer set search_path = '' as $$
  with changed as (
    update private.import_items set state = 'unmatched', note = left(import_skip.note, 300)
    where job_id = job and must_id = item and state = 'pending' returning 1
  )
  update private.import_jobs set done = done + (select count(*) from changed) where id = job;
$$;
revoke execute on function api.import_skip(uuid, bigint, text) from public, anon, authenticated;
grant execute on function api.import_skip(uuid, bigint, text) to service_role;

-- Puts the latest import's "Not found" titles back in the queue; the import then runs again for them only.
create or replace function api.import_retry() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare job private.import_jobs; requeued int;
begin
  select * into job from private.import_jobs j where j.user_id = (select private.ready_user())
  order by j.created_at desc limit 1 for update;
  if not found then return null; end if;
  update private.import_items set state = 'pending', note = null where job_id = job.id and state = 'unmatched';
  get diagnostics requeued = row_count;
  if requeued > 0 then
    update private.import_jobs set state = 'running', finished_at = null, done = greatest(done - requeued, 0)
    where id = job.id;
  end if;
  return api.import_status();
end $$;
grant execute on function api.import_retry() to authenticated;

create or replace function api.import_status() returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(j) || jsonb_build_object('unmatched', coalesce((
      select jsonb_agg(jsonb_build_object('title', i.data->>'title', 'year', i.data->'year', 'kind', i.data->>'kind',
        'note', i.note) order by i.data->>'title')
      from private.import_items i where i.job_id = j.id and i.state = 'unmatched'), '[]'::jsonb))
  from private.import_jobs j
  where j.user_id = (select private.ready_user())
  order by j.created_at desc limit 1;
$$;


-- ===== 20261119000100_feedback_fixes.sql =====

-- Search: what the viewer already did with each result, as the search sheet's quick-action keys.
create or replace function api.my_title_marks(tmdb_ids bigint[])
returns table (kind api.media_kind, tmdb_id bigint, marks text[])
language sql stable security definer set search_path = '' as $$
  with me as (select (select private.ready_user()) as id)
  select t.kind, t.tmdb_id, array_remove(array[
      case when exists (select 1 from private.wanted_entries w
        where w.user_id = me.id and w.title_id = t.id and w.added_at is not null) then 'want' end,
      case when exists (select 1 from private.movie_viewings v
        where v.user_id = me.id and v.movie_id = t.id and v.deleted_at is null) then 'watched' end,
      case when exists (select 1 from private.tracked_shows sh
        where sh.user_id = me.id and sh.show_id = t.id and sh.intent is not null) then 'start' end
    ], null)
  from me join api.titles t on t.tmdb_id = any(tmdb_ids[1:100]);
$$;
grant execute on function api.my_title_marks(bigint[]) to authenticated;

-- Notifications say what happened, in the inbox and in the push body.
create or replace function private.notification_text(n private.notifications) returns text
language sql stable set search_path = '' as $$
  select case n.kind
    when 'follow' then '@' || a.handle || ' started following you'
    when 'follow_request' then '@' || a.handle || ' wants to follow you'
    when 'follow_accepted' then '@' || a.handle || ' accepted your follow request'
    when 'like' then '@' || a.handle || ' liked your review of ' || coalesce(reviewed.display_title, 'a title')
    when 'comment' then '@' || a.handle || ' commented on your review of ' || coalesce(reviewed.display_title, 'a title')
    when 'episode' then 'New episode of ' || coalesce(t.display_title, 'a show you watch')
    when 'wanted_release' then coalesce(t.display_title, 'A title from your Want list') || ' comes out '
      || coalesce(to_char(n.release_day, 'Mon FMDD'), 'soon')
    when 'import_done' then 'Your Must import is finished'
    else 'Something new in Taspa'
  end
  from (select 1) x
  left join api.profiles a on a.user_id = n.actor_id
  left join private.reviews r on n.kind in ('like', 'comment') and r.discussion_id = n.target_id
  left join api.titles reviewed on reviewed.id = r.title_id
  left join api.titles t on n.kind in ('episode', 'wanted_release') and t.id = n.target_id;
$$;

create function api.inbox_page(before_time timestamptz default null, before_id uuid default null, item_id uuid default null)
returns table (id uuid, kind text, actor_id uuid, target_id uuid, event_at timestamptz, read_at timestamptz, message text)
language sql stable security definer set search_path = '' as $$
  select n.id, n.kind, n.actor_id, n.target_id, n.event_at, n.read_at, private.notification_text(n)
  from private.notifications n
  left join private.notification_preferences p on p.user_id = n.recipient_id and p.category = private.notification_category(n.kind)
  where n.recipient_id = (select private.ready_user()) and coalesce(p.inbox,true) and private.notification_valid(n)
    and (item_id is null or n.id = item_id)
    and (before_time is null or (n.event_at,n.id) < (before_time,before_id))
  order by n.event_at desc,n.id desc limit 20;
$$;
grant execute on function api.inbox_page(timestamptz, uuid, uuid) to authenticated;

-- The push worker reads the body for a claimed delivery; it stays a separate call so push_destination keeps its shape.
create or replace function api.push_message(claim uuid) returns text
language sql stable security definer set search_path = '' as $$
  select private.notification_text(n) from private.push_deliveries q
  join private.notifications n on n.id = q.notification_id and n.generation = q.generation
  where q.lease_id = claim;
$$;
revoke execute on function api.push_message(uuid) from public, anon, authenticated;
grant execute on function api.push_message(uuid) to service_role;

-- Everything the owner logged, as one JSON document they can download. Titles are keyed by TMDB id so any app can match them.
create or replace function api.export_library()
returns jsonb language sql stable security definer set search_path = '' as $$
  with me as (select private.ready_user() as id),
  touched as (
    select w.title_id from private.wanted_entries w, me where w.user_id = me.id and w.added_at is not null
    union select v.movie_id from private.movie_viewings v, me where v.user_id = me.id and v.deleted_at is null
    union select s.show_id from private.tracked_shows s, me where s.user_id = me.id
    union select r.title_id from private.ratings r, me where r.user_id = me.id and r.score is not null
    union select r.title_id from private.reviews r, me where r.user_id = me.id and r.body is not null
  )
  select jsonb_build_object('format', 'taspa-library', 'version', 1, 'exported_at', now(),
    'titles', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'kind', t.kind, 'tmdb_id', t.tmdb_id, 'title', t.display_title,
      'original_title', t.original_title, 'release_date', t.first_release_day,
      'want_added_at', (select w.added_at from private.wanted_entries w
        where w.user_id = me.id and w.title_id = t.id and w.added_at is not null),
      'viewings', (select jsonb_agg(jsonb_build_object('watched_on', v.watched_on, 'logged_at', v.logged_at) order by v.logged_at)
        from private.movie_viewings v where v.user_id = me.id and v.movie_id = t.id and v.deleted_at is null),
      'status', (select s.intent from private.tracked_shows s where s.user_id = me.id and s.show_id = t.id),
      'started_at', (select s.tracking_started_at from private.tracked_shows s where s.user_id = me.id and s.show_id = t.id),
      'episodes', (select jsonb_agg(jsonb_build_object('season', se.season_number, 'episode', e.episode_number, 'watched_on', m.watched_on)
          order by se.season_number, e.episode_number)
        from private.episode_marks m join api.episodes e on e.id = m.episode_id join api.seasons se on se.id = e.season_id
        where m.user_id = me.id and m.show_id = t.id and m.watched),
      'ratings', (select jsonb_agg(jsonb_build_object('season', se.season_number, 'score', r.score) order by se.season_number nulls first)
        from private.ratings r left join api.seasons se on se.id = r.season_id
        where r.user_id = me.id and r.title_id = t.id and r.score is not null),
      'reviews', (select jsonb_agg(jsonb_build_object('season', se.season_number, 'body', r.body, 'spoiler', r.spoiler,
          'published_at', r.published_at) order by se.season_number nulls first)
        from private.reviews r left join api.seasons se on se.id = r.season_id
        where r.user_id = me.id and r.title_id = t.id and r.body is not null)
    )) order by t.kind, t.display_title), '[]'::jsonb))
  from me, touched x join api.titles t on t.id = x.title_id
$$;
revoke execute on function api.export_library() from public, anon;
grant execute on function api.export_library() to authenticated;


-- ===== 20261120000000_profile_insights.sql =====

-- Watch statistics for the profile Insights screen. Same audience as the library (profile_library);
-- ratings are additionally gated by their own audience. Period is [from_day, to_day); no bounds = all time,
-- which also counts undated logs. Streaks, months and weekdays are derived on the client from `days`.
create or replace function api.profile_insights(owner_id uuid, from_day date default null, to_day date default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with allowed as materialized (
    select s.user_id, coalesce(s.timezone, 'UTC') as tz from private.profile_settings s
    where s.user_id = owner_id and private.can_see(s.user_id, s.library_audience)
  ), watches as materialized (
    -- Without a chosen date a log counts on the owner's local day it was made. Imported episodes have no
    -- stamp (the import clears marked_at), so they stay undated.
    select 'movie' as kind, v.movie_id as title_id,
      coalesce(v.watched_on, (v.logged_at at time zone a.tz)::date) as day, coalesce(t.runtime_minutes, 0) as minutes,
      row_number() over (partition by v.movie_id order by v.watched_on nulls first, v.logged_at) > 1 as rewatch
    from private.movie_viewings v join allowed a on a.user_id = v.user_id
    join api.titles t on t.id = v.movie_id
    where v.deleted_at is null
    union all
    select 'episode', m.show_id, coalesce(m.watched_on, (m.marked_at at time zone a.tz)::date),
      coalesce(e.runtime_minutes, t.runtime_minutes, 0), false
    from private.episode_marks m join allowed a on a.user_id = m.user_id
    join api.episodes e on e.id = m.episode_id
    join api.titles t on t.id = m.show_id
    where m.watched
  ), period as materialized (
    select * from watches w
    where (from_day is null or w.day >= from_day) and (to_day is null or w.day < to_day)
  ), titles as materialized (
    select p.title_id, t.kind, t.display_title, t.poster_path, t.first_release_day,
      sum(p.minutes) as minutes, count(*) as plays, md.details
    from period p join api.titles t on t.id = p.title_id
    left join private.title_metadata md on md.title_id = p.title_id
    group by p.title_id, t.kind, t.display_title, t.poster_path, t.first_release_day, md.details
  ), rated as materialized (
    select x.title_id, x.kind, x.display_title, x.poster_path, r.score,
      (x.details->'rating'->>'value')::numeric as imdb
    from titles x join private.ratings r on r.title_id = x.title_id
    where r.user_id = owner_id and r.season_id is null and r.score is not null
      and private.can_see(r.user_id, r.audience)
  ), shows as materialized (
    -- Current status of the shows watched in the period; all time also counts shows started with no episode yet.
    select private.show_snapshot(owner_id, s.show_id) as snap
    from private.tracked_shows s join allowed a on a.user_id = s.user_id
    where s.intent is not null
      and ((from_day is null and to_day is null) or s.show_id in (select title_id from titles where kind = 'show'))
  ), people as (
    select role, tmdb_id, name, portrait, count(*) as titles from (
      select distinct on (x.title_id, role, (p->>'tmdb_id')) role, x.title_id,
        (p->>'tmdb_id')::bigint as tmdb_id, p->>'name' as name, p->>'portrait' as portrait
      from titles x
      cross join lateral (
        select 'actor' as role, c as p from jsonb_array_elements(coalesce(x.details->'cast', '[]')) c
        union all
        select 'creator', c from jsonb_array_elements(coalesce(x.details->'creators', '[]')) c
      ) credit
    ) d group by role, tmdb_id, name, portrait
  )
  select jsonb_build_object(
    'minutes', (select coalesce(sum(minutes), 0) from period),
    'movie_minutes', (select coalesce(sum(minutes), 0) from period where kind = 'movie'),
    'episode_minutes', (select coalesce(sum(minutes), 0) from period where kind = 'episode'),
    'movies', (select count(*) from period where kind = 'movie'),
    'episodes', (select count(*) from period where kind = 'episode'),
    'rewatches', (select count(*) from period where rewatch),
    'previous_minutes', case when from_day is not null and to_day is not null then
      (select coalesce(sum(minutes), 0) from watches w
       where w.day >= from_day - (to_day - from_day) and w.day < from_day) end,
    'days', (select coalesce(jsonb_agg(d order by d.day), '[]') from (
      select day, sum(minutes) as minutes, coalesce(sum(minutes) filter (where kind = 'movie'), 0) as movie_minutes,
        count(*) filter (where kind = 'movie') as movies,
        count(*) filter (where kind = 'episode') as episodes
      from period where day is not null group by day) d),
    'genres', (select coalesce(jsonb_agg(g order by g.minutes desc), '[]') from (
      select name, sum(x.minutes) as minutes
      from titles x cross join lateral jsonb_array_elements_text(coalesce(x.details->'genres', '[]')) name
      group by name order by sum(x.minutes) desc limit 8) g),
    'decades', (select coalesce(jsonb_agg(d order by d.decade), '[]') from (
      select (extract(year from first_release_day)::int / 10) * 10 as decade, count(*) as titles
      from titles where first_release_day is not null group by 1) d),
    'ratings', jsonb_build_object(
      'count', (select count(*) from rated),
      'average', (select round(avg(score), 1) from rated),
      'imdb_delta', (select round(avg(score - imdb), 1) from rated where imdb is not null),
      'buckets', (select jsonb_agg((select count(*) from rated where ceil(score) = b) order by b)
        from generate_series(1, 10) b),
      'disagreements', (select coalesce(jsonb_agg(r order by abs(r.delta) desc), '[]') from (
        select title_id as id, kind, display_title, poster_path, score, imdb, score - imdb as delta
        from rated where imdb is not null and abs(score - imdb) >= 1
        order by abs(score - imdb) desc limit 5) r)),
    'actors', (select coalesce(jsonb_agg(p order by p.titles desc, p.name), '[]') from (
      select tmdb_id, name, portrait, titles from people
      where role = 'actor' and titles > 1 order by titles desc, name limit 10) p),
    'creators', (select coalesce(jsonb_agg(p order by p.titles desc, p.name), '[]') from (
      select tmdb_id, name, portrait, titles from people
      where role = 'creator' and titles > 1 order by titles desc, name limit 10) p),
    'show_status', (select coalesce(jsonb_object_agg(status, n), '{}') from (
      select snap->>'status' as status, count(*) as n from shows group by 1) s),
    'dropped_after', (select round(avg((snap->>'watched')::numeric), 1) from shows where snap->>'status' = 'dropped'),
    'top_shows', (select coalesce(jsonb_agg(s order by s.minutes desc), '[]') from (
      select title_id as id, display_title, poster_path, minutes, plays as episodes
      from titles where kind = 'show' order by minutes desc limit 5) s),
    'top_titles', (select coalesce(jsonb_agg(s order by s.minutes desc), '[]') from (
      select title_id as id, display_title, poster_path, minutes
      from titles where poster_path is not null order by minutes desc limit 3) s)
  ) from allowed;
$$;
grant execute on function api.profile_insights(uuid, date, date) to anon, authenticated;

-- Profile header: counts on the list tabs (now with reviews) and this year's watch time per month for the
-- Insights strip. Same as the baseline version otherwise. The year follows the owner's time zone.
create or replace function api.profile_page(target uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('user_id', p.user_id, 'handle', p.handle, 'display_name', p.display_name,
    'private', s.profile_private, 'own', p.user_id = (select auth.uid()),
    'can_read', private.can_see(p.user_id, 'public'),
    'can_read_library', private.can_see(p.user_id, s.library_audience),
    'relationship', (select f.state from private.follows f where f.follower_id = (select auth.uid()) and f.followed_id = p.user_id))
  || case when private.can_see(p.user_id, 'public') then jsonb_build_object('bio', s.bio,
    'followers', (select count(*) from private.follows f where f.followed_id = p.user_id and f.state = 'accepted' and private.profile_visible(f.follower_id)),
    'following', (select count(*) from private.follows f where f.follower_id = p.user_id and f.state = 'accepted' and private.profile_visible(f.followed_id)),
    'reviews', (select count(*) from private.reviews r where r.user_id = p.user_id and private.review_visible(r)))
    else '{}'::jsonb end
  || case when private.can_see(p.user_id, s.library_audience) then jsonb_build_object(
    'movies', (select count(distinct movie_id) from private.movie_viewings where user_id = p.user_id and deleted_at is null),
    'shows', (select count(distinct show_id) from private.episode_marks where user_id = p.user_id and watched),
    'series', (select count(*) from (
        select show_id from private.tracked_shows where user_id = p.user_id and intent is not null
        union
        select show_id from private.episode_marks where user_id = p.user_id and watched) x),
    'want', (select count(*) from private.wanted_entries w join api.titles t on t.id = w.title_id and t.catalog_state = 'available'
        where w.user_id = p.user_id and w.added_at is not null),
    'episodes', (select count(*) from private.episode_marks where user_id = p.user_id and watched),
    'year', extract(year from now() at time zone coalesce(s.timezone, 'UTC'))::int,
    'year_months', (select jsonb_agg(coalesce(m.minutes, 0) order by g.n) from generate_series(1, 12) g(n)
      left join (
        select extract(month from w.day)::int as month, sum(w.minutes) as minutes from (
          -- Same day rule as profile_insights: chosen date, else the owner's local day of the log.
          select coalesce(v.watched_on, (v.logged_at at time zone coalesce(s.timezone, 'UTC'))::date) as day,
            coalesce(t.runtime_minutes, 0) as minutes
          from private.movie_viewings v join api.titles t on t.id = v.movie_id
          where v.user_id = p.user_id and v.deleted_at is null
          union all
          select coalesce(em.watched_on, (em.marked_at at time zone coalesce(s.timezone, 'UTC'))::date),
            coalesce(e.runtime_minutes, t.runtime_minutes, 0)
          from private.episode_marks em join api.episodes e on e.id = em.episode_id join api.titles t on t.id = em.show_id
          where em.user_id = p.user_id and em.watched
        ) w where extract(year from w.day) = extract(year from now() at time zone coalesce(s.timezone, 'UTC'))
        group by 1
      ) m on m.month = g.n))
    else '{}'::jsonb end
  || case when p.user_id = (select auth.uid()) then jsonb_build_object(
    'library_audience', s.library_audience, 'tracking_activity', s.tracking_activity, 'market', s.market, 'timezone', s.timezone)
    else '{}'::jsonb end
  from api.profiles p join private.profile_settings s using (user_id)
  where p.user_id = target and private.profile_visible(p.user_id);
$$;

-- Episode list: `marked_on` is the owner's local day an episode was ticked, shown when no watch date was chosen.
-- Imported episodes have no stamp and still read "Date unknown".
create or replace function api.show_episode_page(title_id uuid, selected_season uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('episodes', coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'number', e.episode_number, 'title', e.display_title, 'released', private.episode_released(e.release_day),
    'release_day', e.release_day, 'watched', coalesce(m.watched, false), 'watched_on', m.watched_on,
    'marked_on', (m.marked_at at time zone coalesce(
      (select ps.timezone from private.profile_settings ps where ps.user_id = m.user_id), 'UTC'))::date,
    'revision', coalesce(m.revision, 0)
  ) order by e.episode_number, e.id), '[]'::jsonb))
  from api.episodes e
  join api.seasons s on s.id = e.season_id and s.available
  join api.titles t on t.id = e.show_id and t.catalog_state = 'available'
  left join private.episode_marks m on m.user_id = (select auth.uid()) and m.episode_id = e.id
    and private.profile_visible(m.user_id)
  where e.show_id = title_id and e.season_id = selected_season and e.available;
$$;
