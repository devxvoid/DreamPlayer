# DreamPlayer

<p align="center">
  <img src="https://raw.githubusercontent.com/mangeshghodke/DreamPlayer/main/app_icon.png" width="200" alt="DreamPlayer icon">
</p>

[![License: GPLv3](https://img.shields.io/github/license/mangeshghodke/DreamPlayer?style=flat)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20iPad%20%7C%20Android%20TV-blue)](https://github.com/mangeshghodke/DreamPlayer)
[![Flutter](https://img.shields.io/badge/Flutter-3.44-46A6F2?logo=flutter&logoColor=white&color=46A6F2)](https://flutter.dev)
[![iOS build](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml/badge.svg)](https://github.com/mangeshghodke/DreamPlayer/actions/workflows/ios.yml)
[![Donate](https://img.shields.io/badge/Donate-Razorpay-2D8CF0)](https://rzp.io/rzp/cZ5afqVG)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-Support-EA4AAA?logo=github&logoColor=white)](https://github.com/sponsors/mangeshghodke/)

A cross-platform video player for **Android, iOS/iPad, and Android TV** — built for true Dolby Vision, HDR10/HDR10+, and lossless audio playback.

## Highlights

### Dolby Vision & HDR
- Plays **Dolby Vision** Profile 8 at 4K 60fps with zero dropped frames
- Full **HDR10 / HDR10+ / HLG** passthrough to the display panel
- Live on-screen chips showing the active HDR format, video codec, audio codec, and resolution
- Graceful fallback on non-DV devices (plays as HDR10 or shows a clean error)

### Lossless Audio
- All major codecs: **DTS, DTS-HD, TrueHD, E-AC3, AC3, AAC, FLAC** and more
- Mid-playback **audio track switching** with full track names and channel info
- Optional **audio passthrough** over HDMI for Dolby Atmos / DTS:X on compatible soundbars

### Subtitles
- **Embedded + sideloaded** — every subtitle file next to the video auto-attaches
- Supports SRT, SSA/ASS, WebVTT, TTML, SAMI, MicroDVD, MPL2, SubViewer
- Full track picker with Off option; subtitles are anchored to the video, not the screen

### Network Playback
- **SMB / NAS** — in-app SMB browser on Android; CX Explorer "Open with" handoff
- **WebDAV** — browse and stream from WebDAV servers on both platforms
- **Jellyfin / Emby** — browse libraries, direct-play with auto-discovery
- **Files app "Open with"** on iPad with bookmarked folders
- Encrypted credentials (Android Keystore / iOS Keychain)

### Smart Library
- **Continue watching** — resume any partially-watched video with progress bars
- **User-added folders** — add a TV show or movie folder, get a TMDB poster and episode list
- **Jellyfin folders in the home library** — server shows sit alongside local folders
- **File browser** — browse device storage and play any video without importing

### Movie Metadata (TMDB)
- Every video opens a **details screen** with poster, backdrop, synopsis, rating, genres, runtime, and cast
- Metadata auto-fetches in the background — rows show poster thumbnails before you tap
- TV episodes labeled with Season/Episode info
- "Fix match" to correct a wrong auto-match

### Player Controls
- Play/pause, seek, ±10s, fullscreen, auto-hiding UI
- **Swipe gestures** — left side for brightness, right side for volume (phones/tablets)
- Aspect ratio picker: Fit, Crop, Stretch, 16:9, 4:3 (persists per video)
- Resumes playback from where you left off, even after app close or screen lock

### Android TV / Fire TV
- Full 10-foot UI with D-pad navigation and custom focus highlights
- Leanback launcher banner
- Dolby Vision + HDR10 passthrough to the TV panel
- Audio passthrough for Atmos/DTS:X over HDMI

## Requirements

| Platform | Minimum version |
|---|---|
| Android | 5.0 (API 21) |
| iOS / iPadOS | 16.0 |

## Download

Prebuilt binaries are on the [Releases](https://github.com/mangeshghodke/DreamPlayer/releases) page.

- **Android** — universal APK + per-architecture APKs (arm64, armv7, x86_64)
- **iOS / iPadOS** — unsigned IPA; sideload with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io)

### Installing on iPhone / iPad

1. Install [SideStore](https://sidestore.io) or [AltStore](https://altstore.io) on your device
2. Download `DreamPlayer-*.ipa` from the [latest release](https://github.com/mangeshghodke/DreamPlayer/releases)
3. Open SideStore/AltStore → **+** → select the IPA
4. The 7-day signature auto-refreshes over Wi-Fi

## Getting Started

```bash
flutter pub get
flutter run                    # run on a connected device
flutter test                   # run tests
flutter analyze                # static analysis
```

For TMDB metadata, copy `.env.example` to `.env` and add your API key:

```bash
flutter run --dart-define-from-file=.env
```

## License

Copyright (C) 2026 Mangesh Ghodke. Released under the [GNU General Public License v3.0](LICENSE).

## Support

If DreamPlayer is useful to you, consider supporting the project:

- [Razorpay](https://rzp.io/rzp/cZ5afqVG) — UPI, cards, or netbanking (India)
- [GitHub Sponsors](https://github.com/sponsors/mangeshghodke/) — recurring support

Both are also in the app under **Settings → Support**.
