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
  score smallint check (score between 1 and 10),
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
