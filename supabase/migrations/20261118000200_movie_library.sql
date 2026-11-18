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
