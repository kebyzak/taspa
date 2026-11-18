# Taspa implementation plan

**Delivery sequence · 18 November 2026**

Deliver the smallest vertical slice at each milestone, then resolve its integrity and recovery cases before adding features. The approved [product](PRODUCT_SPEC.md), [design direction](DESIGN_DIRECTION.md), [design system](DESIGN_SYSTEM.md) and [brand kit](BRAND_GUIDELINES.md) provide acceptance references. The [technical overview](TECHNICAL_SPEC.md), [schema](DATABASE_SCHEMA.md) and [API](API_SPEC.md) define the implementation interface.

## First make it work

### Implementation progress · 18 November 2026

| Slice | State |
| --- | --- |
| Foundation and catalog | Flutter shell and Splice resources, email Auth, guest browsing, live TMDB search, poster collections, credits, trailers and similar titles are wired. Hosted discovery, show hydration and season hydration returned HTTP 200. Verify Auth email delivery and callbacks, native presentation, and accessibility on a device. |
| Tracking and library | Wanted, movie history and rewatches, show statuses, episode tracking, bulk actions, Undo, Continue Watching, sorting and filters are implemented. Local SQL checks passed for earliest episode gaps, deduplication, Undo, Completed and owner isolation. Encrypted mobile snapshots, drafts and replay are wired. Verify restart and reconnection on-device, especially chained optimistic updates, overlapping edits, and conflict recovery before closing this milestone. |
| Opinions and social | Independent movie, show and season opinions, chronological feed, followed recommendations, profiles, avatars, follow requests, blocking, likes, comments, reports and share resolution are wired. SQL verified spoiler concealment and audience revocation. Hosted title share returned HTTP 302 to the app scheme and the missing-review and missing-avatar routes returned HTTP 404. Native share opening, authenticated avatar upload and the complete account deletion flow still need manual verification. Verified web links remain a launch dependency. |
| Notifications | Android enrollment, category preferences, inbox, release refresh/reminders and push delivery worker are wired. A hosted validate-only request returned HTTP 200 from both the Edge worker and Firebase. SQL verified ownership, worker-only grants and opt-out before delivery. Device delivery, tap routing and release timing remain open. iOS APNs is deferred. |
| Deployment and verification | Hosted Supabase reports 17 applied project migrations and five active scheduled jobs. All five Edge Functions are deployed and pass Deno type checks. The final Flutter static analysis reported two style notices in the review editor and zero errors or warnings. Flutter's test runner found no test directory. Native builds and device acceptance were left for manual review. |

| Order | Deliver | Exit condition |
| --- | --- | --- |
| 0. Foundation | Initialize Flutter and Supabase CLI projects. Pin compatible Flutter/Dart, Supabase CLI and dependency versions. Create environment config, app shell, GoRouter, Cubit and repository composition. Wire the existing Splice icon/launch assets in each native project. Establish schema/grants migrations and synthetic local seed data. | Local Flutter app reaches Discover as guest, uses the local project, and displays the approved launch appearance on Android/iOS checkpoints. Public config diff contains no server keys. |
| 1. Auth, catalog and first movie | Email verification/recovery, handle claim, guest catalog/search, title detail. Build the normalized catalog schema, seed first, then connect the cached TMDB Edge adapter. Add Wanted, first watch, history, rewatch and Undo through the tracking RPC. | A guest opens a movie, signs in, confirms the original action, then marks it watched. Wanted moves atomically, one undated viewing exists, and both Undo and a subsequent rewatch behave correctly. |
| 2. Series and offline library | Stable show hierarchy, catalog release evidence, derived progress, episode quick actions, independent intents, bulk preview/actions, Continue Watching, library filters, SQLite replay and retention. | A tracked show can be resumed and corrected offline. Earlier gaps win, TV status and counts are consistent across screens, and confirms never create duplicate watches. Views survive a season renumbering or returning release. |
| 3. Opinions, people and privacy | Independent movie/show/season opinions, spoiler gates, account profiles, avatar handling, follows, review comments/likes, report/block, chronological feed, scoped public share routes. Add catalog credits and filmographies if not in the initial hydration slice. | People can publish, follow and discuss, while a change in audience immediately affects every authorized projection. Incomplete-season prose and flagged contents stay out of previews and unread thread responses. |
| 4. Inbox, release jobs and push | Notification preferences and inbox, due-catalog refresh, release dedupe and fan-out, worker leases, FCM HTTP v1, device binding/permission flows, account deletion and cleanup. | In-app events work without push. A newly released episode or Wanted reminder creates only the appropriate outcome, and delivered push opens the current authorized view. Account deletion immediately restricts access and can resume cleanup. |
| 5. Launch hardening | Complete secondary screen states and metadata fallbacks, operational documentation, quotas and alerting, manual performance/security checks, and staged native builds. | Product acceptance and the manual release checks below pass. Provider, privacy, release-market and support decisions are resolved. |

Profile favorites and custom collections keep their V1.1 roadmap position. Defer Supabase Realtime until there is a measured latency problem, as well as advanced analytics, recommendation ranking, episode opinions, and external playback integrations. Start one vertical slice with one repository per feature and expand only at a demonstrated boundary.

## Then make it right

### Local work and migrations

1. Use Supabase CLI with Docker to run local Postgres, Auth and Storage. Keep environment-specific public endpoint/key config separate and use a target-specific protected secrets file for Edge Functions. Use local email capture to exercise verification and reset. Use deterministic catalog fixture mode for routine manual development and live TMDB in an explicitly enabled developer or staging environment. Use isolated Firebase projects/configurations for staging and production. [Supabase local workflow](https://supabase.com/docs/guides/local-development/cli-workflows)
2. Use numbered/timestamped SQL migrations under `supabase/migrations/` as the only schema history. Add schemas, role grants, catalog and identity, tracking, opinions/social, and notification maintenance in dependency order. Every exposed relation ships with grants and RLS in its creation migration. Local `supabase db reset` applies from scratch with synthetic seeds. Avoid remote resets. Keep fixture users, mock dates and sample contents out of production. [Supabase database migration workflow](https://supabase.com/docs/guides/local-development/database-migrations)
3. Use additive changes first. For a shape change, add columns or versioned RPC, support both old and new clients, backfill in bounded steps, switch readers, then retire obsolete fields after the supported mobile version window. Record migration order, rollback/roll-forward plan and lock implications. Once applied to a shared project, fix with a new forward migration.
4. Include CLI-pinned local configuration, storage bucket/policies and required database extension setup in versioned project files. Keep Cron activation and Vault secret installation environment-specific. Edge logic and migrations use compatible shapes across deploys. Stub vendor calls via local fixture paths that are disabled in hosted environments.

### Validation without new automated tests

Use manual verification, controlled fixtures, SQL inspection and real client-role calls in local/staging. The user requested static analysis and execution of available automated tests for this verification. The standing preference against writing, adding or modifying automated tests still applies.

| Area | Manual behavior check |
| --- | --- |
| Auth and role boundaries | Exercise guest, unverified, owner, unrelated member, accepted follower, blocked member and worker credentials through supported APIs. Verify users cannot self-approve requests, claim another ID, set service privileges, invoke maintenance or read private tables from PostgREST. Check Auth callback handling and neutral recovery messaging. |
| Movie/auditable Undo | From two clients, double tap a first watch, drop a response then retry the same UUID, add same-day rewatches with separate IDs, edit/delete one viewing, and undo the first move from Wanted with and without an intervening edit. Inspect row counts and preserved primary keys. |
| Series progress and metadata | Start at zero, mark an episode with an earlier gap, mark a season and reverse it, backfill through a previous season, change season ordering, simulate a returning Completed show, and check hold/drop. Validate ratings remain independent. |
| Offline and conflict | Queue eligible updates, restart, reconnect with a second client edit in flight, and check unrelated state and error recovery. Resume with an expired session and after an account switch. Force an expired operation receipt and verify that reapply is explicit and separate. |
| Privacy and spoofing | Use real public/owner/follower/blocked sessions to inspect raw response bodies from profile, feed, reviews, previews, comments, notification taps and avatar. Tighten then reopen profile visibility and ensure capped material needs an explicit audience change. Confirm no protected prose appears without reveal. |
| Release and push | Use fabricated dates including unknown market, timezone boundaries, reschedule, canceled entry, caught-up return, paused show, same-day drop, duplicate Cron run, provider timeout, and revoked token. Check preferences and access at send/tap. Confirm APNs/FCM device behavior before enabling production push. |
| SQL and edge performance | Inspect typical and larger synthetic queries with PostgreSQL plans, including non-owner profile reads, catalog filters, high-follow feed and due delivery claims. Verify scoped indexed access, batch limits, queue recovery, and graceful TMDB 429 handling. |
| UI integrity | Follow product acceptance scenarios and design-system implementation review at compact width and large text. Validate keyboard/assistive navigation, Reduced Motion, undo announcement, and native iOS/Android Splice mask/splash in builds. |

Keep manual release findings with the migration/deploy review. Fix the governing rule once if Flutter, RPCs and projections disagree. Use a separate hosting environment for destructive simulation and restore drills.

## Follow practice

### Deployment sequence

1. Push approved migrations to staging, then deploy compatible Edge Functions. Install server secrets and SMTP settings, verify callback allowlists, deploy policies, and activate staged Cron jobs only after a dry run. Ship a staged mobile build against that project. Confirm release candidates and messages using staging-only credentials and devices.
2. Review staging migrations and plans, reconcile migration history, confirm database backups and restoration path, and ensure compatibility with the already released API clients. Push production schema before clients require it. Deploy compatible functions, set secret/Vault bindings, and enable Cron jobs in dependency order. Supabase CLI project linking is explicit per environment and production seeds are disabled. [Supabase hosted and local commands](https://supabase.com/docs/guides/local-development/local-and-hosted-projects)
3. Verify guest, Auth, tracking, privacy, inbox and provider health in production using a controlled account. Release Flutter separately through normal store channels. Keep new background work independently stoppable. In an incident first disable the relevant job, restore a compatible function, or roll forward safely. Do not drop data to reverse a mobile release.

### Suggested initial job cadence

| Job | Starting cadence and limits |
| --- | --- |
| Catalog refresh and release fan-out | Poll due work every 15 minutes with leases. Prioritize titles with new or imminent releases. Start with 15–30 minute refresh near a known tracked-release window, daily for other active or Wanted titles, and weekly for completed tracked shows. Back off on provider limits. |
| Wanted reminders | Evaluate hourly with per-user local day and reliable configured market/date. Use a reminder window beginning 09:00 local on the previous day. Skip when the window is missed. Suppress rows after rescheduling or membership removal at read and send time. |
| Push delivery | Claim a small due batch every five minutes. Do not let provider calls hold database locks. Fan-out and send are separate, bounded work even when run by the same function. Record queue age and retry backlog. |
| Cleanup and deletion | Poll account deletion/asset finalization frequently while work exists. Run receipt, cache, expired device and log cleanup in bounded daily batches. Use approved retention and purge rules. |

In-app social events are written during the interaction and do not wait on Cron. Notification eligibility is checked again before dispatch. Provider send outcomes are at-least-once under crash ambiguity. Use a stable notification identifier for client dedupe and the provider's safe collapse mechanisms where applicable. Keep OS notification payloads neutral and time-bounded since already delivered push cannot be recalled. Start on the smallest Supabase plan that covers measured workload and agreed backup/restore needs.

### Decisions and launch dependencies

| Decision or dependency | Required before |
| --- | --- |
| Confirm TMDB permitted use of live metadata, cache expiry, image attribution and commercial license if applicable. | Connected public rollout. [TMDB API FAQ](https://developer.themoviedb.org/docs/faq) |
| Set launch locales and supported release markets, release-kind mapping, default behavior when dates or source timezone are uncertain, and user market/timezone setup. | Release notifications and catalog defaults |
| Review a real sample of ongoing, returned, canceled, split and special-heavy series. Confirm coverage signals, stable mappings, practical bulk-operation limit and job budgets. | Series and offline acceptance |
| Provision production SMTP, redirect domains, static link association files, APNs setup and dedicated FCM sender identity. | Auth, sharing and push rollout |
| Agree raw cache/receipt retention, user export/deletion policy, data support and moderator ownership, backup RPO/RTO and launch eligibility. Treat numeric defaults in this spec as operational baselines. | Production readiness |

### Work log

Read the approved product, design and brand documentation and the reference concept notes. Checked primary platform documentation for security, scheduling, messaging and provider terms. Defined tracking and visibility boundaries first, then cross-referenced the schema, API and implementation order. The deliverable is a design handoff. Application code, platform deploys and automated tests are outside this work.
