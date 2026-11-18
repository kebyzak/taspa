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
