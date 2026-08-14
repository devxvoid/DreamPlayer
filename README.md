# DreamPlayer

<p align="center">
  <img src="https://raw.githubusercontent.com/mangeshghodke/DreamPlayer/main/app_icon.png" width="120" height="120" alt="DreamPlayer icon">
</p>

[![License: GPLv3](https://img.shields.io/github/license/mangeshghodke/DreamPlayer?style=flat)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20iPad-blue)](https://github.com/mangeshghodke/DreamPlayer)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-46A6F2?logo=flutter&logoColor=white&color=46A6F2)](https://flutter.dev)
[![iOS build](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml/badge.svg)](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml)
[![Stars](https://img.shields.io/github/stars/mangeshghodke/DreamPlayer)](https://github.com/mangeshghodke/DreamPlayer)
[![Donate](https://img.shields.io/badge/Donate-Razorpay-2D8CF0)](https://rzp.io/rzp/cZ5afqVG)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-Support-EA4AAA?logo=github&logoColor=white)](https://github.com/sponsors/mangeshghodke/)

A cross-platform video player built with **Flutter**, designed for high-end playback on Android and iOS/iPad — including **Dolby Vision**, HDR10/HDR10+, and lossless audio formats like DTS-HD and TrueHD.

> **Android (primary):** playback runs on the native **ExoPlayer / Media3** engine inside a Flutter platform view, so the display receives a real HDR / Dolby Vision signal (no tone-mapped preview).
> **iOS/iPad:** playback runs on **AetherEngine** (FFmpeg demux/decode + native AVPlayer path for DV/HDR) behind the same platform-view contract; verified on the iPad Pro M2.

## Features

- **Dolby Vision playback** — DV P8 verified on-device: decoded by the Qualcomm hardware `c2.qti.dv.decoder` at 4K 3840×2160@60 fps with zero dropped frames and correct colors.
- **HDR on-screen display** — live chips for Dolby Vision, HDR10+, HDR10, HLG, SDR.
- **All major audio codecs** — DTS, DTS-HD, E-AC3, AC3, TrueHD, AAC, and more via Media3 `FFmpegAudioRenderer` (FLAC and E-AC3 work around buggy platform decoders).
- **Audio track selection** — pick any audio track mid-playback; the sheet shows the full track name and channels (e.g. `DTS-HD MA 5.1`).
- **Aspect ratio / fit-mode picker** — Fit, Crop to screen, Stretch to screen, 16:9, or 4:3 from the player's aspect button; the choice persists per video and is re-applied on play-next.
- **Subtitles — embedded + sideloaded with a full track picker** — every subtitle file sitting next to the video (SRT, SSA/ASS, WebVTT, TTML, SAMI, MicroDVD, MPL2, SubViewer) auto-attaches and the best match auto-selects; the CC button opens a picker over embedded container tracks plus all sideloaded files, with Off. Non-UTF-8 sidecars are re-encoded automatically. Cues are drawn by the host on both platforms and anchored to the video itself, so text and PGS/DVB bitmap subtitles hug the picture (not the screen edge) in portrait, landscape, and through rotation.
- **NAS / LAN playback** — stream files from network shares via **CX Explorer → "Open with"** on Android (CX serves them over a local HTTP proxy at full speed) and via the **Files app → "Open with"** on iPad. The in-app SMB browser existed on iPad (AMSMB2) but is hidden from the home screen (2026-08): switching audio tracks on an SMB stream could crash the app, and the picker/Open-with paths cover local + NAS workflows without it. See the **[SMB / NAS playback tutorial](docs/tutorials/play-smb-nas-videos.md)** ([video walkthrough](https://youtube.com/shorts/a7oR1yxGz2o)).
- **In-app file browser** — browse the whole device and play any video, no import needed: Android internal + SD storage, and on iPad a **Files** root that opens the system Files-app home (iCloud Drive, On My iPad, Downloads, other providers), plus the app's Documents folder and bookmarked folders.
- **"Open with" integration** — tap any video on the device and open it in DreamPlayer; works with file managers like CX Explorer (including their network-stream handoff via a local HTTP proxy).
- **WebDAV playback** — browse WebDAV servers and stream videos straight into the player on **both** platforms: add/edit/delete servers with an inline connection test, per-server **self-signed HTTPS** opt-in (default off), and credentials stored encrypted (Android Keystore / iOS Keychain — never plaintext, never sent to Dart).
- **Jellyfin / Emby browsing + playback** — the home **+** menu adds Jellyfin/Emby servers (with automatic **LAN discovery** via a UDP-7359 probe + mDNS), signs in, and browses libraries → folders → play. Playback direct-plays the Jellyfin URL with your token, reusing the existing HTTP pipeline on both platforms (self-signed HTTPS honors the same opt-in toggle as WebDAV). No password ever reaches the app's Dart code or disk.
- **Movie metadata (TMDB)** — every video (continue-watching cards, WebDAV/Jellyfin/file-browser listings) opens a details screen with poster/backdrop art, the real title, year, synopsis, star rating, genres, runtime, and cast. **TV episodes detect their season/episode** and the details screen + continue-watching cards label them (`Season 2 · Episode 4`, `S02E04`). "Fix match" lets you re-pin a wrong auto-match; metadata is cached so cards load instantly. The API key is a build-time value only — it is never bundled in the UI or shipped in source.
- **Live codec / resolution overlay** — video codec, audio codec + channel count, resolution, HDR format as the file plays.
- **Transport controls** — play/pause, seek bar, ±10s, fullscreen, buffering spinner, auto-hiding UI.
- **Continue watching** — the home library lists every partially-watched video, most recent first, with a progress bar and "Continue from m:ss"; each card carries a **source badge** showing where it plays from (WebDAV, CX SMB, Files/SMB, Files, Network).
- **Resume playback** — a video stopped mid-way continues from where you left off on the next open (bookmarked while playing / on pause / on background; cleared when it plays to the end). Resume keys stay stable across sessions even for rotating network URLs (`cx:` for CX SMB handoffs, `folderbookmark:` for iOS bookmarked folders).
- **Replay after end (iOS)** — the replay button and scrubber pull-back work even after playback reaches the end, by reloading the last-opened source.
- **Native refresh rate** — selects the display's highest refresh rate (e.g. 120 Hz) at startup.

## Tech stack

| Concern | Choice |
|---|---|
| Framework | Flutter (stable 3.44.x) |
| Playback engine (Android) | ExoPlayer / Media3 in a native `SurfaceView` PlatformView |
| Playback engine (iOS/iPad) | AetherEngine in a native `AVPlayerView` PlatformView (FFmpeg demux/decode + native path for DV/HDR) |
| Video decode | Android MediaCodec (hardware DV/HEVC/AVC; `c2.qti.dv.decoder` on device) |
| Audio decode | Media3 `FFmpegAudioRenderer` extension (`libmedia3ext.so`) |
| Subtitles | Media3 subtitle stack + custom SAMI/MicroDVD/MPL2/SubViewer parsers; auto-paired siblings from the video's folder; host-drawn text + PGS/DVB cues anchored to the video |
| NAS playback (iPad) | Via Files app → "Open with" + bookmarked folders (in-app SMB browser hidden 2026-08 — see Roadmap) |
| NAS playback (Android) | Via CX Explorer → "Open with" (CX streams over a local HTTP proxy) |
| WebDAV | In-app server list + folder browsing + streaming (Android `WebDAVClient.kt` / iOS `WebDAVClient.swift`); encrypted credentials; per-server self-signed HTTPS toggle |
| Jellyfin / Emby | Pure-Dart REST client (server add + LAN auto-discovery + sign-in + browse); direct-play with the user token, self-signed HTTPS opt-in |
| Movie metadata | TMDB details screen (pure Dart `tmdb_client.dart`); build-time API key via `--dart-define` |
| Video fit modes | Fit / Crop to screen / Stretch / 16:9 / 4:3 (native aspect-box control on both engines; persists per video) |
| HDR output | Hybrid-composition PlatformView keeps its own SurfaceFlinger layer → real HDR to the display |
| Reference architecture | [Nova Video Player](https://github.com/nova-video-player/aos-AVP) |
| Permissions | `permission_handler` (runtime `READ_MEDIA_VIDEO`); `MANAGE_EXTERNAL_STORAGE` for the file browser |
| Refresh rate | `flutter_displaymode` |

## Getting started

```bash
flutter pub get
flutter run                          # run on a connected Android phone
flutter test                         # run tests
flutter analyze                      # static analysis
```

Build a debug APK for your phone:

```bash
flutter build apk --debug --target-platform android-arm64
flutter install --debug -d <device-id>
```

Movie metadata (TMDB) needs a build-time API key — copy `.env.example` to `.env`, fill in your key, and pass it to the build:

```bash
flutter run --dart-define-from-file=.env
```

The key is compiled in at build time (never shown in the UI, never committed); the app still builds and runs without it — only metadata resolution is skipped.

## Download

Prebuilt binaries are attached to each [GitHub Release](https://github.com/mangeshghodke/DreamPlayer/releases). The current release is **0.1.1**; previous releases follow the **0.1.0** and **0.0.x** lines.

- **Android** — per-architecture release APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`) plus a **universal** APK that installs on any device, and the AAB for Google Play.
- **iOS / iPadOS** — the versioned `DreamPlayer-<version>.ipa` (e.g. `DreamPlayer-0.1.1.ipa`) is **unsigned** (Apple only allows App Store / TestFlight installs), so sideload it with a free Apple ID via **SideStore** or **AltStore** (guide below).

### Installing on iPhone / iPad (SideStore or AltStore)

Apple doesn't allow installing unsigned apps, so the IPA is signed on-device with your own Apple ID. SideStore and AltStore both do this and then **auto-refresh the 7-day signature** in the background over Wi-Fi.

1. Install **SideStore** or **AltStore** on your iPhone/iPad:
   - SideStore — [sidestore.io](https://sidestore.io)
   - AltStore — [altstore.io](https://altstore.io)
2. Download `DreamPlayer-<version>.ipa` from the [latest release](https://github.com/mangeshghodke/DreamPlayer/releases).
3. Open SideStore/AltStore → **+** → select `DreamPlayer-<version>.ipa`. It signs it with your Apple ID and installs.
4. The signature lasts **7 days**; SideStore/AltStore refresh it automatically over Wi-Fi — a weekly open is all that's needed.

Notes:
- A free Apple ID can keep ~3 sideloaded apps active per device.
- First-time setup of SideStore/AltStore needs a computer (or a second Apple device).
- No automatic updates — re-download the newest IPA from the Releases page when a new version is published.
- Playback of DRM-free local media is fully supported; Dolby Vision/HDR needs a panel that supports it (e.g. iPad Pro M2).

## Project layout

```
lib/
  main.dart                     # entry point (native refresh rate)
  app.dart                      # root MaterialApp, dark theme, nav shell
  theme/app_theme.dart          # dark theme
  models/
    video_item.dart             # library item model + codec labels
    hdr_format.dart             # HDR format enum
  utils/codec_info.dart         # HDR detection + codec → label mapping
  config/tmdb_api_key.dart      # build-time TMDB API key (--dart-define, never committed)
  services/
    display_refresh_rate.dart   # high refresh rate selection
    exo_player.dart             # ExoPlayerController + ExoPlayerView platform view
    resume_store.dart           # per-video resume position store (shared_preferences)
    continue_watching.dart      # continue-watching list (shared_preferences JSON)
    file_browser.dart           # file-browser channel wrapper
    webdav_client.dart          # WebDAV channel wrapper + WebDavServer model
    jellyfin_client.dart        # Jellyfin/Emby REST client + server model + mDNS/UDP discovery
    tmdb_client.dart            # TMDB metadata: filename parser, API, cache + facade
    open_intent.dart            # "Open with" intent bridge
    support_links.dart          # donation links (Razorpay, GitHub Sponsors)
    smb_client.dart             # SMB channel wrapper (ipad in-app shares; hidden from the UI)
  screens/
    home_screen.dart            # Continue watching grid + **+** source menu (Jellyfin / WebDAV / storage / folder)
    player_screen.dart          # ExoPlayer/AetherEngine playback + live chips + controls + subtitle/audio/aspect pickers
    tmd_details_screen.dart     # TMDB details: poster/backdrop, rating, genres, cast + Resume/Play + Fix match
    jellyfin_screen.dart        # Jellyfin/Emby server list + discovery + sign-in → libraries → folders → play
    file_browser_screen.dart    # in-app device file browser
    webdav_screen.dart          # WebDAV server list → folders → play (self-signed toggle)
    smb_screen.dart             # in-app SMB share browser (hidden from the UI 2026-08)
    settings_screen.dart        # settings + About + open-source licenses
  widgets/
    video_card.dart             # library card with HDR/audio/source badges
    format_chip.dart            # colored codec/HDR chip
android/app/src/main/kotlin/com/dreamplayer/app/
  ExoPlayerView.kt              # native PlayerView platform view + channels
  SubtitleFormats.kt            # subtitle MIME map + sibling auto-pairing + charset handling
  DreamSubtitleParserFactory.kt # SAMI/MicroDVD/MPL2/SubViewer parsers
  FileBrowser.kt                # device storage browsing channel
  WebDAVClient.kt               # WebDAV browse/test channel (encrypted credentials)
  MulticastLockManager.kt       # Wi-Fi MulticastLock + Jellyfin UDP-7359 discovery probe
  MainActivity.kt               # registers platform views + intent handling
ios/Runner/
  AvPlayerView.swift            # AetherEngine platform view + channels; host SubtitleOverlayView; SMB via AetherEngineSMB custom source (unused — entry hidden)
  BufferedSMBReader.swift       # read-ahead sliding-window IOReader (32 MiB) for SMB/WebDAV playback
  SMBClient.swift               # SMB client (channel dreamplayer/smb): AMSMB2 browse + AetherEngineSMB playback connections (unused — entry hidden)
  WebDAVClient.swift            # WebDAV browse/test channel (Keychain credentials)
  JellyfinDiscovery.swift       # Jellyfin UDP-7359 broadcast probe (channel dreamplayer/multicast)
  FileBrowser.swift             # Files-app home + Documents + bookmarked-folder browsing channel
  IntentBridge.swift            # "Open with" intent channel
test/
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting tests
  resume_key_test.dart          # stable resume keys (CX SMB, bookmarked folders)
  resume_store_test.dart        # resume-position persistence
  continue_watching_test.dart   # continue-watching list + source badges
  playback_source_test.dart     # continue-watching source badges
  jellyfin_test.dart            # Jellyfin model / URL unit tests
  tmdb_test.dart                # TMDB filename parser + metadata store round-trip
```

## Roadmap

- [x] Android playback via ExoPlayer/Media3 PlatformView
- [x] Dolby Vision + lossless audio on-device (DV P8, E-AC3)
- [x] Remove mpv/media_kit (cannot output Dolby Vision)
- [x] Subtitles: embedded + sideloaded with a full track picker (SRT, ASS, VTT, TTML, SAMI, MicroDVD, MPL2, SubViewer)
- [x] iOS/iPad playback (AetherEngine; FFmpeg demux/decode + native DV/HDR path)
- [x] WebDAV browsing + playback (Android + iPad; self-signed HTTPS opt-in; encrypted credentials)
- [x] Jellyfin / Emby browsing + playback (server add + LAN auto-discovery + sign-in + browse + direct-play)
- [x] TMDB movie metadata details screen (poster/art, rating, genres, cast; Resume/Play; Fix match)
- [x] Aspect ratio / fit-mode picker (Fit / Crop / Stretch / 16:9 / 4:3, persists per video)
- [x] Continue watching with source badges (WebDAV / CX SMB / Files/SMB / Files / Network / Jellyfin)
- [~] In-app SMB/LAN playback on iPad (AMSMB2 browse + stream) — **hidden 2026-08**: switching audio tracks on an SMB stream could crash the app; NAS files reach the app via CX/Files "Open with" instead. Code stays in the tree as a rebuild blueprint.
- [ ] MediaStore scanning for the library
- [x] GitHub Releases (Android APKs for all ABIs + universal; unsigned iOS IPA)
- [ ] Play Store / TestFlight distribution (paid Apple Developer account)

## License

Copyright (C) 2026 Mangesh Ghodke. This project is free software released under the **GNU General Public License v3.0** (or any later version) — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

DreamPlayer is GPLv3 because the Android build links [nextlib-media3ext](https://github.com/anilbeesetti/nextlib) (GPLv3), an FFmpeg extension for Media3 that provides the lossless audio decoders (DTS, TrueHD, E-AC3). Under GPLv3 you are free to use, modify, and redistribute this software (including commercially); modified versions must also be released under GPLv3.

## Support

If DreamPlayer is useful to you, consider supporting the project:

- [Razorpay](https://rzp.io/rzp/cZ5afqVG) — pay via UPI, cards, or netbanking (India)
- [GitHub Sponsors](https://github.com/sponsors/mangeshghodke/) — recurring support

Both options are also in the app under **Settings → Support**.

Third-party components are used under their own licenses:

| Component | License |
|---|---|
| AndroidX Media3 / ExoPlayer | Apache 2.0 |
| nextlib-media3ext (Android FFmpeg) | GPLv3 |
| AetherEngine (iOS engine) | LGPL-3.0 + Apple Store/DRM exception |
| FFmpeg frameworks (iOS, via FFmpegBuild) | LGPL-2.1+ |
| AMSMB2 (iOS SMB client) | MIT |
| Flutter / Dart | BSD-3-Clause |
| permission_handler, flutter_displaymode, cupertino_icons | MIT |
| shared_preferences | BSD-3-Clause |

Dolby Vision, DTS, HDR10, and other trademarks belong to their respective owners.
