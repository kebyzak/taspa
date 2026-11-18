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
