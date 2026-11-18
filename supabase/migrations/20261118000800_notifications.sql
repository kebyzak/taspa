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

create function api.inbox_page(before_time timestamptz default null, before_id uuid default null, item_id uuid default null)
returns table (id uuid, kind text, actor_id uuid, target_id uuid, event_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select n.id, n.kind, n.actor_id, n.target_id, n.event_at, n.read_at
  from private.notifications n
  left join private.notification_preferences p on p.user_id = n.recipient_id and p.category = private.notification_category(n.kind)
  where n.recipient_id = (select private.ready_user()) and coalesce(p.inbox,true) and private.notification_valid(n)
    and (item_id is null or n.id = item_id)
    and (before_time is null or (n.event_at,n.id) < (before_time,before_id))
  order by n.event_at desc,n.id desc limit 20;
$$;
grant execute on function api.inbox_page(timestamptz, uuid, uuid) to authenticated;

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
