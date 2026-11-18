create function private.allowed_audience(actor uuid, choice private.audience) returns private.audience
language sql stable set search_path = '' as $$
  select case when choice = 'public' and s.profile_private then 'followers'::private.audience
              else choice end
  from private.profile_settings s where s.user_id = actor;
$$;

create function private.check_opinion_target(title uuid, season uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not exists (select 1 from api.titles t where t.id = title and t.catalog_state = 'available')
    or (season is not null and not exists (select 1 from api.seasons s where s.id = season and s.show_id = title and s.available)) then
    raise exception using errcode = '22023', message = 'opinion_target_unavailable';
  end if;
end;
$$;

create function api.title_opinions(title uuid, season uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('rating_count', (
      select count(*) from private.ratings r join private.profile_settings s on s.user_id = r.user_id
      where r.title_id = title and r.season_id is not distinct from season and r.score is not null
        and r.audience = 'public' and s.lifecycle = 'ready' and not s.profile_private
    ), 'average', (
      select case when count(*) >= 5 then round(avg(r.score) / 2, 1) end
      from private.ratings r join private.profile_settings s on s.user_id = r.user_id
      where r.title_id = title and r.season_id is not distinct from season and r.score is not null
        and r.audience = 'public' and s.lifecycle = 'ready' and not s.profile_private
    ), 'my_rating', (
      select jsonb_build_object('score', r.score, 'audience', r.audience, 'revision', r.revision)
      from private.ratings r
      where r.user_id = (select auth.uid()) and private.profile_visible(r.user_id)
        and r.title_id = title and r.season_id is not distinct from season
    ), 'my_review', (
      select jsonb_build_object('body', r.body, 'audience', r.audience, 'spoiler', r.spoiler,
        'discussion_id', r.discussion_id, 'revision', r.revision)
      from private.reviews r
      where r.user_id = (select auth.uid()) and private.profile_visible(r.user_id)
        and r.title_id = title and r.season_id is not distinct from season
    ))
  where exists (select 1 from api.titles t where t.id = title and t.catalog_state = 'available');
$$;
grant execute on function api.title_opinions(uuid, uuid) to anon, authenticated;

create function api.set_rating(title uuid, season uuid, score_value smallint, audience_value text,
  observed_revision bigint, share boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); current_rating private.ratings; effective private.audience;
begin
  perform private.check_opinion_target(title, season);
  perform 1 from private.profile_settings where user_id = actor for update;
  effective := private.allowed_audience(actor, audience_value::private.audience);
  select * into current_rating from private.ratings r where r.user_id = actor and r.title_id = title and r.season_id is not distinct from season;
  if coalesce(current_rating.revision, 0) is distinct from observed_revision then
    raise exception using errcode = '40001', message = 'opinion_conflict';
  end if;
  insert into private.ratings as r (user_id,title_id,season_id,score,audience,revision)
  values (actor,title,season,score_value,effective,1)
  on conflict (user_id,title_id,season_id) do update set
    score = excluded.score, audience = excluded.audience, revision = r.revision + 1
  returning * into current_rating;
  if share and score_value is not null and effective <> 'only_me' then
    insert into private.activity(actor_id,kind,title_id,season_id,rating_id,audience,source_key)
    values(actor,'rating',title,season,current_rating.id,effective,'rating:' || current_rating.id)
    on conflict (source_key) do update set audience = excluded.audience;
  end if;
  return api.title_opinions(title, season);
end;
$$;
grant execute on function api.set_rating(uuid, uuid, smallint, text, bigint, boolean) to authenticated;

create function api.save_review(title uuid, season uuid, content text, has_spoiler boolean,
  audience_value text, observed_revision bigint, discussion uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.ready_user();
  old private.reviews;
  effective private.audience;
  discussion_value uuid;
  public_at timestamptz;
begin
  perform private.check_opinion_target(title, season);
  perform 1 from private.profile_settings where user_id = actor for update;
  effective := private.allowed_audience(actor, audience_value::private.audience);
  select * into old from private.reviews r where r.user_id = actor and r.title_id = title and r.season_id is not distinct from season;
  if coalesce(old.revision, 0) is distinct from observed_revision then
    raise exception using errcode = '40001', message = 'opinion_conflict';
  end if;
  content := nullif(btrim(content), '');
  if content is not null and effective <> 'only_me' then
    discussion_value := coalesce(old.discussion_id, discussion);
    if discussion_value is null then raise exception using errcode = '22023', message = 'discussion_required'; end if;
    public_at := coalesce(old.published_at, now());
  end if;
  if old.discussion_id is not null and discussion_value is null then
    delete from private.activity where review_id = old.discussion_id;
    delete from private.review_comments where review_id = old.discussion_id;
    delete from private.review_likes where review_id = old.discussion_id;
  end if;
  insert into private.reviews as r(user_id,title_id,season_id,discussion_id,body,spoiler,audience,published_at,revision)
  values(actor,title,season,discussion_value,content,coalesce(has_spoiler,false),effective,public_at,1)
  on conflict (user_id,title_id,season_id) do update set
    discussion_id = excluded.discussion_id, body = excluded.body, spoiler = excluded.spoiler,
    audience = excluded.audience, published_at = excluded.published_at, revision = r.revision + 1;
  if discussion_value is not null then
    insert into private.activity(actor_id,kind,title_id,season_id,review_id,audience,source_key,created_at)
    values(actor,'review',title,season,discussion_value,effective,'review:' || discussion_value,public_at)
    on conflict (source_key) do update set audience = excluded.audience;
  end if;
  return api.title_opinions(title, season);
end;
$$;
grant execute on function api.save_review(uuid, uuid, text, boolean, text, bigint, uuid) to authenticated;

create function private.review_card(r private.reviews, reveal boolean default false) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', r.discussion_id, 'author_id', r.user_id,
    'handle', p.handle, 'title_id', r.title_id, 'title', t.display_title, 'season_id', r.season_id,
    'season', s.display_title, 'published_at', r.published_at, 'protected', r.spoiler or private.season_reveal_required(r.season_id),
    'body', case when reveal or not r.spoiler and not private.season_reveal_required(r.season_id) then r.body end,
    'score', (select score from private.ratings rate where rate.user_id = r.user_id and rate.title_id = r.title_id
      and rate.season_id is not distinct from r.season_id and private.can_see(rate.user_id,rate.audience)),
    'likes', (select count(*) from private.review_likes l where l.review_id = r.discussion_id and private.profile_visible(l.user_id)),
    'liked', exists (select 1 from private.review_likes l where l.review_id = r.discussion_id and l.user_id = (select auth.uid())),
    'public', r.audience = 'public' and not settings.profile_private
  )
  from api.profiles p join private.profile_settings settings on settings.user_id = p.user_id
  join api.titles t on t.id = r.title_id
  left join api.seasons s on s.id = r.season_id
  where p.user_id = r.user_id and t.catalog_state = 'available';
$$;

create function api.opinion_page(title uuid default null, season uuid default null, author uuid default null,
  before_time timestamptz default null, before_id uuid default null) returns setof jsonb
language sql stable security definer set search_path = '' as $$
  select private.review_card(r)
  from private.reviews r join api.titles t on t.id = r.title_id and t.catalog_state = 'available'
  where private.review_visible(r) and (title is not null or author is not null)
    and (title is null or (r.title_id = title and r.season_id is not distinct from season))
    and (author is null or r.user_id = author)
    and (before_time is null or (r.published_at,r.discussion_id) < (before_time,before_id))
  order by r.published_at desc,r.discussion_id desc limit 20;
$$;
grant execute on function api.opinion_page(uuid, uuid, uuid, timestamptz, uuid) to anon, authenticated;

create function api.review_detail(review uuid, reveal boolean default false, reveal_comment uuid default null,
  after_time timestamptz default null, after_id uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select private.review_card(r,reveal) || jsonb_build_object('comments',
    case when reveal or (not r.spoiler and not private.season_reveal_required(r.season_id)) then (
      select coalesce(jsonb_agg(row_data order by created_at,id),'[]'::jsonb) from (
        select c.created_at,c.id,jsonb_build_object('id',c.id,'author_id',c.user_id,'handle',p.handle,
          'body',case when not c.spoiler or c.id = reveal_comment then c.body end,
          'spoiler',c.spoiler,'created_at',c.created_at,'revision',c.revision) as row_data
        from private.review_comments c join api.profiles p on p.user_id = c.user_id
        where c.review_id = r.discussion_id and not c.hidden and private.profile_visible(c.user_id)
          and (after_time is null or (c.created_at,c.id) > (after_time,after_id))
        order by c.created_at,c.id limit 30
      ) comments
    ) else '[]'::jsonb end)
  from private.reviews r where r.discussion_id = review and private.review_visible(r);
$$;
grant execute on function api.review_detail(uuid, boolean, uuid, timestamptz, uuid) to anon, authenticated;

create function api.set_review_like(review uuid, liked boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); target private.reviews;
begin
  select * into target from private.reviews where discussion_id = review;
  if not found or liked is null then raise exception using errcode = '42501', message = 'unavailable'; end if;
  perform private.lock_pair(actor,target.user_id);
  select * into target from private.reviews where discussion_id = review for share;
  if not found or not private.review_visible(target) then raise exception using errcode = '42501', message = 'unavailable'; end if;
  if liked then
    insert into private.review_likes (review_id,user_id) values (review,actor) on conflict do nothing;
    if found then perform private.notify(target.user_id,'like',review,actor,review::text); end if;
  else
    delete from private.review_likes where review_id = review and user_id = actor;
  end if;
end;
$$;
grant execute on function api.set_review_like(uuid, boolean) to authenticated;

create function api.set_comment(review uuid, comment uuid, action text, content text default null,
  spoiler boolean default false, observed_revision bigint default null, reveal boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user(); target private.reviews;
begin
  select * into target from private.reviews where discussion_id = review;
  if not found or comment is null then raise exception using errcode = '42501', message = 'unavailable'; end if;
  perform private.lock_pair(actor,target.user_id);
  select * into target from private.reviews where discussion_id = review for share;
  if not found or not private.review_visible(target)
    or (not reveal and (target.spoiler or private.season_reveal_required(target.season_id))) then
    raise exception using errcode = '42501', message = 'unavailable';
  end if;
  if action = 'add' then
    insert into private.review_comments(id,review_id,user_id,body,spoiler)
    values(comment,review,actor,btrim(content),spoiler) on conflict do nothing;
    if found then perform private.notify(target.user_id,'comment',review,actor,comment::text); end if;
  elsif action = 'edit' then
    update private.review_comments c set body = btrim(content), spoiler = set_comment.spoiler, revision = c.revision + 1
    where c.id = comment and c.review_id = review and c.user_id = actor and c.revision = observed_revision and not c.hidden;
    if not found then raise exception using errcode = '40001', message = 'comment_conflict'; end if;
  elsif action = 'remove' then
    delete from private.review_comments c where c.id = comment and c.review_id = review and c.user_id = actor and c.revision = observed_revision;
  elsif action = 'hide' and target.user_id = actor then
    update private.review_comments c set hidden = true, revision = c.revision + 1
    where c.id = comment and c.review_id = review and c.revision = observed_revision
      and private.profile_visible(c.user_id);
  else raise exception using errcode = '42501', message = 'unavailable';
  end if;
end;
$$;
grant execute on function api.set_comment(uuid, uuid, text, text, boolean, bigint, boolean) to authenticated;

create function api.submit_report(target uuid, kind_value text, reason_value text) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.ready_user();
begin
  if not (case kind_value when 'profile' then private.profile_visible(target)
    when 'review' then exists (select 1 from private.reviews r where r.discussion_id = target and private.review_visible(r))
    when 'comment' then exists (select 1 from private.review_comments c join private.reviews r on r.discussion_id = c.review_id
      where c.id = target and private.profile_visible(c.user_id) and not c.hidden and private.review_visible(r))
    else false end) then raise exception using errcode = '42501', message = 'unavailable'; end if;
  if (select count(*) from private.reports where reporter_id = actor and created_at > now() - interval '1 hour') >= 10 then
    raise exception using errcode = '22023', message = 'report_limit';
  end if;
  insert into private.reports(reporter_id,target_id,target_type,reason)
  values(actor,target,kind_value,btrim(reason_value)) on conflict do nothing;
end;
$$;
grant execute on function api.submit_report(uuid, text, text) to authenticated;

create function api.following_feed(before_time timestamptz default null, before_id uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id',a.id,'created_at',a.created_at,'kind',a.kind,'actor_id',a.actor_id,
    'handle',p.handle,'title_id',t.id,'title',t.display_title,'tmdb_id',t.tmdb_id,'media',t.kind,
    'season',s.display_title,'review',case when a.kind = 'review' then private.review_card(r) end,
    'score',case when a.kind = 'rating' then rating.score end)
  from private.activity a
  join private.follows f on f.followed_id = a.actor_id and f.follower_id = (select private.ready_user()) and f.state = 'accepted'
  join api.profiles p on p.user_id = a.actor_id
  join api.titles t on t.id = a.title_id and t.catalog_state = 'available'
  join private.profile_settings settings on settings.user_id = a.actor_id
  left join private.reviews r on r.discussion_id = a.review_id
  left join private.ratings rating on rating.id = a.rating_id
  left join api.seasons s on s.id = a.season_id
  where private.can_see(a.actor_id,a.audience)
    and case a.kind
      when 'review' then private.review_visible(r)
      when 'rating' then rating.score is not null and private.can_see(rating.user_id,rating.audience)
      when 'first_movie' then settings.tracking_activity and private.can_see(a.actor_id,settings.library_audience)
        and exists (select 1 from private.movie_viewings m where m.user_id = a.actor_id and m.movie_id = a.title_id and m.deleted_at is null)
      when 'first_show' then settings.tracking_activity and private.can_see(a.actor_id,settings.library_audience)
        and exists (select 1 from private.tracked_shows sh where sh.user_id = a.actor_id and sh.show_id = a.title_id and sh.intent is not null)
      else false end
    and (before_time is null or (a.created_at,a.id) < (before_time,before_id))
  order by a.created_at desc,a.id desc limit 20;
$$;
grant execute on function api.following_feed(timestamptz, uuid) to authenticated;
