# Taspa Product Specification

**Status** — Proposed launch baseline · 18 November 2026

**Decision key** — **Confirmed** means explicit in the brief. **Recommended** means a proposed product decision. **Assumption** means a premise to validate. Untagged behavior in a recommended section is part of that proposal. Acceptance criteria test the confirmed requirements and the proposed launch baseline. Roadmap placement is recommended unless the brief specifies it.

## 1. Product vision

**Confirmed.** Taspa is a personal cinematic diary and social platform where people discover, track, rate, review, and share movies and TV shows. Its Kazakh name evokes tape or filmstrip.

**Recommended.** Make Taspa the place people return to after a screening, between episodes, and when deciding what to watch. Give it a cinematic identity through carefully credited imagery, thoughtful editorial selections, and concise writing that leaves room for users' own memories and opinions.

## 2. Value proposition

**Recommended.** Keep a movie diary and a series tracker in the same personal library. Save a film you heard about, log a rewatch without overwriting the first viewing, pick up a series at the right episode, and discover a title through someone whose taste you trust. Each action should be useful from the first day, including for users who follow nobody.

## 3. Target audience

| Audience | Job Taspa should solve | Priority |
| --- | --- | --- |
| People who regularly watch both movies and series | Maintain one record and one queue with the right tracking depth for each medium | Primary |
| Viewers juggling several series, including weekly and returning shows | Find the next episode, catch up quickly, and keep their place through a break | Primary |
| Movie diary keepers and rewatchers | Record dated and undated viewings and revisit their notes and opinions | Primary |
| Friends and small circles with overlapping taste | Find and share recommendations with enough context to act on them | Secondary |

**Assumption.** Mobile is the primary context. Launch geography, catalog coverage, and supported languages remain open. The Kazakh name establishes an identity, with launch localization to be decided separately.

## 4. Product principles

**Confirmed.**

- Keep tracking fast and intuitive. Make ratings, reviews, and watch dates optional.
- Give movies and TV shows equal prominence and let their tracking experiences fit their viewing patterns.
- Make following, discovery, and conversation support the personal diary.
- Favor deliberate presentation and straightforward controls. Avoid engagement mechanics such as streaks, social ranks, and leaderboards.

**Recommended.** Use visible text and accessible control names for tracking states. Support scalable text, screen-reader navigation, and reduced motion. Keep actions usable when artwork is missing. Define premium by the care of the experience. Pricing remains an open product decision.

## 5. Competitive analysis

Public product documentation reviewed 18 November 2026. Strengths below describe documented features. Limitations are assessments against Taspa's intended use case. Interaction speed and ease of use remain hypotheses pending comparative usability sessions.

| Product | Documented strengths | Limitation for Taspa's audience and response |
| --- | --- | --- |
| Must | Brings film and TV into one app, with watched and wanted lists, season and episode tracking, alerts, editorial discovery, and a social feed. | Its pitch starts with movie lists and includes social rank. Taspa should put film history and series progress on equal footing and organize its social feed around recommendations and reviews. Mixed-media coverage alone offers little differentiation. [Must App Store listing](https://apps.apple.com/us/app/must-for-movies-tv/id1071382493) |
| Letterboxd | A film-oriented diary with optional viewing dates, well-established reviews, lists, and following. | The help center describes limited television coverage. Taspa should preserve the ability to record past viewings easily and add first-class season and episode progress. [Letterboxd Help Center](https://letterboxd.com/faq/), [Logging guide](https://support.letterboxd.com/hc/en-us/articles/15178763117967-How-should-I-use-Letterboxd) |
| Serializd | TV-first tracking with next episode, release alerts, and ratings and reviews at show, season, and episode levels. | Its TV focus leaves the mixed movie diary and watchlist use case open. Taspa should make episode completion quick and concentrate launch discussion at show and season level. [Serializd product site](https://www.serializd.com/), [Serializd App Store listing](https://apps.apple.com/us/app/serializd/id1581244120) |
| Trakt | Mixed-media history, watchlists, season and episode progress, calendars, repeat plays, and automatic playback tracking. It distinguishes caught-up and ended series in progress views. | Its breadth introduces more concepts than the launch audience needs to maintain a diary. Taspa should demonstrate that the default path from a title or library row to a saved action is easy to find and complete. Compare directly on backfill, repeat logging, and series resumption. [Trakt product changelog](https://roadmap.trakt.tv/changelog), [Trakt tracking tutorial](https://forums.trakt.tv/t/how-do-i-mark-a-show-or-a-movie-as-watched/107354) |

**Recommended.** Treat the combination of quick film logging, reliable next-episode tracking, and actionable reviews from people users follow as the differentiation hypothesis. Test it on realistic histories and cold-start accounts. Prioritize fixes to those flows before adding personalization or social formats.

## 6. Information architecture

**Confirmed.** The personal library contains exactly three peer sections. **Recommended** sort, filter, and action defaults follow.

| Section | Inclusion | Default and controls |
| --- | --- | --- |
| Watched Movies | Movies with at least one saved viewing, dated or undated | Most recently logged. Sort by last known viewing date, title, or personal rating. Filter by genre or rating. Show one row per title with access to every viewing. Undated-only and unrated entries sort last in their respective sorts. |
| Watched Shows | Tracked shows, including partial, completed, on-hold, and dropped shows | Watching first, ordered by latest personal tracking activity within each group. Filter by status. Offer title and personal rating sorts. Show status, episode and season counts, and next episode or release state. |
| Wanted | Unstarted movies and shows explicitly saved for later | Newest added. Filter by All, Movies, Shows. Sort by date added, title, or release date. Open a title directly and offer the relevant start or watch action. |

**Recommended.** A watched movie can have many viewings. A show has tracked status and episode progress. A season has episode progress and its own opinion. A movie, show, and season each have their own rating and review. Catalog facts, personal tracking, and social publication have independent meanings. A rating or review alone does not put a title into a library section or remove it from Wanted.

## 7. Navigation structure

**Recommended.**

- **Discover** is the initial signed-in destination. Search is one tap away from Discover and Library. Notifications are accessible from Discover, Following, and Profile.
- **Library** opens the last-used of its three sections. First open shows Watched Movies with all three section labels visible. Watched Shows exposes next-episode actions where progress is shown.
- **Following** is the chronological activity feed. The term covers people the user follows, including one-way follows.
- **Profile** opens the user's own profile with editing and settings. Other profiles open from search, followers, reviews, and activity.
- Title, person, season, and review destinations open in context. Back navigation restores the source query, filter, scroll position, or selected season. Shared links use the same destinations and obey current access.

## 8. Core features

### Diary and series tracking

**Confirmed.** Movies support quick watched actions, optional dates, edits, rewatches, ratings, reviews, sorting, and filtering. TV supports show status, total progress and next episode, independent show and season opinions at any stage, season-wide watched and unwatched actions, individual episode tracking with optional dates, and bulk catch-up. Released episodes and returning shows preserve prior progress. See [tracking rules](#12-tracking-rules-and-status-transitions).

### Catalog and discovery

**Confirmed.** Give movies and shows consistent detail experiences with type-specific actions. Search covers titles, actors, directors, creators, and users. Credits link to filmographies that cover both media.

**Recommended.** Launch Discover with balanced Movies and Shows selections for trending, popular, new, and upcoming titles, plus browse by genre. Keep editorial curation small and maintainable. Show one section for recommendations from followed accounts when eligible activity exists. Derive it from eligible reviews and ratings and show a plain reason such as who reviewed the title. Provide a route to Wanted and the detail page, and label release dates as catalog dates for the available market where known. Taste-based ranking and deeper editorial programming follow once catalog and activity supply support them.

### Profile statistics

**Recommended.** MVP shows distinct movies with a saved viewing, distinct shows with at least one watched episode, and distinct watched episodes. An undated viewing contributes to lifetime totals. Movie rewatches increase viewing count in title history while contributing once to the profile's movie count. A show started at zero episodes appears in Watched Shows and contributes to the profile count after the first episode. Show all-time counts with profile visibility rules. Defer viewing time, rating distributions, favorite genre and talent insights, viewing timelines, and monthly and yearly breakdowns. If total viewing time ships, sum known runtimes across recorded viewings, including movie rewatches, and label incomplete coverage. Attribute only dated viewings to time periods.

### Sharing and collections

**Confirmed.** Users can share movies, shows, reviews, and collections as those features become available. Custom collections must support personal and public visibility.

**Recommended.** Ship shareable titles and public reviews at launch. Defer custom collections to V1.1. Wanted already covers intent, and a second list creator adds editing, privacy, sharing, and moderation work. In V1.1, support a named, manually ordered list of movies and shows with optional description, private by default. Users can rename, reorder, remove items, publish, unpublish, share public collections, and delete a list without affecting the titles' tracking state. Curated Discover collections are editorial surfaces with a separate purpose.

## 9. Screen inventory

**Recommended.** Rows identify destinations or modal flows. Variants share the same entry point where practical. Sections 10–16 define their requirements and states.

| Area | MVP screens and surfaces | Later |
| --- | --- | --- |
| Entry and account | Welcome, onboarding introduction, create account, sign in, verification, recovery and reset, handle and profile setup, sign-out confirmation, account deletion | Import setup and import results |
| Discovery | Discover, catalog browse results, genre browse, editorial collection detail when populated, Search and categorized results | Personalized recommendations and expanded editorial browsing |
| Library | Library with three sections, sort and filter sheet, movie viewing history, movie log editor, show status actions | Diary calendar and views across all dated logs |
| Catalog | Movie detail, show detail, season detail with episode list, episode detail or action sheet, cast and crew list, person filmography, trailer surface, similar titles and review lists | Expanded release calendar |
| Opinions | Movie, show, and season rating/review editor, review detail, comments, spoiler reveal, share sheet | Public collection share targets |
| Social | Following feed, own profile, another user's profile, profile editor, followers/following, follow requests, privacy-filtered profile library and reviews, report sheet | Collection browsing and editing, richer profile favorites |
| Notifications and settings | Inbox, notification preferences, privacy settings, blocked accounts, account settings, help/report routes | Release digest and expanded notification controls |
| Shared states | Empty, loading, partial metadata, no results, offline, pending, recoverable error, restricted/deleted content, and undo | Applied to each new surface |

## 10. Screen-level requirements

**Recommended.** Show the action relevant to the current state. Label an episode action **Mark watched** so people can distinguish it from playback.

| Screen or surface | Required content and actions |
| --- | --- |
| Welcome and onboarding | Explain the diary, Wanted, and series progress in a short skippable introduction. Offer catalog browsing; gate personal writes and social actions behind sign-in. Return users to the intended destination after sign-in and ask them to confirm the pending action there. Defer follow suggestions and notification permission until context makes them useful. |
| Account entry and setup | Launch baseline uses email, password, verification, and password recovery. Require a unique handle for an account. Display name, photo, and bio are editable and optional. Allow users to resume verification and handle setup. Use neutral recovery responses, actionable validation, and recoverable errors. |
| Discover and browse | Give both media types comparable space and stable section ordering. Link each list to relevant filters. Make title, media type, and release year or release state visible without a poster. Provide genre browse and contextual routes to Search, title details, and Wanted actions. |
| Search and filmography | Search by display title, original title, and known aliases. Group mixed results by Movies, Shows, People, and Users with category views. Disambiguate titles by year and type, people by role or known credit, users by handle. Person pages list available credits by role and media with a year sort. Keep blocked and private-profile visibility rules on results. |
| Watched Movies and movie history | Provide sort and filter controls, movie rating, and last known viewing where available. Title history lists dated watchings by viewing date and undated watchings under Date unknown. Support adding a rewatch and editing or deleting a specific viewing. |
| Watched Shows and Wanted | Apply section controls in §6. Show quick next-episode completion for Watching titles with a released next episode. Show the next known release for caught-up shows. In Wanted, allow add/remove via title actions and movie watch or show start from the list with undo. |
| Movie detail | Use poster, backdrop, title, original title when different, release date or year, genres, runtime, synopsis, director and key credits. Prioritize Mark watched, Log rewatch when watched, and Add to Wanted when eligible. Show personal rating/history, community rating and count, reviews, friends' eligible activity, trailers, and similar titles where available. |
| Show detail | Share the catalog and social fields with movie detail. Use creator credits, first release, release status, and typical episode runtime where available. Prioritize Start watching, Resume watching, or a next-episode action according to state. Show status, watched and released episode counts, completed seasons, and seasons in order. Distinguish the catalog's release state from the viewer's status. |
| Season and episode | Season shows ordinal or name, release information, episode progress, independent rating/review, reviews, and whole-season actions. Episode rows show number, title, release state, watched state, and quick completion. Expand for runtime, synopsis, date editing, unwatch, or catch-up. Hide episode synopses by default for unwatched episodes as a spoiler precaution. |
| Rating/review editor and review detail | Show the title and explicit target, especially for season opinions. Offer independent rating and review edits, optional spoiler marking, and an audience choice before publication. Review detail supports reveal, like, comment, share where eligible, edit/delete for owners, and report for other viewers. |
| Following and profile | Following shows eligible recent activity and a title or review link. An empty feed points to user search and title reviews. Profiles show display name or handle, photo or fallback, bio, permitted stats, followers/following, and links to visible Watched Movies, Watched Shows, Wanted, and reviews. Include owner edit and viewer follow, unfollow, request, cancel, block, and report actions as applicable. |
| Notifications | Separate unread and read through accessible labels, support mark all read, and open the referenced content or a safe fallback. Provide meaningful categories and preferences with the defaults in §14. |
| Settings | Provide profile/account management, privacy and review audience defaults, notification controls, follow request management, blocked accounts, help, sign-out, and a clearly confirmed deletion flow. Explain the visible effects before applying privacy changes or deletion. |

## 11. Primary user journeys

**Recommended.** Tap counts below start from the named screen. Navigation and optional edits are outside the quick-action counts.

| Journey | Completion path |
| --- | --- |
| First visit | Browse a movie or show as a guest. Tap tracking, create or sign into an account, return to the title, and confirm. The personal library reflects the saved result. |
| Save something for later | On an eligible title tap Add to Wanted once. It appears under the correct media filter. Remove or undo from the title or Wanted. |
| Log a movie now | On the detail or Wanted row tap Mark watched once. Save an undated viewing and offer Undo and Edit date. Open the detailed log editor when a date is part of the intended action. |
| Backfill and rewatch | Use Mark watched for an old movie with unknown date. Add a known date when desired. Log rewatch opens an editor and explicit Save adds another viewing. History shows both. |
| Start or resume a series | Tap Start watching to move it from Wanted to Watched Shows at zero episodes. For On Hold or Dropped, resume explicitly. Tap Mark watched on a released next episode in Watched Shows or on the show detail to update progress in one action. |
| Catch up after time away | Select an episode or season, preview which released episodes will change, and confirm. Preserve earlier watch dates and show the next unwatched episode or release state. Offer Undo for the whole change. |
| Review a season mid-watch | Open the season, choose Rate or Review, and save a rating, text, or both. Choose audience and mark spoilers if relevant. The season opinion saves independently of show opinion and progress. |
| Discover through a person | Open a friend's eligible review, reveal spoiler text only if desired, open the title, and add it to Wanted. Alternatively open a credited person and browse their movie and TV credits. |
| Manage release alerts | Open a release notification to the show, episode, or movie. Manage the category from its notification settings. Unavailable, deleted, or newly restricted targets resolve safely. |

## 12. Tracking rules and status transitions

### Movies and Wanted

**Confirmed.** A movie leaves Wanted when marked watched. A show leaves Wanted when the user starts watching. Dates and opinions are optional.

**Recommended.**

| Before | Action | Result |
| --- | --- | --- |
| Untracked movie or show | Add to Wanted | One Wanted entry. Repeated requests leave one entry. Upcoming titles may be saved. |
| Wanted | Remove from Wanted | Untracked for library purposes. Existing opinions remain available through title and profile reviews as permitted. |
| Untracked or Wanted movie | Mark watched or save first viewing | Watched. Create one viewing and remove Wanted together if present. Mark watched defaults to Date unknown. |
| Watched movie | Save Log rewatch | Add a distinct viewing. Same-day rewatches are allowed. Repeating the same save through retry or double-tap creates one viewing. |
| Watched movie | Edit or delete a viewing | Edit the chosen viewing only. With any viewing remaining the movie stays Watched. Deleting the last returns it to untracked. Restore prior Wanted only through undo of the originating move or by adding it again. |
| Untracked or Wanted show | Start watching, save a watched episode, or confirm a watched batch | Track as Watching, or Completed if its completion conditions are met. Remove Wanted in the same change. Starting alone records zero episodes and is available once a regular episode is released. |

Wanted is for unstarted titles. A settled Watched movie or tracked show offers history, rewatch where supported, or show status actions. Users can remove a show from tracking through a separate confirmation that describes removal of its episode progress and dates. Show and season opinions survive. The title then becomes eligible for Wanted.

### Series status

**Confirmed.** Supported statuses are Watching, Completed, On Hold, and Dropped. Seasons and episodes remain independently trackable.

**Recommended.** Treat Watching, On Hold, and Dropped as user intent and Completed as earned by satisfying the rule below. **Caught up** is a progress label for a Watching show with all released regular episodes watched while further episodes are possible or the catalog status is unknown. It never creates a fifth status. A show can be Completed only when it is confirmed ended or canceled, has at least one regular episode, has no known future regular episodes, and every released regular episode is watched. If catalog coverage is visibly incomplete, label it and withhold automatic completion until enough is known. Provide a confirmed **Mark all released episodes watched** action for backfilling an ended series.

| Before | Event | Result |
| --- | --- | --- |
| Watching or On Hold | Drop | Dropped. Preserve every episode and date. Remove from the default next-up queue. |
| Watching or Dropped | Put on hold | On Hold. Preserve every episode and date. Remove from the default next-up queue. |
| On Hold or Dropped | Resume | Watching or Completed according to current progress. A single episode edit leaves the manual status in place. |
| Watching | Completes progress or catalog confirms the series ended | Completed if the full rule is satisfied, otherwise Watching. Show Caught up when eligible. |
| Completed | Unwatch a required episode, or catalog reopens the series or adds a missing released episode | Watching with updated progress and next item. Preserve all prior watched episode records other than the explicitly unwatched one. |
| Any tracked status | New season announced, episode rescheduled, or catalog refreshed | Recalculate from the latest reliable catalog. Keep On Hold and Dropped until explicit resume. Unreleased episodes stay out of progress totals. Display known upcoming release separately. |
| Watching with zero watched episodes | Undo Start watching or remove tracking | Undo restores the prior state, including Wanted if applicable. Explicit removal returns to untracked. Unwatching the sole episode leaves a started show tracked at zero. |

### Episode, season, and progress semantics

**Recommended.**

- Quick completion marks one released episode watched with Date unknown. Episode detail supports setting, editing, and clearing the watch date. Unwatching clears that episode's saved completion and associated date, with Undo. Episode rewatches are deferred.
- Next episode is the earliest released unwatched regular episode in season and episode order. An earlier gap stays next even after a later episode is watched. When no released episode is pending, show the earliest known upcoming regular release, or a neutral message when none is known.
- Season progress counts watched regular episodes against released regular episodes. Show progress sums the same counts across seasons. Show completed seasons separately from seasons with any progress. Count a season as complete when there is at least one released regular episode, all released regular episodes are watched, and the catalog indicates the season's release is finished. Otherwise use Caught up or progress counts as appropriate. Upcoming seasons stay outside completed/released-season totals until their first episode releases. Specials can be individually tracked, with their own progress display. Exclude specials from regular next-up, bulk catch-up, completion, and regular totals.
- **Mark through this episode** includes the selected episode and all earlier released regular episodes across seasons. **Mark season watched** fills released gaps in the selected regular season only. **Mark all released episodes watched** fills them across every regular season of an ended show. Show the affected range and count before confirmation. Existing watched dates survive, and new entries default to unknown. **Mark season unwatched** previews and clears every saved watch and date in that regular season, including logs preserved after a release-date correction. A batch can only add watches for released episodes. For a currently releasing season use **Mark released episodes watched**.
- Store the user's chosen calendar day for dated logs. Accept past dates through today in the user's local time. Untouched or cleared dates remain unknown. Metadata corrections may change release labels, order, or totals. They must preserve prior viewing history and make unavailable entries discoverable in history where the original episode can no longer be shown.
- Undo reverses the affected entries and restores a prior Wanted membership or status where applicable. If a later edit has touched an entry, preserve that later edit and report any part Undo could not restore. Once the undo prompt expires, expose normal history or episode editing. Confirm bulk unwatches and removal of show tracking before applying them.

## 13. Rating and review logic

**Confirmed.** Ratings and reviews are optional. Show and season ratings are independent, including before completion. Episode ratings and reviews are outside MVP.

**Recommended.**

- Use a 0.5–10 scale in half-point steps, shown as a score out of 10 on five stars (two points per star): 3½★ reads as 7. A blank rating means unrated. Show, season, and movie ratings can be set, changed, or cleared with or without review text.
- Maintain one editable personal rating and one editable review per movie, show, or season. Movie viewing history is separate. A rewatch leaves the current opinion intact unless the user edits it. Deleting review text leaves the rating intact. Changing a rating creates no new review or viewing.
- Save a review privately or explicitly publish to an allowed audience. Rating and review audiences are set independently. Let users preview the selected audience, spoiler status, and target before publication. Profile and title pages show the latest eligible version. Include the author's rating next to a review only if the reader can also see the rating. Editing a review updates its existing feed item and conversation without creating a duplicate.
- Show Taspa community rating and eligible rating count independently for movies, shows, and seasons. Aggregate only Public ratings from public profiles, one per member per target. Suppress the average below five eligible ratings and use an insufficient-ratings state. Private and Followers ratings remain personal or audience-scoped on permitted surfaces.
- Spoiler tags apply to movie, show, and season reviews. Conceal flagged text and associated comment thread behind an explicit reveal on all in-app surfaces. Notifications, search, shares, and external previews never include flagged snippets. Hide season review text for a season the viewer has not completed until they choose to reveal it, even if the author left it unflagged. Keep the rating and season label visible when permitted.

## 14. Social interaction and notification rules

**Recommended.**

- Following is one-way. A public profile can be followed immediately. A private profile requires approval. Users can unfollow, cancel or decline requests, and remove followers. Blocking ends follows and requests in both directions and prevents renewed follows and interactions while active.
- The feed is chronological. Eligible events include published reviews, deliberately shared ratings, and first movie or show milestones if the owner enables tracking activity. Bulk edits can produce at most one milestone. Exclude individual episode completions, backfills made with tracking activity disabled, Wanted removals, and routine edits. Feed and title-level friends' activity respect the same current visibility. Avoid an implied friendship label for a one-way follow.
- Likes toggle once per member on visible published reviews. Show total count. Use a flat comment thread with editable/deletable own comments and the ability to report comments, reviews, and profiles. Review owners may hide comments from their thread. Keep comment text inside the thread and let commenters flag spoilers. Moderation can remove reported content and show an outcome to the reporter where appropriate.
- Share movie/show links with public catalog information. Share review links when publicly visible. For any previously shared material, check current visibility when opened. Apply equivalent rules to collection links in V1.1.

| Event | Launch behavior | Default |
| --- | --- | --- |
| New follower, follow request, request accepted | In-app entry with a route to the account or request. Deduplicate repeated actions. | In-app on. Push off. |
| Like or comment on the user's review | Group likes by review. Comments link to the thread and conceal text in notifications. Suppress self-events and interactions removed before delivery. | In-app on. Push off. |
| New episode of a tracked show | Notify on confirmed release for Watching, including caught-up ongoing shows. For a returning Completed show, evaluate the transition to Watching before eligibility. Group same-day drops by show. | In-app on for Watching. Push opt-in. |
| Upcoming Wanted release | In-app reminder on the day before a reliable local release date, for titles still in Wanted. Check the title and current release date before surfacing. Skip reminders with unknown market/date or a date learned after the reminder window. | In-app on. Push opt-in. |

Allow category-level controls. Suppress repeat notifications for the same release, remove or neutralize entries that no longer authorize access, and keep release and account notification content concise. Defer digests and configurable lead times.

## 15. Privacy requirements

**Confirmed.** Access to other users' library, progress, ratings, reviews, and Wanted is subject to privacy preferences.

**Recommended.**

| Control | Default and effect |
| --- | --- |
| Profile visibility | Public identity consists of handle, display name, avatar, and bio. Private profiles expose only enough identity to recognize the account and request a follow. Email and account details remain owner-only. |
| Library audience | Only me by default. Choose Only me, Followers, or Public. Applies to the three library sections, status/progress summaries, personal statistics, and eligible tracking activity. Individual viewing dates remain owner-only in MVP. |
| Opinion audience | Only me by default. Set per movie, show, or season rating and review, with explicit choice for broader visibility. Spoiler protection is independent of audience. A public opinion may exist alongside a private library without exposing its dates or progress. |
| Sharing and activity | Tracking activity starts off. Opt-in enables eligible events up to the library audience. Sharing an opinion uses its own current audience. Before publishing, show who can see it. |
| Blocking and follow requests | Blocked accounts cannot see each other's profiles, posts, or comments while signed in. A private profile requires approval for Followers content. Switching to private keeps existing followers, with an explicit summary and ability to remove them. |

Private profile mode caps all audiences at approved followers, including previously public material. Tightening visibility updates profile counts, libraries, review views, feeds, ratings aggregates, search, notifications, and direct-link access. Material previously public stays capped if the owner later makes the profile public again, until the owner explicitly reopens its audience. Prevent guests and link-preview services from receiving private content. For inaccessible targets use neutral messaging that does not reveal hidden progress, text, or relationship data.

Provide private settings and confirmation for account deletion. On confirmed deletion remove the profile and personal collection from user-facing surfaces, remove the user's reviews and comments, and update aggregate counts and relationships. Retention terms and export requirements need a launch decision.

## 16. Edge cases and recovery

**Recommended.**

| Situation | Expected behavior |
| --- | --- |
| Empty library, feed, or reviews | Explain the empty state in one short line and provide a relevant action such as Search titles or Find people. An empty filtered result offers Clear filters. |
| Loading, refresh, or request failure | Keep stable navigation and last saved content during refresh. Make partial loading local to the section. Provide Retry for failure. Distinguish a failed load from confirmed zero results. |
| Offline | Allow available saved catalog and library content to open with an offline indication. Queue explicit tracking changes when their target and affected entries are known, show Pending, retain pending changes through restart, and resolve on reconnection without duplicate viewings. Retain review drafts and require connectivity for publication, social actions, and account changes. If needed metadata is unavailable for a bulk operation, explain why it cannot run and preserve existing progress. |
| Failed or competing edit | Reconcile cross-device edits using the most recent confirmed explicit change to the affected item or opinion field. If a queued edit conflicts with a newer confirmed edit to the same item, show the saved state and let the user reapply their intent. A failed move or batch restores the prior affected library state and offers retry or edit. |
| Incomplete or removed metadata | Use readable fallbacks. Omit unavailable images, runtime, credits, or trailers and show Unknown for missing dates or release states where needed. Keep existing logs reachable and avoid presenting uncertain availability as a release. A title with unknown release can be backfilled if no future date is known. An explicitly upcoming title remains Wanted-eligible only. |
| Ongoing season, hiatus, or returning show | Show counts for released episodes and the next scheduled release separately. A new episode increases the released denominator and becomes next if it is first in order. Existing dates and ratings survive, including on paused or dropped shows. |
| Spoiler, removed review, or changed access | Require reveal for hidden prose. Deleted or restricted targets open to neutral state, with a route back. Suppress sensitive preview text and restrict disclosure on shares and follower views. |
| Unknown viewing date and repeat viewing | Preserve undated records, allow the same movie on the same day in deliberate separate entries, and keep unspecified dates out of date-based filters and statistics. |

## 17. MVP scope and launch bar

**Recommended.** Launch should satisfy three everyday needs on day one: record a movie, continue a show, and choose something to watch using catalog and social context.

| Launch slice | Required launch scope | Rationale |
| --- | --- | --- |
| Personal library | Three fixed sections, movie history with rewatches, show/season/episode tracking, Wanted transitions, sort/filter, optional dates and opinions, undo, and offline tracking recovery | Highest repeat value. Progress and history integrity are launch gates. |
| Catalog and discovery | Movie/show/season details, credits and filmography, trailers where available, similar titles, browsable catalog sections, and search across titles/people/users | Makes tracking findable and provides value before the social graph forms. |
| Social and identity | Follow and approve, chronological feed, public and restricted profiles, reviews and spoiler handling, likes and comments, title/review shares, basic stats, blocking and reporting | Delivers the social promise with a small set of formats and controls. |
| Onboarding and notifications | Guest browsing, account lifecycle, optional intro, in-app inbox, opt-in release push, notification categories, and privacy controls | Lets users start quickly and receive updates they choose. |

Launch review should verify catalog coverage, accessibility, failed-action recovery, privacy enforcement, and operational ownership for reports and catalog corrections. Evaluate first-session tracking success, time to complete a quick log, ability to find the correct next episode, and follow-to-discovery actions in usability sessions. Establish quantitative targets after baseline sessions and before release readiness review.

## 18. Roadmap

**Recommended.**

| Phase | Priorities | Decision basis |
| --- | --- | --- |
| MVP | Deliver the slices in §17 and meet the acceptance criteria in §19. Provide lightweight editorial collections when curation is available. | Complete diary and TV loop with usable sharing and strong trust controls. |
| V1.1 | Custom mixed-media collections with private/public visibility, profile favorites for movies and shows, date-based diary browsing, basic data export and import evaluation, richer editorial collections, and improved recommendations based on people followed. Add calendar or release digest if upcoming-episode users need more than the inbox. | Build on existing catalog and social behavior. Validate repeat use, demand for collections, and report volume before widening public content. Bring export forward if required for launch. |
| Future | Explainable taste-based discovery, viewing-time estimates, rating distributions, favorite genres and talent, monthly/yearly summaries, episode rewatches, and episode opinions only if demand and spoiler/moderation capacity justify them. Evaluate playback integrations separately. | These features depend on adequate activity, reliable dates and runtimes, or substantial policy and complexity tradeoffs. |

## 19. Acceptance criteria

These are product acceptance scenarios for design review and manual validation.

| ID | Scenario | Pass condition |
| --- | --- | --- |
| A01 | Guest searches for an original movie title, a show, a credited creator, and a user, then requests a personal action | Results disambiguate by type. Person credits open a mixed filmography. After sign-in the guest returns to the action context and can confirm. |
| A02 | User marks a Wanted movie watched in one tap, chooses Undo, then logs it again | First mark adds one undated viewing and removes Wanted. Undo restores the prior state. Repeating the action after undo saves one viewing. |
| A03 | User adds a dated rewatch and an intentional second watch that day, then deletes one | History lists the two distinct dated viewings and original undated one. Deleting one preserves the others and the title still appears once in Watched Movies. |
| A04 | User starts a Wanted show at zero episodes, then taps its first released episode | Show moves to Watched Shows immediately. The episode action updates the count and next episode in one tap. A retry leaves one watched episode. |
| A05 | User picks Mark through S2E3 after watching S1E1 with a known date | Preview counts missing released episodes through S2E3. Confirmation fills qualifying gaps, preserves the date, skips unreleased episodes and specials, and supports one undo of the batch. |
| A06 | User marks a season watched and then unwatched | Confirmation fills released gaps in the selected season. The subsequent unwatch clears only that season's saved watches. Show totals and next-up recalculate. Undo restores affected episode dates. Show and season opinions persist. |
| A07 | Viewer rates an unfinished season and independently reviews the show | Both edits save with zero required watches or dates. Changing the season rating leaves the show rating and progress untouched. |
| A08 | Viewer catches up on an ongoing show, pauses it, and an episode releases | Watching initially displays Caught up. On Hold survives release with prior progress. Resume exposes the new next episode. |
| A09 | Completed series returns | The show becomes Watching. Previous dates and progress stay visible. An announced but unreleased episode never counts as watched or as a released gap. |
| A10 | A review contains spoilers and comments, and a viewer opens it from a profile, feed, share, or notification | The reader explicitly reveals the text and thread in context. No spoiler excerpt appears in the preview or notification. |
| A11 | Public review or library becomes restricted while another viewer has an old link | Discovery surfaces, aggregates, previews, and directly opened links respect the new audience. A blocked account cannot interact. |
| A12 | User logs a viewing offline, closes Taspa, and reconnects | The pending state survives restart. Sync creates one viewing, applies the Wanted transition, and shows either confirmed success or a recoverable error while retaining the user's input. |
| A13 | A Wanted title has a reliable upcoming date, then is removed or rescheduled | The reminder uses the current date and membership. No stale reminder is delivered. If a previously delivered entry has an unavailable target, it opens a safe fallback. |
| A14 | Catalog entries are missing artwork, trailer, dates, or episode data | Titles remain readable and usable where metadata allows. Existing history is accessible. Actions requiring unavailable episode data explain the limitation. |
| A15 | User navigates with a screen reader and enlarged text | Tracking controls announce the action and current state. Spoiler reveal and undo are accessible, and primary actions remain reachable. |
| A16 | User filters Wanted by Movies and sorts, then switches to Shows and opens a detail | Each filter contains only eligible titles. Sort order is consistent and returning from detail restores the section's active filter and position. |
| A17 | Two viewers like or comment, then one is blocked or their comment is removed | Count and thread reflect eligible activity. Notifications respect current access and expose no removed text. |

## 20. Open decisions and assumptions

| Decision | Recommended baseline or assumption | Resolve by |
| --- | --- | --- |
| Launch market, languages, and regional dates | Validate the first audience and languages alongside localized title coverage. Distinguish global and localized dates when the market is known. | Before catalog and onboarding design sign-off |
| Catalog inclusion and correction policy | Validate season release state, incomplete episode lists, split seasons, specials, conflicting release dates, title aliases, and missing titles on a cross-market sample. Decide who handles metadata reports. | Before locking the tracking experience |
| Meaning of Completed | Use ended or canceled with all regular episodes watched and sufficient metadata. Validate whether the Caught up label meets expectations for people who finish a released season of a returning show. | Before tracking flow sign-off |
| Dates on quick logs | Default to Date unknown and surface Edit date after saving. Compare with an explicitly labeled Today action in usability sessions for backfill and diary use. | Before finalizing logging controls |
| Rating and review granularity | Start with a 1–10 scale and one current opinion per title or season. Validate demand for viewing-specific reviews and alternate scale conventions. | Before opinion editor sign-off |
| Public profile and sign-in | Use guest catalog access, minimal public identity, private tracking and opinions by default, and simple email sign-in. Review age eligibility, identity expectations, and privacy controls for launch markets. | Before account and privacy sign-off |
| Moderation, deletion, and portability | Assign response ownership and define user-facing reporting outcomes, retention and removal terms, and launch export requirements. | Before launch readiness |
| Premium positioning and monetization | Treat premium as a quality target. Test willingness to pay separately from the MVP tracking loop. | Before pricing or entitlement decisions |
| Collection timing and release alerts | Validate whether users need mixed-media lists at launch and whether reliable regional release data supports the proposed Wanted reminders. | At first roadmap and launch readiness reviews |

**Assumptions to test first.** Mixed-media viewers prefer a single diary when it preserves TV depth. An undated quick log is useful for backfill and everyday viewing. Friends' activity becomes useful with a small following graph. Progress survives real-world metadata changes across the intended launch catalog.
