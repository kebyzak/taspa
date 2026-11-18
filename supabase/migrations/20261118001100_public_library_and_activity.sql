create function api.profile_library(owner_id uuid, section text, before_time timestamptz default null,
  before_title uuid default null) returns table (title jsonb, activity_at timestamptz)
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
  ), page as (
    select t,e.id,e.at from entries e join api.titles t on t.id = e.id and t.catalog_state = 'available'
    where before_time is null or (e.at,e.id) < (before_time,before_title)
    order by e.at desc,e.id desc limit 20
  )
  select to_jsonb(p.t) - 'overview' - 'backdrop_path' ||
    case when (p.t).kind = 'show' and section = 'watched_shows' then jsonb_build_object('progress',
      private.show_snapshot(owner_id,p.id) - 'next' - 'show_revision' - 'wanted_revision' - 'wanted' - 'viewing_count')
      else '{}'::jsonb end,
    p.at from page p order by p.at desc,p.id desc;
$$;
grant execute on function api.profile_library(uuid,text,timestamptz,uuid) to anon, authenticated;

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
