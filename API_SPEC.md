# Taspa API specification

**Supabase contracts · 18 November 2026**

This document describes interfaces for implementation. It defines the call boundary, authorization, and essential inputs and outputs. [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) defines persistence and [PRODUCT_SPEC.md](PRODUCT_SPEC.md) defines visible behavior.

## Conventions

- Flutter initializes one Supabase client against the selected project's URL and publishable key. Auth supplies the bearer JWT for signed-in calls. Guests use the publishable credential for explicitly allowed public operations. Edge handlers accepting a guest publishable key treat it as public and throttle accordingly. For a supplied user JWT, validate the token and its intended project and reject an invalid credential. Never downgrade an invalid bearer call to guest. For user-only functions use the supported Supabase user authentication mode and verify the user in the handler. Internal functions authorize a worker-only credential before using privileged access. [Supabase Edge authorization headers](https://supabase.com/docs/guides/functions/auth-headers)
- Use direct PostgREST queries against `api` grants, PostgreSQL RPC for atomic changes or privacy-sensitive read shapes, and Edge Functions under `functions/v1` for foreign and privileged operations. SQL parameter names and generated models may follow project conventions. The operation semantics here are stable. Clients never supply a trusted `user_id` for a self-operation. Others' IDs are target IDs only.
- UUIDs identify Taspa titles, seasons and other entities. Use provider IDs only for uncached catalog hydration and stable mapping. Day strings use ISO date, timestamps UTC ISO 8601, and rating score uses half-star units 1–10. Null rating means cleared. Optional dates, ratings and review bodies remain independent. All server responses project only documented fields.
- List responses contain items and an optional next cursor. Default page size 20, cap 50. Catalog search/discovery follows provider paging behind the Edge contract, with inputs limited to the first 10 pages per query unless measured demand justifies more. Database query-cursors include ordered key(s) plus ID, tied to scope, filter and sort. Validate all cursor fields. Use allowlisted sorts and safe typed parameters, no interpolated SQL. For manual direct-query keyset use the corresponding timestamp and UUID together.
- Tracking is desired-state and idempotent. Optimistic retry uses the same operation UUID and payload including observed revisions. Only new intent gets a new operation. Sensitive responses have no shared HTTP caching. Catalog responses mark cache age and stale status.

## Auth and direct operations

| Access | Interface | Contract |
| --- | --- | --- |
| Guest or account | Supabase Auth SDK | Sign up by email/password, verify email, sign in, send recovery email, establish password recovery session, update password and sign out. Use allowlisted redirects/PKCE where applicable and neutral messages. A stable session does not imply completed profile setup. |
| Guest or account | SELECT `titles`, `seasons`, `episodes`, `people`, `title_credits` | Public normalized rows under RLS, limited to expected public columns. Episode listing omits synopsis. Use title/season relationship queries and allowed pagination. Cold catalog hydration goes through `catalog`. |
| Guest or account | SELECT `profiles` by handle or bounded canonical prefix | Minimal identity only, with account lifecycle and block RLS. Short input floor for member search, parameterized prefix matching, stable order `handle, user_id`. Use `profile_page` for expanded fields. |
| Ready owner | UPDATE `profiles.display_name` | Own row only. DB validates length and trims display value. Profile bio, settings, and audience updates go through `profile_update`. |

## Read RPCs

| RPC | Inputs and authorization | Response |
| --- | --- | --- |
| `title_context` | Title UUID and optional season/episode identity, viewer derived from caller. Same public access as catalog. | Normalized detail extras and scoped rating/community info, owner status/history entry point and safe public activity entry points. Episode synopsis available through explicit episode detail/reveal intent in this contract. Hidden titles produce neutral unavailable. |
| `library_page` | Owner handle/UUID, library section, media/status/genre/rating filters as supported, order, cursor and limit. Omitted owner means caller. | Group-aware pages of visible titles with ratings, progress, and next/release summary where permitted. Owner-only watches/dates are absent from visitors' rows. For Watched Shows return separate Continue Watching and Other pages/cursors derived from one progress projection. View mode remains local. |
| `viewing_history` | Movie or show ID, owner only. Cursor for dated, undated or retained entries. | Active viewing entries, watch dates, history IDs and revisions. A show includes retained unavailable watch records. |
| `tracking_snapshot` | Ready owner, title, optional selected season. | Membership, active entries or requested episode slice, scoped revisions including absence values or tombstones, catalog revision, derived status, progress and next episode or release state. |
| `tracking_preview` | Ready owner, show and bulk action identifier with optional season or episode. | Exact counts/range, catalog revision and explicit affected episode IDs/revisions, plus membership observations for start/restore cases. Include a compact shape suitable for local persistence. Snapshot does not authorize a later write by itself. |
| `opinion_page` | Movie/show/season target or profile, allowlisted sort and cursor. | Eligible review summary and ratings independently gated. Conceal flagged review body and incomplete-season review body. Include permitted author display, publication time, rating and action capabilities. |
| `review_detail` | Review ID, reveal intent flag initially false, optional comment cursor. Recheck visibility on every call. | Visible detail, eligibility flags, scoped rating, current likes, and flat thread where allowed. Mask comment spoilers until their specific reveal action. Protect the whole thread while its review requires reveal. Concealed bodies are absent from the payload. |
| `profile_page`, `relationship_page` | Target user, scope for followers/following/request list and cursor when applicable. | Minimal or expanded profile, eligible totals, permitted relationships and controls. Incoming requests owner only. |
| `following_feed` | Ready account, immutable chronological cursor `(created_at,id)`. | Eligible activity variants, current actor/target, current review excerpt only if allowed, and context. Review edits appear in place. No standalone episode events. |
| `inbox_page`, `inbox_item` | Ready recipient, cursor or identifier. | Recomputed eligible notification data and safe target IDs. Inaccessible entries are suppressed or neutralized. Push tap resolves `inbox_item` before routing. |

## Mutation RPCs

Authenticated, verified ready-profile ownership is required unless explicitly stated. Server owns timestamps and resulting state. Inputs are typed and bounded at the DB boundary.

| RPC | Inputs | Effect/result |
| --- | --- | --- |
| `claim_profile` | Verified Auth user without a ready profile, normalized handle | Idempotently initialize identity/settings and report handle conflict without exposing account details. |
| `profile_update` | Allowlisted bio, timezone, market, profile/library visibility and tracking-activity fields | Apply settings. A private transition permanently downgrades previously public audience entries to Followers until explicitly reset. Return updated settings and permissions. |
| `apply_tracking` | Operation UUID, first-submission instant, title UUID, action, action-specific fields and expected revisions | Atomic tracking and receipt. Return IDs, current membership/state and authoritative progress/revisions for the affected scope, plus undo availability. Actions are listed below. |
| `undo_tracking` | Own new operation UUID, first-submission instant, original operation UUID | Replay-safe conditional restore from receipt. Return restored/skipped scope and current projection. 24-hour preimage expiry. |
| `set_rating` | Target, optional half-star units, independent rating audience, observed revision, operation UUID where sharing is requested | Save or clear own rating, optionally emit a deliberate shared rating event at the same time. Return new revision and state. A private score cannot emit a visible rating event. |
| `save_review`, `delete_review` | Target, body, spoiler, audience and draft/publish intent for save, observed revision. Publish/create includes stable client request identity. | Save privately/explicitly publish, edit or retire review without changing rating or viewing. First publication creates exactly one activity entry. Retired discussion ID is never reused. |
| `set_follow`, `resolve_follow_request`, `set_block` | Target user and desired relationship or request resolution | Validate both actors and legal transition. Public follows accepted, private requested. Support cancel, unfollow, decline, remove follower and approve. Block removes both relationships atomically. Recheck eligibility before adding notifications. |
| `set_review_like`, `add_comment`, `edit_comment`, `remove_comment`, `hide_comment` | Review or comment target, desired state/body/spoiler, stable comment UUID for create, observed revision for an edit | Access and block recheck plus single deduped interaction/notification. Write only caller's comment and allow review owner to hide. For protected threads require explicit reveal context. |
| `submit_report` | Authorized typed target, category and optional short explanation | Validate target and dedupe/throttle abuse. Return report ID. Restrict resolution details to permitted reporter outcomes. |
| `set_notification_preferences`, `mark_inbox_read` | Category flags or eligible ID/list and all-read mode | Persist scoped preferences or mark eligible entries read idempotently. All-read uses a server-issued high-water event time/ID to preserve later arrivals. |
| `register_device`, `unregister_device` | Installation ID, FCM registration token/platform to enroll, installation credential to rebind/renew or detach | Bind to caller, store only a verifier/hash of an installation secret and keep raw FCM token private. Return expiry. An older account cannot detach or overwrite a newer binding. If renewal cannot be authorized, re-enroll using a new installation identity/token. |

### Tracking action fields

| Action | Required scope | Rules |
| --- | --- | --- |
| `set_wanted` | Desired membership, Wanted revision | Eligibility atomically checks active viewing or show tracking. Set does not disturb independent opinions. |
| `mark_movie_watched`, `log_rewatch` | New stable viewing UUID, optional viewing day, observed Wanted/membership where affected | First mark requires an unwatched movie and removes Wanted. Rewatch requires an existing title viewing and adds a distinct entry. Validate known upcoming restrictions. |
| `edit_movie_viewing`, `delete_movie_viewing` | Own viewing UUID and revision, optional date for edit | Affect only that record. Last deletion leaves movie untracked. |
| `start_show`, `set_show_intent`, `remove_show_tracking` | Show intent revision and Wanted revision where affected. Intent is Watching/On Hold/Dropped. Removal requires previewed affected scope and confirmation. | Starting may store zero watches. Completed is computed. Explicit resume required from manual stop. Removing tracking clears its episode histories while preserving opinions. |
| `set_episode_watched`, `edit_episode_watch_date` | Episode UUID, observed mark revision, desired watched state or optional date. Include membership/Wanted observations if this operation starts tracking. | Reject unreleased additions. Clear date on unwatch. Prior saved state and optional date remain separate. |
| `apply_show_batch` | Show, action type, optional season/anchor episode, catalog revision and exact proposed affected records/revisions | Support mark through, mark season watched, season unwatch and mark all released episodes of eligible ended show. Revalidate the preview inside the transaction. Preserve the old dates and reject stale/oversized batches atomically. |

Delivery semantics for opinions, comments and relationship mutations follow the same principle. Use desired-state forms where naturally idempotent, stable IDs or durable receipts for one-time creation/publication, and observed revisions for destructive edits. Reconnecting a pending tracking write never creates a new ID. The database receipt horizon and age limit apply to both tracking RPCs.

## Edge Functions

| Function | Authentication and request | Result |
| --- | --- | --- |
| `catalog` | Guest publishable access or verified JWT. Allowlisted operation, locale, market, typed search/detail keys and page. Throttle per actor or trusted request origin and a global budget. | Discover categories, mixed title/people results, hydration, or filmography. No arbitrary endpoint, URL, query string forwarding or raw upstream payload. Titles in cold results provide typed TMDB ID only until hydrated to a stable Taspa ID. Return age and stale markers. |
| `avatar` | Read for authorized profile viewers. Owner-only upload/removal with verified JWT. Bound byte length/dimensions, verify file type, and serve a sanitized image. | Proxy private avatar reads without shared caching. Recheck desired profile and block access. Stage writes to an opaque owner-scoped path, swap the authorized pointer, then clean old objects after commit. |
| `share` | Public HTTPS resolution for typed title or review target. Guest requests are rate limited with the public catalog budget. | Open allowed target in the app, or show a minimal destination/fallback. Recheck public review eligibility on each resolution. Generic review previews contain no text, actor identity or tracking data. |
| `delete-account` | Ready or already-deleting verified owner with fresh re-verification for a new irreversible request. Idempotent delete request identity. | Mark account unavailable, revoke active access and schedule durable cleanup of avatars, tokens, data and Auth account. Return accepted/current state. |
| `maintenance` | Cron-only worker credential stored in Vault and Edge secrets. Allowlisted job names only. Never accept guest or user credentials for this function. | Bounded jobs for catalog refresh, release fan-out, reminders, FCM sending, cleanup and account deletion. Claim leased SQL work, perform external network work outside SQL locks, and complete it transactionally. Return internal job summary without tokens or content. |

Use Supabase-supported JWT/key header modes. Where gateway JWT verification is disabled for guest/internal function calls, explicitly authorize the intended credential in the handler before processing. Cron calls a dedicated secret-backed endpoint through `pg_net`. Use the official FCM HTTP v1 API from maintenance with short-lived OAuth credentials. [Scheduling Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions) · [FCM HTTP v1](https://firebase.google.com/docs/cloud-messaging/send/v1-api)

## Errors and retries

Normalize Supabase SDK errors, RPC SQLSTATE and structured RPC conflicts, Edge HTTP errors, and connectivity failures to one Dart failure model. Do not depend on parsing English database messages. Return an opaque request ID for support. Structured write conflict/expiry results can carry authorized current state. Unexpected details stay server-side.

| Class | Handling |
| --- | --- |
| Invalid/unsupported | Explain field, date, kind or batch limit. Keep editable input. Never retry automatically. |
| Auth/forbidden/unavailable | Refresh expired session once. A guest sees sign-in; a stale permission or inaccessible target resolves neutrally. Discard protected cached responses. |
| Conflict/expired operation | Fetch/reconcile current state and ask the user to reapply affected intent. Preserve unrelated optimistic actions. No silent overwrite. |
| Rate limited/upstream unavailable | Respect Retry-After, serve allowed stale catalog when available, and retry bounded transient calls. |
| Offline/timeout/5xx | Show cached results or blocked action state. Retry reads with jitter and ambiguous eligible tracking writes under the same operation identity. |

Edge errors use HTTP 400 for invalid, 401 for unauthenticated, 403 for a forbidden operation without existence disclosure, 404 for neutral unavailable, 409 for conflict, 429 for budget, and 502/503 for upstream/service failures. Direct queries and RPC keep their native transport semantics and map to the same app classes. Inbox read state and pushes remain independent of the durability of tracking writes.
