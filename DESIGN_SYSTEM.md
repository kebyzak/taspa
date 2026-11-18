# Taspa design system

**Implementation baseline · Cinematic Editorial · Dark**

Use this system for Taspa's mobile surfaces. [DESIGN_DIRECTION.md](DESIGN_DIRECTION.md) defines the approved screen hierarchy. [PRODUCT_SPEC.md](PRODUCT_SPEC.md) governs tracking rules, privacy, and release scope. Geometry below uses logical units. Text uses platform-scalable units. Component values are defaults at standard text size.

## Brand identity

**Splice** is Taspa's approved identity. Use the standalone Splice T for launcher icons, native splash, and compact brand placements. Use the supplied Taspa wordmark when the name needs to be read. Both marks are fixed SVG outlines. Keep brand marks distinct from functional navigation and action icons.

The signature pairing is fired coral on graphite, using the existing **Accent** and **Canvas** tokens below. Use ivory on dark surfaces or graphite on light surfaces where a neutral treatment fits. The minimum SVG canvas sizes are 16 × 16 for the symbol and 96 wide for the wordmark. Clear space is measured from the visible artwork. Use the platform icon and launch assets as delivered. [Brand guidelines and Flutter handoff](BRAND_GUIDELINES.md)

## 1. Design tokens

### Color

| Token | Value | Use |
| --- | --- | --- |
| Canvas | `#141416` | Root backgrounds, poster gutters, and detail copy |
| Surface | `#1D1C1F` | Opaque tab bar, action dock, sheets, and feedback |
| Surface pressed | `#2B292D` | Neutral pressed and selected backgrounds, art fallback |
| Text primary | `#F3EEE8` | Titles, body, labels, and primary glyphs |
| Text secondary | `#B2AAA8` | Metadata, secondary controls, captions, and default outline icons |
| Hairline | `#39363B` | Decorative separation with no state meaning |
| Control outline | `#82797E` | Unfilled inputs and boundaries where required for recognition |
| Accent | `#DB806F` | Primary fill, active indicator, progress, or a liked heart |
| Accent pressed | `#C87566` | Pressed primary fill |
| On accent | `#1C1414` | Text and icons on accent fills |
| Selected surface | `#382725` | Quiet selection tint with ivory labels |
| Focus | `#F1AE9F` | Visible two-unit keyboard focus outline with two-unit offset |
| Destructive | `#FFAAA7` | Removal and error text or glyphs, paired with a label |
| Progress track | `#49434A` | Rail behind coral progress. Adjacent text supplies the count. |

Use primary and secondary text on Canvas, Surface, and Surface pressed. Use On accent for filled coral buttons. Use a selection label or icon alongside coral indicators. Use neutral text and icons for disabled controls, with an unavailable reason supplied in adjacent readable text when needed. Selection tint is reserved for controls where it clarifies state. Keep art full-color and use solid surfaces for text, navigation, and CTAs. Shadows are unnecessary on content. Native modal elevation is sufficient.

### Typography

| Role | Family and weight | Size / line height | Use |
| --- | --- | --- | --- |
| Display | Instrument Serif Regular | 32 / 36 | Movie/show detail titles, one editorial feature title, profile name |
| Heading | Instrument Sans Semibold | 24 / 28 | Screen headings and major section headings |
| Body | Instrument Sans Regular or Semibold | 16 / 24 | Synopsis, review, list title, tabs within a screen, form value, button |
| Supporting | Instrument Sans Regular or Semibold | 13 / 20 | Metadata, captions, counts, secondary section labels, tab bar text |

Use sentence case. Use regular for reading and semibold for actions and row titles. Use tabular numerals where supported for episode counts, ratings, and dates. Body width is capped at 600 logical units on wide layouts. Use the platform's serif fallback for missing display glyphs and system sans for UI glyphs. Check localized titles and Cyrillic/Kazakh coverage, preserve selectability of copy where appropriate, and keep original titles available.

### Spacing, geometry, and density

| Token | Value | Use |
| --- | --- | --- |
| Spacing scale | 4, 8, 12, 16, 24, 32, 48, 64 | Choose the smallest appropriate shared step |
| Screen gutter | 16 compact, 24 at widths 600+ | Content column. Detail still may extend to the edges. |
| Relationship spacing | 4–8 within metadata, 8–12 inside rows, 24–32 between groups | Favor spacing between adjacent sections and feed entries |
| Grid and shelf gap | 12 | Consistent horizontal gutter |
| Content corner | 4 | Poster, still, and small media placeholder. Use 0 for full-bleed art. |
| Control corner | 8 | Button, tag/filter control, and feedback container |
| Sheet top corner | 16 | Top corners only. Follow platform safe areas. |
| Avatar corner | Circular | Avatar sizes 32 for feed, 40 for people lists, 72 for profile |
| Hairline and progress | 1 logical separator, 4-high progress rail, 2-high selection indicator | Flat boundaries and state indicators |
| Compact target | 44 pt minimum on iOS, 48 dp minimum on Android | All interactive targets, even compact icon, poster, or row actions |

Treat 375 logical units as the baseline. At narrower widths or enlarged type, reduce grid column count and wrap controls. When the Library section names no longer fit without truncation, reflow to a stacked selector with all three labels visible. At 600 and above, give poster shelves and grids more columns or visible items within the available width. Keep reading and reachability constraints.

### Imagery

| Asset | Standard |
| --- | --- |
| Poster thumbnail | 48 × 72 in index rows and compact reviews. In detail lockups use 72 × 108. |
| Poster shelf | 96 × 144 in Discover and Profile favorites. Preserve 2:3 and display a caption beneath. |
| Poster grid | 2:3 in three equal columns at 375 with 16-unit margins and 12-unit gutters. Use two columns at narrow widths or when captions cannot remain legible, and list-style flow at the largest accessibility settings if needed. |
| Backdrop and still | Use 16:9 as a source and set a content-aware crop. Detail art max height is 224 for movies and 160 for shows. Optional Discover feature cap is the lesser of 144 or 20% of usable viewport height. In feed, a still is optional and maxes at 160 high. |
| Missing image | Reserve the same ratio in a solid well. Keep the visible external title and metadata. A title used as a single joint image/text target has one accessible name. |

Use a shared focal crop policy for stills. Keep complete poster art visible within the 2:3 well. Captions sit outside artwork. Truncate grid captions after two lines at standard type if necessary, with the complete accessible name and full detail title. In the List layout let titles wrap. Decorative duplicated artwork is omitted from the assistive reading order.

### Iconography

Use one shared outline family for app chrome. Size primary navigation and toolbar glyphs at 24 and inline glyphs at 16 or 20, with a consistent 2-unit stroke at 24. Preserve platform-native glyphs for system back and share where appropriate. Standard mappings are compass for Discover, stacked frames for Library, people for Following, person/avatar for Profile, bell for Notifications, magnifier for Search, sliders for Sort & filter, and ellipsis for More actions. Use the same grid and list glyphs with accessible labels on all layout toggles.

Use a check for watched, a bookmark for Wanted, heart for Like, speech bubble for Comments, and star for rating. Play is reserved for a trailer or actual media playback. Use solid variants for selected heart and bookmark when helpful. Treat navigation, toggle, and checked states as semantic selection in addition to their visual indicators.

## 2. Reusable components

| Component | Required anatomy and variants | Behavior |
| --- | --- | --- |
| Root navigation | Discover, Library, Following, Profile. Icon and visible text with selected indicator. 56-unit content height plus bottom safe area, allowed to expand for text. | Discover is the initial signed-in destination. Retain each tab's navigation state. Back returns to source and restores position. |
| Header and action dock | Solid header with title/back and scoped controls. Dock contains one primary action and optional neutral action or context, above bottom safe area. | Library and Discover expose Search in one tap. Notifications are reachable from Discover, Following, and own Profile. Details use Back and the dock. Add scroll padding so the dock covers no content. Stack controls as space tightens. |
| Button and icon action | Primary coral, neutral outline, quiet text, destructive text, and labeled icon variants. Support rest, pressed, focused, disabled, and pending. | Text communicates effect. Ignore repeat activation while the same action is pending. Icon-only controls have explicit names and states. |
| Selector | Labeled sections, filters, season choice, and Grid/List variants. Selection uses text contrast plus underline, check, or filled segment. | Preserve user selection. Allow scrolling on long ordered season rows and offer a **Choose season** sheet when the complete range needs a faster route. Provide full current season label. Grid/List is a view preference independent of data filters. |
| Poster tile, shelf, and grid | Image, title, type or year where useful, and optional short supporting caption. Shelves have a title and **See all** for browse collections with a full result. | Tap opens details. Swiping a shelf scrolls horizontally without disrupting the vertical feed. Visible See all provides an alternative to swiping. Restore position on return. |
| Compact title row | 48 × 72 poster, title, short release line, optional status, trailing menu or visible action. Typical minimum 88 high including spacing. | Title and poster form one detail target. Tracking button and menu are independent targets. Wrap metadata and move actions onto their own line when space is tight. |
| Progress summary | Status, watched/released count, completed-season count, labeled next/release information, optional rail. Season variant shows its own count. | Counts are source of truth for visual fill. Omit determinate rail when denominator is unavailable. Reveal no private progress to unauthorized viewers. |
| Next episode row | Label **Next**, code and title, plus visible **Mark watched**. Applies in Continue Watching and show detail. | Title opens the episode. Mark watched is one tap, saves with Date unknown, updates progress, and shows Undo. The episode detail offers date editing. Keep the action accessible when the next episode is shown inside the selected season list. |
| Episode row and season actions | Code, title, and Watched, Unwatched, or Upcoming label. Selected season has explicit opinion actions. | Tap opens detail with watch date and permitted tracking controls. Season actions include mark season watched/unwatched, or mark released episodes watched. Use an affected-count preview for bulk operations. Upcoming rows are informational. Specials are grouped separately. |
| Rating summary and editor | Labeled personal number plus star. Separate community name, average, and count. Editor clearly names the target and shows five stars, a numeric value, half-step controls, and Clear rating. | Accept half steps from 0.5 to 5. Blank represents unrated. Make precise adjustment available by buttons and accessible adjustable semantics. Save applies to the named target only. Hide community average below the spec threshold. Keep rating and review audience choices separate. |
| Review editor and reveal | Title/season target, text field, spoiler setting, audience, and private save or publish action. Read view uses opaque spoiler replacement. | Review can be saved without rating or completion. Preserve private drafts on failure. Ask for explicit reveal before showing protected text or thread. Share uses current visibility. |
| Activity entry | Author, timestamp, activity label, title, optional art, plus event-specific content and actions. | Reviews can show eligible rating and Like, Comment, and Share when permitted. Shared-rating and tracking-milestone rows only link to appropriate destinations and any eligible title share. Use no empty reaction bar. |
| Native sheet, menu, feedback | Sheet for season picker, bulk preview, editors, and sort/filter. Menus for low-frequency row actions. Feedback sits above persistent chrome. | Provide visible cancel/dismiss. Restore focus to invoking control, or to the next logical target after deletion. Give destructive actions named confirmation. Use feedback for undoable actions, errors, and pending changes. |

## 3. Interaction contracts

### Library layout and tracking

- **Grid/List.** Default Watched Movies to Grid. Persist the chosen presentation with the user's Library view state. Both layouts retain sorting, filtering, and a visible item anchor when toggled. Grid shows rating and last known watch date where available. List exposes title history and the Date unknown fallback. Each movie appears once even with multiple saved viewings.
- **Continue Watching.** Include only Watching shows with an earliest released unwatched regular episode. Put them first under their own heading when eligible. Put every other tracked show under **All other tracked shows**. Watching titles that meet the product spec's Caught up condition show that label and the next release when known. When the catalog cannot confirm progress, show the available count and metadata state. Completed, On Hold, and Dropped use their existing status behaviors. Sort within groups and apply filters to both. Hide an empty group and show the appropriate empty state when both are empty.
- **One-tap next episode.** Mark watched targets the displayed episode. Update the current row and progress counts together. Show the next eligible gap even when an episode out of order was already watched. Move a show between groups when eligibility changes. Keep focus on its status or next action and announce the result. Undo restores affected tracking and group membership when applicable without overwriting newer edits.
- **Wanted.** Keep the All/Movies/Shows filter separate from the three-section selector. Use the compact title row with visible Mark watched or Start watching. Show release information for upcoming titles. Remove from Wanted lives in the named overflow. Successful track or start updates the target Library collection and removes the Wanted row as one visible change.

### Show and season opinions

Place **Rate show** and **Review show** by the show opinion summary. Place **Rate season** and **Review season** in the selected season header. For saved values use **Edit show rating**, **Edit show review**, **Edit season rating**, or **Edit season review**. Keep both actions visible when the show or season is incomplete. The editor names the show and, when relevant, season number or name. Rating, review text, watch status, and watch dates save independently. Give community and personal values distinct labels. Episode rows expose tracking actions only.

### Profile favorites

Display separate **Favorite Movies** and **Favorite Shows** shelves before eligible review and Library content. Accept up to four manually ordered titles per shelf. **Edit favorites** opens owner-only title search and reorder controls. An entry can be removed and reordered using labeled Move up/Move down actions as well as drag. Block duplicate titles within a shelf, keep its media scope, and keep viewing state and Wanted membership intact. Show people the audience before saving. Inherit the Library audience and profile access rules, with the existing Only me default. A profile that hides its Library also hides these shelves from that viewer. An empty owner shelf offers an add action. Omit empty or inaccessible shelves for visitors. Favorites do not create feed events. The product roadmap specifies the release phase.

### Following activity variants

| Activity | Presentation | Actions and privacy |
| --- | --- | --- |
| Published movie or show review | Author and time, title, eligible rating, readable excerpt, optional still | Like toggles and updates count. Comments open the attached thread. Share if public and eligible. |
| Published season review | Same review frame with a clear season label | Apply author spoiler flag and the viewer's completion state. Hide protected text and thread behind Reveal spoiler. |
| Deliberately shared rating | Compact author, title or season label, numeric score and star | Open the associated title or season. Audience applies independently of review publication. Show no review excerpt unless there is a separate eligible review. |
| First movie watched or first show start | Compact author, verb, and title | Show only eligible opted-in milestones. Use “Started watching” for a zero-episode start. Do not imply that an episode was completed. |

Keep events chronological and link avatar/name to the author and title to catalog detail. Editing a published review updates its existing event. Hide unpublished, deleted, blocked, or newly restricted activity across feed, previews, and deep links. Individual episode watches, Wanted removals, and routine edits do not create entries.

### Motion and native gestures

| Interaction | Behavior |
| --- | --- |
| Press and select | 120 ms target for small tonal, underline, or icon changes. Use platform ripple where appropriate. |
| Progress confirmation | 160 ms target for fill and icon update after accepted action. Keep row position stable where possible. A light haptic can confirm an explicit tracking action if platform settings allow. |
| Image readiness | Up to 180 ms opacity fade from the existing placeholder without a layout shift. No autoplaying motion or parallax. |
| Navigation and sheets | Use platform transitions and back gestures. Allow platform sheet dismissal with a visible alternative. Confirm dismissal for unsaved edits that would otherwise be lost. |
| Swipe and long press | Shelf scrolling and native row menus may supplement visible controls. Keep quick actions, filters, and confirmation reachable by tap, keyboard, and assistive tech. |
| Reduced Motion | Make content changes immediate or use the platform-reduced transition. Turn off decorative fades and fills. Preserve focus, feedback, and state announcements. |

## 4. Accessibility and adaptive behavior

- Use at least 4.5:1 contrast for ordinary text and 3:1 for large text and required UI indicators. Check control outlines and focus against their adjacent surfaces. Keep important text on solid backgrounds.
- Support platform text scaling. Reflow navigation, panels, and footers before truncating actions. Use multiline metadata, wrap horizontal controls where feasible, and cap reading measure on wide screens. Do not shrink system text or hide an action to preserve an image crop.
- Use logical focus order. Screen titles and section headings are headings. Tabs, filters, and view mode expose selection. Rating and progress announce their scope and exact count. Explicit names include context, for example **Mark S2E2 Fog Line watched** and **Edit Season 2 rating**.
- Announce Pending, saved, error, and Undo availability. Keep Undo on screen according to platform accessibility timeout preferences. Provide persistent correction via history and episode actions after feedback expires.
- Separate focus from selection. Maintain visible focus indicators. After a sheet closes, restore focus to the trigger. When a list item moves or disappears, follow its new state if visible or focus the next logical item and announce the change.
- Respect screen-reader and switch navigation across horizontal shelves. Offer a route to the full browse result. Avoid duplicate announcements for artwork, titles, and adjacent glyphs. Use dates and numbers in localized display formats, with spoken labels for rating and progress.

## 5. UI states

| State | Required behavior |
| --- | --- |
| Initial loading / refresh | Preserve chrome and size placeholders to content. During refresh retain last available data. Refresh activity, poster shelves, and profile sections independently. |
| Empty / no results | Give a short reason and one relevant action. Empty Library offers Search titles. Empty Following offers Find people or title reviews. Filtered results offer Clear filters. Hide empty visitor favorites and empty Continue Watching groups. |
| Missing metadata | Keep title and allowed actions when imagery or optional data is unavailable. Use Date unknown for undated viewings. For uncertain releases use a neutral unknown state and suppress invalid episode actions. Keep recovered history reachable. |
| Offline / Pending | Keep available catalog and Library content visible. Queue eligible explicit tracking edits whose targets are known. Show Pending without claiming sync is complete. Keep review drafts. Require connectivity for publishing, social, and account actions. |
| Error / conflict | Explain the failed action and provide Retry when actionable. Recover affected display state after a failed move or batch. When a queued edit conflicts with a newer change, show the saved state and let the user reapply intent. |
| Saved / undo | Use quiet feedback at the bottom. Examples are **Marked watched** with Edit date and Undo, and **Episode marked watched** with Undo. Undo restores prior affected watch, Wanted, and status states subject to later edits. |
| Restricted / spoiler | Render minimal authorized content. Use Reveal spoiler only when the viewer can access the review. Use a neutral unavailable state for restricted or deleted targets. Keep concealed snippets out of previews and notifications. |

## Implementation review

| Scenario | Pass condition |
| --- | --- |
| Open Discover at compact width | Search is reachable and the first poster shelf begins on the initial screen at standard type. The feature stays within its height cap. Movies and shows use equal shelf sizing. |
| Switch Watched Movies from Grid to List and return later | The layout preference and filters persist. The collection, sort order, and viewing history remain consistent. |
| Mark the displayed episode from Continue Watching | One tap updates count, next gap, and group when appropriate. Undo restores the prior state subject to later edits. Upcoming episodes offer no Mark watched control. |
| Use Wanted with enlarged type | All three peer sections and media filters remain reachable. Movie and show actions keep explicit labels. The row moves once after successful tracking. |
| Rate a show and review an incomplete season | Both controls stay visible. The correct target is identified in each editor. Values and privacy settings remain independent. |
| Edit profile favorites and open as an unauthorized viewer | Owner can add and reorder each media type. Restricted viewers receive no hidden shelf or title data. Changes create no tracking event. |
| Review mixed Following activity | Published reviews, ratings, and opted-in milestones read distinctly in chronological order. Only authorized reviews expose interaction controls. Protected review text stays concealed until reveal. |
| Check appearance and input states | Contrast, target dimensions, enlarged text, focus, Reduced Motion, and offline recovery work on the shared components and their screens. |
