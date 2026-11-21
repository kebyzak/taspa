# Taspa design direction

**Final visual foundation · Cinematic Editorial · Dark**

Taspa is a cinematic diary with the immediacy of a native mobile app. Film artwork sets the atmosphere. Tracking, discovery, and conversation determine what appears first and where actions live. Dark graphite, warm ivory, restrained fired coral, and selective editorial serif typography carry the approved identity across screens.

[PRODUCT_SPEC.md](PRODUCT_SPEC.md) governs product behavior and release scope. This document defines the approved screen requirements. [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) defines the shared tokens, components, states, and interaction contracts for implementation. Earlier concept boards are historical references. Use these documents for current layout and behavior.

## Visual foundation

- **Let the art set the tone.** Use vivid, rights-cleared posters at their original proportions and carefully framed stills. Reserve full-width artwork for detail pages. In Discover, smaller editorial crops give horizontal poster collections room to appear early.
- **Use serif for signature content.** Gloock belongs on cinematic detail titles, the occasional featured title, and a profile's display name. Noto Sans handles navigation, section headings, metadata, reviews, numbers, and actions.
- **Group by spacing.** Keep interfaces mostly flat on graphite. Use slightly raised opaque surfaces for sheets, the tab bar, and primary action docks. Reserve hairlines for boundaries that aid orientation. Use consistent 8, 12, 16 and 24 pt corners.
- **Use coral to signal an action or state.** Fired coral `#DB806F` marks a primary action, selected indicator, progress fill, or liked heart. Supporting controls use ivory and neutral surfaces. Every important state has a label, glyph, or shape independent of color.
- **Design for one-handed use.** Keep high-frequency tracking actions in the lower reach zone or beside the relevant title. Prefer system navigation and sheets. Keep text and essential controls on solid surfaces. Full-bleed imagery, clean cuts, and typographic hierarchy provide depth.

## Navigation

Four tabs with a center Add button: **Discover** (opens first), **Library**, **Add**, **Feed**, **Profile**.

**Discover** starts with search, then a **For you** shelf built from similar titles to what you watched, each poster captioned "Because you watched …", then activity from people you follow and the catalog shelves. Catalog responses are reused from the device for up to 2 hours (search 30 minutes, details 6 hours) to keep Edge Function calls low.

**Library** has **Shows** and **Movies** chips. Shows lists Continue Watching rows with the next episode, a watched/released counter such as 30/35 and a one-tap check that logs the next episode. A show with no released next episode moves to **Up to date** and is dimmed. Below them a separate **Want** list holds shows saved for later with Start watching; Sort & filter can hide it. **Up to date** shows sit last, under Want. The Notifications bell lives only in the Profile tab's top bar. Every bottom sheet opens on the root navigator so its scrim also covers the tab bar. Movies lists only movies in Want, with one-tap Mark watched. Watched movies open from Profile.

**Add** opens a search sheet over the current tab with quick Want and Mark watched / Start watching actions on every result. **Feed** mixes every log of yours and of people you follow (movies, episodes, show starts, ratings, reviews), grouped by day, newest first. A day shows four items and a "Show all N" button. One person's episodes of one show on one day collapse into a single item ("watched 5 episodes · S1 E1 – S1 E5"). Who sees your logs follows Library audience; there is no separate opt-in. Release market and time zone are taken from the phone, not typed.

**Import from Must** sits in the Profile settings sheet. The user enters a public Must username; the must-import Edge Function reads the profile once, then matches titles to TMDB in resumable steps while the page shows "N of M titles". Want, watched movies, show progress (Must stores only a count, so episodes are marked in order), ratings and reviews come over; existing Taspa data is never overwritten, so a second import is safe. Imported logs stay out of the Feed except one "imported N titles from Must" line. Titles that could not be matched are listed and open the search sheet prefilled. The import keeps running on the server after the app is closed (pg_cron calls must-import every minute while a job is running) and ends with an "import_done" notification that opens the import page. Must has no official API, so the function relies on the endpoints its website uses and may need fixing if Must changes them.


## Movie Details

Start with a cinematic still, then the movie title, original title when distinct, and a compact line of release year, runtime, and primary genre. Include the director nearby. The overview holds the synopsis, trailer where available, personal rating and review actions, and community rating with count. Keep exact release date, other genres, credits, reviews, eligible followed activity, and similar titles available in their relevant sections. Use a solid header for navigation and share.

Use a safe-area action dock with **Mark watched** or **Log rewatch**. Want is a secondary action that reflects current eligibility and membership. The first watch saves immediately with Date unknown and offers **Edit date** and **Undo**. Rewatches open an editor and add a separate viewing on explicit Save. **Viewing history** remains visible on watched titles and includes dated and undated entries.

## TV Show Details

Use a shallower still so personal status and progress appear early. Show catalog release state separately from personal **Watching**, **Completed**, **On Hold**, or **Dropped**. Present watched/released episode count, completed-season count, and a supporting progress line. The show overview has explicit **Rate show** and **Review show** actions. Below the season selector, the active season has its own **Rate season** and **Review season** actions, rating, and progress. A saved opinion changes the corresponding action to Edit. Both levels accept optional ratings and reviews before completion.

Keep the ordered season selector near progress. Preserve the selected season and scroll position when returning from episode or opinion detail. Keep the season header and episode list close together, with a text label for each episode number and state. Use a dedicated Next row or action dock with the episode code and title plus **Mark watched**. Tapping the episode opens its detail and watch-date actions. The season action menu and episode sheet make bulk watch, bulk unwatch, and catch-up discoverable with an affected-count preview. Show upcoming releases separately. Use Caught up as a progress label for a Watching show, and show Resume watching for On Hold or Dropped. Preserve existing watches through releases and metadata updates.

## Personal Library

Display exactly three peer sections and retain the last-open section. First open is **Watched Movies**. Search and **Sort & filter** remain easy to find.

| Section | Approved composition and interaction |
| --- | --- |
| **Watched Movies** | Default to a compact three-column poster gallery at typical phone width. Provide a labeled Grid/List toggle and remember the selection. Use the same sort, filter, and collection across layouts. The grid gives artwork priority and includes a readable title and short rating/date metadata. List adds room for longer titles and exposes viewing history per title. Both show one entry per movie and open its detail with history. |
| **Watched Shows** | Group eligible Watching titles with a released next episode under **Continue Watching**. Place **All other tracked shows** below, including caught-up or manually paused/dropped and completed shows. A show appears in one group. A visible **Mark watched** control lets users complete the exact next episode from the Library. Show names, status, and progress before artwork-heavy treatments. |
| **Want** | Use compact poster rows with a title, media type, year or release state, and visible **Mark watched** or **Start watching** where eligible. Keep **All / Movies / Shows** and sort controls. Open details by tapping title or poster and provide Remove from Want in the row menu. Upcoming titles display their dates where known. A successful track/start removes the title from Want and offers Undo. |

**Continue Watching behavior.** Row tap opens the next episode in context without changing progress. The button saves in one tap, refreshes both counts and the next target, and offers Undo. If the last pending episode is logged, the title moves to the other group and displays the resolved progress or release state. Keep focus stable and make the result explicit. Status filters and sorting apply within visible groups, so the selected filter remains authoritative.

## Following

Make the person the first read, followed by the activity, title, and response controls. Keep chronological ordering and vary the format by activity rather than wrapping every event in a large card. Reviews are text-first with optional contextual imagery and an eligible rating. Deliberately shared ratings are compact, with one star and the score. Opted-in first-watch and first-start milestones are brief activity rows. Keep likes and comments on published reviews. Comment opens the existing review thread. Share is available on eligible targets. The author and title have distinct links.

Flagged reviews and protected season reviews show an opaque **Reveal spoiler** control. Keep concealed text and comment excerpts out of feed previews and notifications. The caught-up moment and routine individual episode completions stay personal under the product spec's activity rules.

## Profile

Must-style header: photo on the left, display name and handle on the right, with small "N followers · N following" links under the name, then bio and Edit profile + Settings (or Follow + More). A stats row shows **Want**, **Watched** (movies), **Series** (tracked or with any watched episode) and **Episodes**; tapping a stat opens its list. Below, chips Want / Watched / Series / Reviews switch a poster grid that keeps loading as you scroll; Series posters show watched/released counts.

Keep eligible reviews and visible Library sections easy to reach through labeled profile sections. A visitor gets Follow, Following, Request to follow, or Requested as applicable. Owners get Edit profile and Settings, plus their inbox. Respect blocked/private states and keep private watch dates out of visitor views. Favorites have implementation requirements here. Their V1.1 release placement remains as specified in the product roadmap.

## Implementation handoff

Favor stable content, explicit state changes, neutral error recovery, and short transitions. Apply the shared system to the six core destinations, supporting screens, and substates. Check each at compact width and enlarged type. Prioritize the handoff scenarios in [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md#implementation-review).
