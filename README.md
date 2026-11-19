# Taspa

A movie and TV diary. Track shows episode by episode, keep a Want list, log what you watched, rate with up to 5 stars in half-star steps, write reviews, follow friends, and bring your whole library over from Must.

Built with Flutter on top of Supabase (Postgres, Auth, Storage, Edge Functions) with TMDB as the catalog source.

## Features

- **Discover**: a personal *For you* shelf, trending and upcoming shelves, genres, and people.
- **Library**
  - **Shows**: series you are catching up on, each with a one-tap check that logs the next episode. Progress is shown as watched/released across all aired seasons.
  - **Want**: shows saved for later, listed under the shows you are tracking.
  - **Up to date**: finished shows, listed last.
  - **Movies**: your Want list of films.
- **Add**: the center button opens search with quick *Want*, *Mark watched* and *Start watching* actions.
- **Feed**: every log of yours and of the people you follow, grouped by day. One person's episodes of one show on the same day collapse into a single item.
- **Title pages**: IMDb rating (via OMDb, falling back to the TMDB score), your rating and review, cast, trailer, seasons and episodes.
- **Profile**: Want, Series and Watched counts with lists that load as you scroll, followers and following.
- **Import from Must**: Want, watched movies, show progress, ratings and reviews from a public Must profile. The import runs on the server, keeps going after the app is closed, and sends a notification when it finishes.
- **Notifications**: inbox and FCM push for new episodes, Want releases, follows, likes and comments.
- **Offline**: an encrypted local store keeps the library readable and queues tracking changes until the device is back online.

## Tech stack

| Layer | Choice |
|---|---|
| App | Flutter, `flutter_bloc`, `go_router`, `sqflite` (encrypted offline store) |
| Backend | Supabase: Postgres with RLS, Auth, Storage, Edge Functions (Deno/TypeScript) |
| Scheduling | `pg_cron` + `pg_net`, with secrets in Supabase Vault |
| Catalog | TMDB, cached in Postgres; IMDb ratings via OMDb |
| Push | Firebase Cloud Messaging |
| Icons | Phosphor, bundled as fonts (`lib/app/phosphor.dart`) |

## Project structure

```
lib/
  app/                 router, theme and design tokens, icons
  core/                config, offline store
  features/
    auth/              sign-in and account
    catalog/           Discover, search, title pages, seasons
    library/           Library tab and tracking
    notifications/     inbox and push
    social/            Feed, profiles, reviews, Must import
supabase/
  migrations/          database schema (single baseline + later changes)
  functions/
    _shared/           backend helpers and the catalog core
    catalog/           TMDB gateway with a shared cache
    must-import/       Must import (start, step, background worker)
    maintenance/       push delivery, catalog refresh, account deletions
    avatar/            profile photo upload
    delete-account/    account deletion request
    share/             public share links
```

The product and design documents (`PRODUCT_SPEC.md`, `DESIGN_SYSTEM.md`, `DESIGN_DIRECTION.md`, `DATABASE_SCHEMA.md`, `API_SPEC.md`, `TECHNICAL_SPEC.md`) describe the intended behavior in detail.

## Running the app

Requirements: Flutter (Dart SDK 3.13 or newer) and an Android device or emulator.

1. Copy `.env.example` to `.env` and fill in your project's values:

   ```
   SUPABASE_URL=https://<project-ref>.supabase.co
   SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
   ```

   Only the publishable key belongs here. Server credentials live in Edge Function secrets. `.env` is git-ignored.

2. Run with the settings passed in at compile time:

   ```
   flutter run --dart-define-from-file=.env
   ```

   In Android Studio, add `--dart-define-from-file=.env` to the run configuration's **Additional run args**.

## Setting up the backend

### 1. Database

On an empty Supabase project, open the SQL Editor and run `supabase/migrations/20261119000000_baseline.sql`. It creates the schemas, tables, functions, policies, the avatar bucket and the cron jobs.

Put later schema changes in new migration files named after the baseline (`YYYYMMDDHHMMSS_description.sql`).

### 2. Secrets

Edge Function secrets (Dashboard → Edge Functions → Secrets):

| Name | Used for |
|---|---|
| `TMDB_READ_ACCESS_TOKEN` | Catalog and Must matching |
| `OMDB_API_KEY` | IMDb ratings. Optional: without it, the app shows the TMDB score |
| `TASPA_WORKER_KEY` | Shared secret for calls from `pg_cron` |
| `FCM_SERVICE_ACCOUNT_JSON` | Push delivery |

Vault secrets (SQL Editor), used by the cron jobs to reach the functions:

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'taspa_project_url');
select vault.create_secret('<same value as TASPA_WORKER_KEY>', 'taspa_worker_key');
```

### 3. Edge Functions

```
npx supabase login
npx supabase functions deploy catalog --project-ref <project-ref> --use-api
npx supabase functions deploy must-import --project-ref <project-ref> --use-api
npx supabase functions deploy maintenance --project-ref <project-ref> --use-api
npx supabase functions deploy avatar --project-ref <project-ref> --use-api
npx supabase functions deploy delete-account --project-ref <project-ref> --use-api
npx supabase functions deploy share --project-ref <project-ref> --use-api
```

`--use-api` builds the function on Supabase's side, so Docker is not needed. `catalog` and `must-import` share `_shared/catalog_core.ts`; redeploy both after changing it.

### Scheduled jobs

| Job | Schedule | What it does |
|---|---|---|
| `taspa-push-outbox` | every 5 min | Sends pending push notifications |
| `taspa-catalog-refresh` | every 15 min | Refreshes titles and airing seasons that someone tracks or wants |
| `taspa-release-notices` | hourly | Creates new-episode and Want release notifications |
| `taspa-account-cleanup` | every 5 min | Finishes requested account deletions |
| `taspa-prune-tracking-receipts` | hourly | Trims old undo receipts |
| `taspa-must-import` | every minute | Advances running Must imports; skipped when none are running |

## Import from Must

Must has no public API. `must-import` uses the same endpoints as Must's website, so the import needs the Must profile to be public. If Must changes those endpoints, only `supabase/functions/must-import/index.ts` needs updating.

- **Start**: reads the profile once and stores every title as an import item.
- **Match**: each step matches items to TMDB by title and year. Matches are cached in `private.must_titles` and shared by all users, and titles already in the catalog are not fetched again.
- **Write**: writes through `api.import_apply`. Existing Taspa data is never overwritten, so running the import again is safe.
- **Background**: steps run while the import page is open and once a minute from cron otherwise.

Known limits:

- Must stores only how many episodes of a show were watched, so episodes are marked in order from S1E1.
- Must has no watch dates. Imported logs use the date the title was last changed in Must.
- Must OVAs and specials that exist on TMDB only as season-0 episodes cannot be matched. They are listed as *Not found* and can be added from search.

## Building a release

```
flutter build apk --release --dart-define-from-file=.env
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. Configure your own signing key in `android/app/build.gradle.kts` before publishing. Keystores and `key.properties` are git-ignored.

## Credits

- Movie and TV data from [TMDB](https://www.themoviedb.org/). This product uses the TMDB API but is not endorsed or certified by TMDB.
- IMDb ratings via [OMDb API](https://www.omdbapi.com/).
- Icons: [Phosphor Icons](https://phosphoricons.com/), MIT license (`assets/fonts/Phosphor-LICENSE.txt`).
