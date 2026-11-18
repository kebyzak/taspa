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
