# Frontend: Share-Menu Integration + Download Page Redesign

Date: 2026-06-16
Scope: `flutter_app/` only. No backend changes.

## Summary

Three independent frontend features:

1. **OS share-menu integration** — register the app in Android's share sheet.
   A shared **video** link starts a background download (no app UI). A shared
   **channel** link opens the app on the channel detail page.
2. **Download page filter/sort redesign** — collapse the All/Unlistened/Listened
   filter chips into a single dropdown, and add a desc/asc sort direction toggle.
3. **Swipe-left-to-delete** on downloaded track rows, with a ~100px reveal threshold.

---

## Feature 1: Share-menu integration

### Goal
- App appears in the Android OS share sheet for shared text/links.
- **Video link** (e.g. `watch?v=`, `youtu.be/`, `/shorts/`, `/live/`): immediately
  start the existing download flow and drop the app to the background — the user
  stays in whatever app they shared from. Progress is visible via the download
  notification and the Downloaded tab next time the app is opened.
- **Channel link** (`/channel/UC…`, `/@handle`, `/c/…`, `/user/…`): open the app
  and navigate straight to that channel's **detail view** (latest videos).
- **Anything else** (or unparseable): open the app normally on the Link tab.

### Approach (chosen)
Flutter-side handling via the `receive_sharing_intent` package. A brief app
flash on share is acceptable (user confirmed). This reuses all existing Dart
download logic rather than duplicating it in Kotlin.

### Android manifest
Add an `<intent-filter>` to the existing `MainActivity` (or a dedicated alias)
for:
```xml
<intent-filter>
  <action android:name="android.intent.action.SEND" />
  <category android:name="android.intent.category.DEFAULT" />
  <data android:mimeType="text/plain" />
</intent-filter>
```
Plus any setup the `receive_sharing_intent` package requires (per its install
docs for the current version).

### New code
- `pubspec.yaml`: add `receive_sharing_intent`.
- `services/share_handler.dart`:
  - `String? firstUrl(String sharedText)` — regex-extract the first http(s) URL
    from shared text (YouTube sometimes prepends a title).
  - `enum SharedLinkKind { video, channel, unknown }`
  - `SharedLinkKind classify(String url)` — video patterns: `watch?v=`,
    `youtu.be/`, `/shorts/`, `/live/`, `music.youtube.com/watch`; channel
    patterns: `/channel/UC…`, `/@handle`, `/c/`, `/user/`. Order: check video
    first, then channel.

### Flow wiring
- In `main.dart` / `MainScaffold`, subscribe to **both** the cold-start initial
  share (`ReceiveSharingIntent.getInitialMedia()`) and the live stream
  (`.getMediaStream()`), so shares work whether the app was running or not.
- Resolve `serverUrl` + `accessToken` from SharedPreferences. If the app is not
  yet configured, route to the setup page instead of acting on the share.
- **Video** → build an `ApiService` from saved config, call
  `DownloadManager.instance.start(api, url)` (fire-and-forget, exactly as the
  Link tab does), then `SystemNavigator.pop()` / `moveTaskToBack(true)` (via a
  platform channel or the `move_to_background` package) so the app backgrounds
  itself.
- **Channel** → resolve channel id: if `extractChannelId(url)` returns a `UC…`
  id use it directly, otherwise `ApiService.resolveChannel(url)`. Then show the
  Channel tab's detail view for that id.
- **Unknown** → open normally on the Link tab.

### Plumbing changes
- `MainScaffold`: accept an optional initial action — `{switchToChannelTab,
  pendingChannelId}` — and a method to switch tabs programmatically (it already
  holds `_currentIndex`). When a channel share arrives while running, switch to
  the Channel tab and hand the id to `ChannelTab`.
- `ChannelTab`: expose a way to open a detail view for an externally-supplied
  channel id (it already resolves+opens detail on paste; factor that into a
  method that the share path can call, e.g. via a `GlobalKey` or a
  `ValueNotifier`/callback passed from `MainScaffold`).

### Edge cases
- App not set up yet → setup page, share ignored (or queued — simplest: ignore).
- `resolveChannel` fails → open Channel tab paste view and show a SnackBar.
- Empty/many URLs in shared text → take the first matched URL.

---

## Feature 2: Download page — dropdown filter + sort toggle

File: `lib/pages/downloaded_tab.dart`.

### Filter
- Replace the three `FilterChip`s (lines ~244–260) with a single
  `DropdownButton<FilterMode>` showing the current filter: **All / Unlistened /
  Listened**. `FilterMode` enum unchanged.

### Sort direction toggle
- Keep `DropdownButton<SortMode>` (Date / Channel / Status).
- Add `bool _sortAsc = false;` state (false = descending = current default:
  newest first).
- Add an `IconButton` next to the sort dropdown showing
  `Icons.arrow_downward` (desc) / `Icons.arrow_upward` (asc).
- Behavior:
  - Picking a **different** sort type → set `_sortMode`, keep `_sortAsc`.
  - Picking the **same** sort type again (re-tap) → toggle `_sortAsc`.
  - Tapping the arrow button → toggle `_sortAsc`.
- `_displayVideos`: after building the sorted list per `_sortMode`, if `_sortAsc`
  is true reverse the result (for `downloadTime` the base list is newest-first,
  so asc = reversed; for `channel`/`listenStatus` reverse the comparator output).

### Result
Layout becomes: `[Filter ▾]   [Sort ▾] [↑/↓]` in the existing horizontal control
row. No change to the list rendering.

---

## Feature 3: Swipe-left-to-delete

File: `lib/pages/downloaded_tab.dart`, in `_buildVideoTile`.

- Wrap the returned `ListTile` in a `Dismissible`:
  - `key: ValueKey(video.youtubeId)`
  - `direction: DismissDirection.endToStart` (swipe left only).
  - `background`: a red container aligned to the right with a delete icon + the
    word **"Delete"**, revealed during the drag.
- Threshold behavior (~100px reveal-and-commit):
  - Use `dismissThresholds: {DismissDirection.endToStart: <fraction≈100px/width>}`
    so a release **past** the threshold dismisses and a release **before** it
    snaps back — matching the spec (drag past ~100px to see "Delete"; release
    there to delete; retract under it to cancel).
  - The "Delete" label/icon visibility is tied to drag extent so it appears as
    the row passes the threshold.
- `onDismissed`: call `LocalLibrary.remove(video.youtubeId)`, reload the list,
  and show a `SnackBar` ("Deleted '<title>'"). **No confirmation dialog and no
  undo** (user confirmed) — the deliberate threshold gesture is the confirmation.
- The existing **long-press context menu** (Play Next / Delete from device) is
  unchanged; its Delete keeps its current confirmation dialog.

---

## Out of scope
- No backend changes.
- iOS share extension (Android-only app).
- The truly-headless native (Kotlin foreground-service) share path — explicitly
  not chosen; the brief-flash Flutter path is used instead.
- Auto-scroll to current subtitle line (separate existing TODO).

## Testing
- Manual: share a video URL from a browser/YouTube → confirm download starts and
  app backgrounds; share a channel URL → confirm app opens to that channel's
  detail view; share random text → app opens normally.
- Manual: Download page filter dropdown filters correctly; sort dropdown + arrow
  toggles direction; re-selecting same sort type toggles.
- Manual: swipe a row left past ~100px and release → deleted with SnackBar;
  swipe a little and release → snaps back, not deleted.
