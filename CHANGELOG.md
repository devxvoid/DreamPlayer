# Changelog

All notable changes to DreamPlayer are documented here. Each release's entry is
pulled into the GitHub Release body automatically by `.github/workflows/release.yml`.

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
