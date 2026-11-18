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
