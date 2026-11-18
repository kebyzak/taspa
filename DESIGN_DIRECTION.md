# Taspa design direction

**Final visual foundation · Cinematic Editorial · Dark**

Taspa is a cinematic diary with the immediacy of a native mobile app. Film artwork sets the atmosphere. Tracking, discovery, and conversation determine what appears first and where actions live. Dark graphite, warm ivory, restrained fired coral, and selective editorial serif typography carry the approved identity across screens.

[PRODUCT_SPEC.md](PRODUCT_SPEC.md) governs product behavior and release scope. This document defines the approved screen requirements. [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) defines the shared tokens, components, states, and interaction contracts for implementation. Earlier concept boards are historical references. Use these documents for current layout and behavior.

## Visual foundation

- **Let the art set the tone.** Use vivid, rights-cleared posters at their original proportions and carefully framed stills. Reserve full-width artwork for detail pages. In Discover, smaller editorial crops give horizontal poster collections room to appear early.
- **Use serif for signature content.** Instrument Serif belongs on cinematic detail titles, the occasional featured title, and a profile's display name. Instrument Sans handles navigation, section headings, metadata, reviews, numbers, and actions.
- **Group by spacing.** Keep interfaces mostly flat on graphite. Use slightly raised opaque surfaces for sheets, the tab bar, and primary action docks. Reserve hairlines for boundaries that aid orientation. Use consistent 4 and 8 pt corners.
- **Use coral to signal an action or state.** Fired coral `#DB806F` marks a primary action, selected indicator, progress fill, or liked heart. Supporting controls use ivory and neutral surfaces. Every important state has a label, glyph, or shape independent of color.
- **Design for one-handed use.** Keep high-frequency tracking actions in the lower reach zone or beside the relevant title. Prefer system navigation and sheets. Keep text and essential controls on solid surfaces. Full-bleed imagery, clean cuts, and typographic hierarchy provide depth.

## Discover

Discover opens first after sign-in. Search is a single tap away and supports the product spec's movie, TV, people, and user destinations. The inbox is in the header. An optional single editorial feature uses a shallow crop capped at 144 logical units and 20% of the usable viewport height. Its title and action sit on the canvas beneath it. No automatic advance. Skip the feature when there is no editorial selection.

**Trending Movies** and **Trending Shows** use matching horizontal poster shelves and See all routes. At a typical phone width the first shelf heading and posters begin on the initial screen. Popular, New, Upcoming, genre browsing, and eligible recommendations from followed accounts use the same collection system. Show the recommendation reason where relevant. Both media types get equivalent space and browse depth. Posters stay recognizable on a dark canvas and titles, type, and release details remain available outside the art.

## Movie Details

Start with a cinematic still, then the movie title, original title when distinct, and a compact line of release year, runtime, and primary genre. Include the director nearby. The overview holds the synopsis, trailer where available, personal rating and review actions, and community rating with count. Keep exact release date, other genres, credits, reviews, eligible followed activity, and similar titles available in their relevant sections. Use a solid header for navigation and share.

Use a safe-area action dock with **Mark watched** or **Log rewatch**. Wanted is a secondary action that reflects current eligibility and membership. The first watch saves immediately with Date unknown and offers **Edit date** and **Undo**. Rewatches open an editor and add a separate viewing on explicit Save. **Viewing history** remains visible on watched titles and includes dated and undated entries.

## TV Show Details

Use a shallower still so personal status and progress appear early. Show catalog release state separately from personal **Watching**, **Completed**, **On Hold**, or **Dropped**. Present watched/released episode count, completed-season count, and a supporting progress line. The show overview has explicit **Rate show** and **Review show** actions. Below the season selector, the active season has its own **Rate season** and **Review season** actions, rating, and progress. A saved opinion changes the corresponding action to Edit. Both levels accept optional ratings and reviews before completion.

Keep the ordered season selector near progress. Preserve the selected season and scroll position when returning from episode or opinion detail. Keep the season header and episode list close together, with a text label for each episode number and state. Use a dedicated Next row or action dock with the episode code and title plus **Mark watched**. Tapping the episode opens its detail and watch-date actions. The season action menu and episode sheet make bulk watch, bulk unwatch, and catch-up discoverable with an affected-count preview. Show upcoming releases separately. Use Caught up as a progress label for a Watching show, and show Resume watching for On Hold or Dropped. Preserve existing watches through releases and metadata updates.

## Personal Library

Display exactly three peer sections and retain the last-open section. First open is **Watched Movies**. Search and **Sort & filter** remain easy to find.

| Section | Approved composition and interaction |
| --- | --- |
| **Watched Movies** | Default to a compact three-column poster gallery at typical phone width. Provide a labeled Grid/List toggle and remember the selection. Use the same sort, filter, and collection across layouts. The grid gives artwork priority and includes a readable title and short rating/date metadata. List adds room for longer titles and exposes viewing history per title. Both show one entry per movie and open its detail with history. |
| **Watched Shows** | Group eligible Watching titles with a released next episode under **Continue Watching**. Place **All other tracked shows** below, including caught-up or manually paused/dropped and completed shows. A show appears in one group. A visible **Mark watched** control lets users complete the exact next episode from the Library. Show names, status, and progress before artwork-heavy treatments. |
| **Wanted** | Use compact poster rows with a title, media type, year or release state, and visible **Mark watched** or **Start watching** where eligible. Keep **All / Movies / Shows** and sort controls. Open details by tapping title or poster and provide Remove from Wanted in the row menu. Upcoming titles display their dates where known. A successful track/start removes the title from Wanted and offers Undo. |

**Continue Watching behavior.** Row tap opens the next episode in context without changing progress. The button saves in one tap, refreshes both counts and the next target, and offers Undo. If the last pending episode is logged, the title moves to the other group and displays the resolved progress or release state. Keep focus stable and make the result explicit. Status filters and sorting apply within visible groups, so the selected filter remains authoritative.

## Following

Make the person the first read, followed by the activity, title, and response controls. Keep chronological ordering and vary the format by activity rather than wrapping every event in a large card. Reviews are text-first with optional contextual imagery and an eligible rating. Deliberately shared ratings are compact, with one star and the score. Opted-in first-watch and first-start milestones are brief activity rows. Keep likes and comments on published reviews. Comment opens the existing review thread. Share is available on eligible targets. The author and title have distinct links.

Flagged reviews and protected season reviews show an opaque **Reveal spoiler** control. Keep concealed text and comment excerpts out of feed previews and notifications. The caught-up moment and routine individual episode completions stay personal under the product spec's activity rules.

## Profile

Lead with the person's photo or initials, display name, handle, bio, and relationship action. Put counts and owner settings after identity. Include **Favorite Movies** and **Favorite Shows** as compact poster shelves with direct title links. Owners add, remove, and reorder through **Edit favorites**. Favorites use the Library audience and profile access rules, and are a deliberate profile selection independent of tracking. Empty shelves are hidden from visitors. The owner sees a direct add action.

Keep eligible reviews and visible Library sections easy to reach through labeled profile sections. A visitor gets Follow, Following, Request to follow, or Requested as applicable. Owners get Edit profile and Settings, plus their inbox. Respect blocked/private states and keep private watch dates out of visitor views. Favorites have implementation requirements here. Their V1.1 release placement remains as specified in the product roadmap.

## Implementation handoff

Favor stable content, explicit state changes, neutral error recovery, and short transitions. Apply the shared system to the six core destinations, supporting screens, and substates. Check each at compact width and enlarged type. Prioritize the handoff scenarios in [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md#implementation-review).
