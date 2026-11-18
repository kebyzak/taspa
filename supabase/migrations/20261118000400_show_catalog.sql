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
