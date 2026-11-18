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
