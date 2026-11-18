create function private.followed_activity(before_time timestamptz, before_id uuid, target uuid, opinions_only boolean)
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
    and (target is null or a.title_id = target)
    and (not opinions_only or a.kind in ('review','rating'))
    and (before_time is null or (a.created_at,a.id) < (before_time,before_id))
  order by a.created_at desc,a.id desc limit 20;
$$;

create or replace function api.following_feed(before_time timestamptz default null, before_id uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  select * from private.followed_activity(before_time,before_id,null,false);
$$;

create function api.followed_recommendations(target uuid default null)
returns setof jsonb language sql stable security definer set search_path = '' as $$
  select * from private.followed_activity(null,null,target,target is null) limit 5;
$$;
grant execute on function api.followed_recommendations(uuid) to authenticated;
