# Changelog

All notable changes to DreamPlayer are documented here. Each release's entry is
pulled into the GitHub Release body automatically by `.github/workflows/release.yml`.

## 0.2.0

Major release — **Apple TV support lands**, Android TV / Fire TV playback rebuilt on the in-app player, and phone gesture controls.

### Apple TV (tvOS) — alpha, CI-green
- **tvOS build works end-to-end** — DreamPlayer builds for Apple TV via the community `flutter-tvos` toolchain (Flutter 3.47 base). CI scaffolds `tvos/` fresh each build, overlays our adapted Swift files, injects the AetherEngine packages into the Xcode project, and produces an unsigned `DreamPlayer-tvOS-alpha-<version>.ipa`. **Alpha** — compiles and ships, but not yet verified on Apple TV hardware.
- **AetherEngine on tvOS** — the same playback engine as iOS resolves as a Swift Package Manager dependency for appletvos: `AvPlayerView.swift` imports AetherEngine + AetherEngineSMB; FFmpeg demux/decode and DV/HDR10 via the native AVPlayer path come along automatically. Deployment target raised to **tvOS 17.0** (the engine's minimum — the scaffold pins `TVOS_DEPLOYMENT_TARGET=15.0` at project level, which beats a target-level override, so both names are set at both levels).
- **Adapted Swift files** — `AvPlayerView.swift` guards `MPVolumeView`/brightness/EDR-headroom with `#if !os(tvOS)`; `AppDelegate.swift` drops IntentBridge (no "Open with") and registers the player view factory, file browser, WebDAV client, Jellyfin discovery, and cache cleaner behind the implicit-engine delegate; `FileBrowser.swift` is Documents-only (no document picker — picker calls are graceful no-ops). `WebDAVClient`, `JellyfinDiscovery`, `BufferedSMBReader`, `CacheCleaner` copied unchanged from iOS.
- **tvOS plugins ported** — `shared_preferences_tvos` + `package_info_plus_tvos` (from fluttertv/plugins) give resume/continue-watching, TMDB cache, and saved servers real persistence; `package_info_plus` bumped to ^10.2.1 for compatibility. Plugins without tvOS implementations (`url_launcher`, multicast-lock channel) are wrapped in try/catch so nothing crashes.
- **CI plumbing solved** (`tvos.yml`) — scaffold step backs up our committed `tvos/Runner/*.swift` before regenerating; Ruby `xcodeproj` adds the AetherEngine SPM package reference + both products to the Runner target, disables code signing (flutter-tvos has no `--no-codesign`; equivalent of `flutter build ios --no-codesign`), and registers every overlaid Swift file in the Sources phase; PlistBuddy adds Bonjour services + local-networking ATS; packaging discovers `Runner.app` dynamically instead of hardcoding the output path.
- **Siri Remote** — arrow keys reveal controls / seek ±10s, select activates focused buttons, Menu hides controls then exits; the remote's **play/pause media key toggles playback** even off the TV code path (fixed this release).

### Android TV / Fire TV
- **Custom focus highlight** — blue 3px border + glow shadow + AnimatedScale (1.25× transport buttons, 1.05× cards/list tiles/fields) across all TV-focusable widgets: transport controls, sheet list tiles, seekbar, home cards.
- **TvTile shared widget** — single source of truth for TV focus-glow wrapper (`lib/widgets/tv_tile.dart`).
- **TvOverscan safe-area** — wraps each TV screen with 36px side / 20px top-bottom padding (`lib/widgets/tv_overscan.dart`).
- **TvTextField** — two-FocusNode design: outer glow node for D-pad targeting, inner `skipTraversal` node for the TextField. OK/select opens the system Leanback IME; back/Done hands focus back to the glow node. No custom keyboard.
- **Leanback banner** — 640×360 `banner.png` in `AndroidManifest.xml` for TV launchers.
- **TV long-press** — Enter/select key held 500ms fires `onLongPress`; `KeyRepeatEvent` swallowed.
- **Home scroll-on-return** — `SliverAppBar` pinned, `jumpTo(0)` on load with stable keys.
- **Buffer sizing** — adaptive by heap class: Fire TV 24MB ring buffer (heap 192MB), phones 96MB (heap ≥ 256MB).
- **Transparent window fix** — `MainActivity.kt` sets `Color.TRANSPARENT` on TV devices; `ExoPlayerView.kt` calls `setZOrderMediaOverlay(true)` — video visible on Fire TV Stick.

### Player
- **Gesture controls** — vertical swipe on left half adjusts brightness (`Window.screenBrightness` on Android, `UIScreen.main.brightness` on iOS); right half adjusts system volume (`AudioManager STREAM_MUSIC` on Android, `MPVolumeView` hidden slider on iOS). Dark centered feedback pill with icon + percentage, auto-fades 0.8s. Controls hide during gesture.
- **Swipe gestures toggle** — "Swipe gestures" switch in Settings → Player section (default on); hidden on TV via `isTvMode()`.
- **Play-pause ring highlight** — `_TvControlButton` `alwaysShowRing` parameter; center play-pause uses `alwaysShowRing: !_isTv` so the ring glow shows on phones/tablets without a D-pad.

### Bug fixes
- **SMB badge** — `VideoItem.playbackSource` now accepts both `smb:` and `smb_` prefixes for backward compat with stored data.
- **Double-back-press exit** — root screen shows a SnackBar and requires two taps within 2s to exit (prevents accidental back-press exits on Android).
- **Seekbar minimal highlight** — TV focus highlight on seekbar is a thin 2px border only (no glow, no scale).
- **Flutter 3.47.1** — local toolchain upgraded to match CI and the flutter-tvos base (Dart 3.13); all 129 tests pass, analyzer clean.

## 0.1.11

- **Minimum iOS lowered to 16.0** — the previous floor of iOS 18.0 was conservative; AetherEngine declares `.iOS(.v16)` as its platform minimum and no iOS 18-only APIs are used anywhere. All three Xcode targets updated (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`).

## 0.1.10

- **SMB: wrong credentials now surface an error (Android)** — browsing a saved server with a bad username/password used to silently return an empty share list (the share probe swallowed every exception, so an auth failure was mistaken for "no such share"). `SmbStore`/`SMBClient.kt` now catches `SmbAuthException` separately: if auth fails on every probed share, the shares list and any folder listing report **"Login failed — check username/password/domain"** (a `smb_auth` channel error) instead of a blank screen. The connection-test dialog already reported the failure correctly; only the browse path was silent.

## 0.1.9

- **Per-file TMDB posters in every file list** — the folder screens (library folder contents + subfolders), the WebDAV browser, and the Jellyfin browser now **auto-fetch** TMDB metadata for each movie/episode as the list loads and show the file's **poster thumbnail** instead of the plain play icon. Each row resolves under the *same* stable key its tap uses (`resumeKey`/`folderbookmark:`/`webdav_<server>/<path>`/`jellyfin:<host>/<itemId>`), so opening the file is a direct cache hit — no re-search, the details screen is already resolved. If auto-fetch fails, opening the file and picking the right title via **"Fix match"/"Search TMDB"** persists that poster, and the row updates to show it the moment you return (both screens listen to the TMDB store).
- **Standalone movies no longer inherit a folder's metadata** — in folder mode, a movie file inside a bookmarked folder used to show the *folder's* matched title/poster (e.g. a "Movies" folder's match shown for every file in it). `carryMeta` now runs only for **episodes** of a TV-show folder; movie files resolve their own title, and any folder metadata an older build stamped onto a movie's key is cleared so it re-searches. Jellyfin folder mode applies the same rule (carry only for `Type == Episode`).
- **Shared poster helper** — `posterUrlOf()` lives in `tmdb_client.dart` so the folder, WebDAV, and Jellyfin row tiles all render the same 48×72 rounded poster thumbnail (with the play icon as the error fallback).

## 0.1.8

- **In-app SMB removed from iOS** — the iPad AMSMB2 + AetherEngineSMB browser and playback were deleted: it was slow, didn't play every video, and audio-track switching could crash the app. The "Network shares" home entry is gone on iOS. **Android SMB stays** — the `SmbScreen` + `SmbClient` (jcifs-ng browse + `SmbDataSource` streaming) remain; the "Network shares" entry shows on Android only. NAS playback: **Android** → in-app SMB browser, CX Explorer "Open with", WebDAV, Jellyfin; **iPad** → Files app "Open with", in-app WebDAV, in-app Jellyfin. `BufferedSMBReader` stays for WebDAV's read-ahead; `AetherEngineSMB` stays for WebDAV's `ByteRangeSource`. Full iOS SMB implementation notes preserved in AGENTS.md as a revival blueprint.
- **Source badges** — continue-watching cards show `CX SMB` (Android handoff), `Files / SMB` (iOS Files-app SMB), and legacy `SMB` (old in-app `smb:` keys, historical only).
- **TMDB auto-fetch works for network-share videos** — opening a video from the SMB browser (or any network share) now lands on a fully-resolved details screen instead of prompting "Search TMDB". Root causes fixed: the folder prefetch and the video tap resolved under *different* keys, so the prefetched match was never reused (both now use the same stable key → direct cache hit); a tap during an in-flight prefetch returned a false "no match" (concurrent calls now share one in-flight search future); and a missing TMDB match used to treat filename noise like `MA`, `Hindi`, `SDR`, `ESub` or bracket audio metadata (`[Hindi AMZN DDP 2.0 224kbps + English DTS-HD MA 5.1]`) as part of the search query. Verified on-device: `Silence`, `Identity`, `Oldboy`, `Her (2013)`, `24`, `Main Vaapas Aaunga` all auto-match at score 1.00.
- **Filename → search-query parser cleanup** — audio-language/codec noise (`hindi`, `tamil`, `telugu`, `korean`, `esub`, `uncut`, `sdr`, `ma`, `hdhub4u`, …) is stripped; bracketed/parenthesized audio metadata is dropped (keeping `[S02E04]` episode tags and `(2013)` years for detection); bitrate annotations (`224kbps`, `640kbps`) are removed; `<group>-<site>` release suffixes (`USURY-4kHdHub.com`) are cut including the group; and underscore-glued tags (`Stranger_Things_[S02E04]_1080p`) no longer survive into the cleaned title. New regression tests cover the real NAS filenames.

## 0.1.7

- **Static HDR10 detection for MKV files without Colour element (Android)** — some HEVC MKVs omit the MKV `Colour` element; the PQ/BT.2020 mastering metadata lives only in the HEVC SEI (payload type 137 Mastering Display Colour Volume, payload type 144 Content Light Level). `ExoPlayerView.kt` now probes the first ~10 MB of video samples on a background thread with `MediaExtractor`, scanning Annex-B / AVCC NALs for these SEI payloads. When found, `hdr10Content=true` is set and `stateMap` emits `desired=5.0` + `colorTransfer=6`, engaging the HDR headroom / window color mode path for true HDR10 passthrough even without container-level signalling. Verified on-device: a test MKV with no Colour element but with SEI 137/144 now shows the HDR10 chip and triggers the EDR ramp.

## 0.1.6

- **Real HDR Dolby Vision output (Android) via hybrid-composition platform view** —
  the player previously rendered through Flutter's stock `AndroidView` widget, which
  composites the video into a **virtual display + texture** (a non-HDR path that
  flattens PQ to SDR at ~500 nits and washes colors out). The view is now built with
  `PlatformViewLink` + `initExpensiveAndroidView` (hybrid composition), keeping the
  video `SurfaceView` a real SurfaceFlinger layer on the physical display. Verified
  on-device: the DV P8 file composites as `BT2020_ITU_PQ` with 10-bit PQ buffers,
  `hdr metadata types=9` and `whitePointNits≈1250` — byte-for-byte the profile of a
  pure-native player (Just Player) — and colors now match on screen. DV content also
  skips the window HDR/headroom machinery entirely (decoder-native BT.2020 PQ
  device-composites), and DV tracks whose MKV omits the `Colour` element (Media3
  `colorInfo=null`) are still treated as HDR via their `dvhe`/`dvh1`/`dvav` codec.
- **Jellyfin folders in the home library** — the folder tiles in the Jellyfin
  browser now carry an **Add to library** button that pins that server folder
  onto the home "Your library" grid (teal Jellyfin badge). Tapping it opens the
  TMDB details screen in Jellyfin mode: episodes list through the server API
  with `SxxExx` labels (+ TMDB episode names when the season data is cached),
  and play directly. Only the server URL + item id are stored — the token is
  re-matched against your saved servers on every open, so it keeps working
  across logins. Removing the folder unlists it (no files/grants touched).
- **Jellyfin series info auto-fetched on bookmark** — adding a folder from the
  Jellyfin browser also fetches the series' own metadata from the server
  (`JellyfinItemInfo`: poster + backdrop art, real title, year, rating, genres,
  overview) and caches it, so the home card shows the show's poster and TV/Movie
  badge without needing a TMDB match. The details screen shows a full
  backdrop/poster header with the series overview when TMDB finds nothing, and
  refreshes the info on open so the token-embedded artwork URLs stay current.
- **Per-episode details (TMDB)** — the single-episode details page now shows
  *that episode's* name, overview, air date, runtime, rating, **guest cast**,
  and a **Stills** gallery (via the per-episode endpoint with
  `append_to_response=credits,images`) instead of only the show's metadata. Runs
  only for the single-episode view — a folder with 100 files triggers no extra
  requests. Best-effort: on API failure the episode keeps its season-level data.
- **Season-folder title parsing fixed** — whole-season folders like
  `HOUSE.S02.1080p.10bit.BluRay.English.AAC.5.1.x265-Panda` now resolve to
  `HOUSE` (a bare `Sxx` season tag is stripped, audio-language and streaming-
  provider tags like `english`/`nf`/`amzn`/`hbo` are noise, and `H.265`/`X.264`
  codec tags are explicitly removed) — before, they resolved to a query with 0
  results and never got their poster.
- **Landscape details header shows artwork whole** — in landscape the metadata
  header now renders the poster/backdrop as a centered 16:9 box (capped to the
  viewport height) instead of cropping the art into a thin strip or filling the
  whole landscape screen; the rating badge stays anchored inside the box. Cast
  rows also fit at large text scales.
- **iOS build: CacheCleaner.swift wired into the Runner target** — CI builds
  were failing because the cache-cleaner file was added to the tree but not to
  the Xcode target; it's now in the Runner Sources build phase.

## 0.1.5

- **HDR10+ detected from the real bitstream (Android)** — Media3's format info
  can't tell HDR10+ from HDR10 (both use the same PQ transfer function), so the
  player now probes the video's first samples with `MediaExtractor` on a
  background thread, scanning for the ST 2094-40 SEI (ITU-T T.35 user data,
  country `0xB5` / provider `0x003C`, AVCC + Annex-B NAL framing). When found,
  the top-bar chip upgrades to the amber **HDR10+** label. Verified on-device:
  the HDR10+ "lake" file shows HDR10+, while SDR content is never labeled HDR.
- **PNG HDR badge overlay removed** — the transient bottom-right Dolby Vision /
  HDR10 / HDR10+ / HLG logo that popped in and faded out is gone; the live
  top-bar chip is now the single HDR indicator (it already showed the same
  information).
- **Safe filename-hint parsing** — the hint detector is token-aware, so a full
  title like `Adventure.mkv` can never be misread as Dolby Vision (the old
  substring check tripped on any name containing "dv"); hints are still never
  wired from titles, so labels reflect only the actual content.

## 0.1.4

- **Hardware video decode everywhere (fixes washed-out HDR + 4K HEVC stutter)** —
  the app previously built the player with NextRenderersFactory, which inserted
  `FfmpegVideoRenderer` *before* the MediaCodec renderer and claimed
  `video/hevc`, so every HEVC file decoded in FFmpeg **software**: 4K60
  stuttered and colors were washed out (the FFmpeg GL output carries no HDR
  dataspace). A new `DreamRenderersFactory` overrides only the audio renderers
  (appending the FFmpeg audio renderer for DTS/TrueHD/FLAC) and leaves video on
  the hardware decoder — vendor-agnostic (`c2.qti` / `c2.mtk` / `c2.samsung`).
  Verified on a Redmi Note 10: Sony 4K60 decoded by `OMX.qcom.video.decoder.hevc`
  with the same `BT2020_ITU_PQ` + `hdr metadata types=1` surface profile as
  Just Player.
- **Dolby Vision Profile 5 rejection on DV-less devices** — P5 (IPTPQc2 color)
  renders pink/green without a `video/dolby-vision` decoder, so the player now
  stops it with a friendly "This device cannot decode Dolby Vision Profile 5"
  error instead of garbage frames. P7/P8 keep playing as HDR10 via the HEVC
  fallback.

## 0.1.3

- **Brighter HDR (Android EDR ramp)** — OnePlus/OxygenOS only engages the
  display's HDR mode when the window asks for headroom. The player now sets
  `COLOR_MODE_HDR` + `setDesiredHdrHeadroom(5.0)` on the activity window and
  the video surface's consumer-side dataspace via `SurfaceControl`, so PQ/HDR
  content no longer clips bright highlights flat to white — verified on-device
  with the HDR10+ "lake" clip (`current hdr/sdr ratio > 1.0`, device
  composition instead of a client-composition fallback).
- **Resume survives device lock/unlock (Android)** — locking the phone
  destroys the video surface; the player now pauses on background (saving the
  position) and, on resume, checks the native player's live state via a new
  `getState` channel method (Android + iOS): if the media was lost it reopens
  at the saved position instead of showing a dead screen.
- **Stability fixes** — relaunching from the launcher after unlock no longer
  pushes an empty player screen; TMDB details no longer overflows in landscape
  (regression-tested); the Jellyfin server list no longer overflows at short
  viewports; iOS network-share folder listing is much faster (background scan,
  no per-entry re-stat round-trips).
- **Play-next removed** — the player and details screens no longer chain
  sibling videos as a playlist; each video plays on its own (fixes a build
  failure and simplifies the transport state).
- **Settings footer** — "Made with ❤️ by Mangesh Ghodke".

## 0.1.2

- **TMDB metadata works in release builds** — the release workflow now bakes the
  TMDB API key (from a masked GitHub secret, never committed) into all Android
  APKs/AAB and the iOS IPA, so movie/TV metadata resolves out of the box. The
  misleading "add an API key in Settings → Metadata" prompt (that setting no
  longer exists) was replaced with an accurate no-key message.

## 0.1.1

- **TV series season/episode detection** — the TMDB details screen now shows the
  detected season and episode (`Season 2 · Episode 4`) with an `S02E04` chip for
  episode files, and Continue-watching cards label them too
  (`S02E04 · Continue from m:ss`).
- **File browser opens details first** — tapping a video in the in-app file
  browser (Internal storage / bookmarked folders) now opens the TMDB details
  screen with the folder as its playlist, so Play keeps play-next, instead of
  jumping straight into the player.
- **App icon in the repository** — `app_icon.png` at the repo root (the iOS
  1024px app icon) for use as the GitHub social preview and other branding.

## 0.1.0

First major release — all of the 0.0.x line's fixes plus the metadata and
browsing features below.

- **TMDB movie metadata + details screen** — tapping any video (Continue-watching
  cards, WebDAV/Jellyfin/file-browser listings) now opens a details screen with
  poster/backdrop art, the real title, year, synopsis, star rating, genres,
  runtime, and cast. The big **Play/Resume** button labels itself from the saved
  playhead and is always enabled — a slow or failed lookup shows the real error
  and never blocks playback. "Fix match" re-pins a wrong auto-match via a TMDB
  search and "Remove info" clears it; metadata is cached on-device. The API key
  is build-time only, supplied via `.env` (see below), and is never shown in the
  app or committed.
- **Aspect ratio / fit-mode picker** — the player's aspect button offers five
  modes (Fit, Crop to screen, Stretch to screen, 16:9, 4:3); the choice applies
  to the native video surface and persists per video, re-applied on play-next.
- **Jellyfin LAN discovery fix** — modern Jellyfin (10.11+) removed its mDNS/Bonjour
  responder entirely, so discovery now also runs the proprietary **UDP-7359
  broadcast probe** (native `MulticastLockManager.kt` on Android /
  `JellyfinDiscovery.swift` on iOS), with the legacy mDNS scan kept for Emby.
  The probe holds a Wi-Fi MulticastLock so broadcast frames are not dropped.
- **Build-time API keys via `.env`** — keys are now supplied with
  `--dart-define-from-file=.env` (gitignored; `.env.example` committed with
  placeholders) instead of a tracked file, so no secret ever lands in the repo.
- **iOS subtitle positioning fixes** — PGS/DVB bitmap cues that rendered
  oversized/off-screen in portrait are fixed (the aspect-fit video rect is now
  computed correctly), and all cue positioning moved into the host
  `SubtitleOverlayView`: text and bitmap cues are anchored to the video's
  aspect-fit rect — bottom-aligned to the picture, not the screen — and are
  re-positioned on every rotation/resize, so subtitles stay on the video in
  portrait, landscape, and after rotating mid-cue.

## 0.0.8

- **Jellyfin / Emby browsing + playback (Android + iPad)** — the home **+** menu's
  new **Jellyfin** entry opens a server list (saved + auto-discovered via mDNS on
  `_jellyfin._tcp` / `_emby._tcp`), libraries → folders → play with direct-play
  streaming (token as `api_key` query param, so no native changes were needed on
  either platform). Add/edit/delete servers with an inline connection test and
  optional sign-in; sessions persist in shared_preferences (no plaintext
  passwords), self-signed HTTPS is an opt-in per server, and a Jellyfin source
  badge shows on Continue-watching cards. Continue-watching taps rebuild the
  stream URL from the stable `jellyfin:<host>/<item>` resume key so rotation of
  the session token between launches never breaks resume playback. Added
  `multicast_dns` + the `CHANGE_WIFI_MULTICAST_STATE` permission (Android) and
  `_jellyfin._tcp`/`_emby._tcp` Bonjour services (iOS) for LAN discovery.
- **Source badges on Continue watching cards** — every card shows where the video
  plays from: WebDAV, CX SMB, Files/SMB, Files, or Network (colored badge,
  bottom-left).
- **iOS "Files" home** — the file browser's root now has a **Files** folder that
  opens the system Files-app home (iCloud Drive, On My iPad, Downloads, other
  providers); pick a video and it plays. The Documents folder and bookmarked
  folders stay listed below it.
- **Stable resume keys for network sources** — CX Explorer SMB handoffs resume by
  their stable path (`cx:` key) and iOS bookmarked-folder files by a remount-safe
  `folderbookmark:` key, so Continue watching keeps working even when the source
  URL rotates between sessions.
- **WebDAV browsing + playback (Android + iPad)** — add/edit/delete servers with an
  inline connection test, browse folders and stream videos straight into the
  player; credentials stored encrypted (Android Keystore / iOS Keychain),
  per-server self-signed HTTPS opt-in (default off), friendly plain-language
  errors.
- **iOS WebDAV folder listing fix** — multistatus XML is now parsed with namespace
  processing, so Apache/nginx/Nextcloud/Synology servers list folders correctly
  (the empty "Nothing here" was a silent parse failure, not an auth problem).
- **Card redesign** — home cards show the gradient/play-icon placeholder plus
  Continue-watching progress and source info (thumbnail extraction removed).

## 0.0.7

- **In-app SMB home entry hidden on all platforms** — NAS playback now goes through
  CX Explorer → "Open with" (Android) and the Files app → "Open with" / bookmarked
  folders (iPad), which cover local + NAS workflows without the audio-track-switch
  crash. The SMB code stays in the tree as a rebuild blueprint.
- Added an SMB/NAS playback tutorial with screenshots and a video walkthrough.

## 0.0.6

- **iPad SMB playback hardened** — SMB streams now load through a read-ahead
  sliding-window reader (`BufferedSMBReader`, 32 MiB) so Wi-Fi latency no longer
  triggers the buffering spinner mid-playback; audio-track switching on SMB
  streams reopens the session with a fresh connection (EPERM fix); AetherEngineSMB
  is linked correctly as a static SPM product.

## 0.0.4

- **iPad in-app SMB playback** via AetherEngineSMB — SMB shares browse and stream
  directly through the engine's custom `IOReader` source (AMSMB2 browse client).

## 0.0.3

- iPad SMB playback fixes — ATS local-network allowance, stream-URL extension +
  content type, and a synchronous connect before returning the URL.

## 0.0.2

- **Android playback via ExoPlayer/Media3** in a native `SurfaceView` PlatformView
  with real Dolby Vision output (`c2.qti.dv.decoder`, verified 4K@60 with zero
  dropped frames) and live HDR/codec/resolution chips.
- **iOS/iPad playback via AetherEngine** (FFmpeg demux/decode + native DV/HDR path)
  behind the same platform-view contract.
- **Subtitles** — embedded + sideloaded (SRT, ASS, WebVTT, TTML, SAMI, MicroDVD,
  MPL2, SubViewer) auto-paired from the video's folder, with a full track picker.
- **Audio track selection** — full track names and channels (e.g. DTS-HD MA 5.1);
  FLAC and E-AC3 work around buggy platform decoders via the bundled FFmpeg
  renderer.
- **In-app file browser** (Android storage / iPad Files folders), **"Open with"**
  integration (including CX Explorer's network-stream handoff), **resume playback**,
  **native refresh rate**, dark theme.
