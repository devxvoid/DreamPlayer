# DreamPlayer

A cross-platform video player built with Flutter.

## Goal

A video player app supporting:
- **Android** (primary, tested on user's Android phone) and **iOS/iPad** (user's iPad Pro M2)
- **All audio codecs**: DTS, DTS-HD, E-AC3, AC3, TrueHD, etc.
- **Dolby Vision passthrough** where the display supports it
- **FFmpeg-based** decoding engine

## Current status (baby steps)

Focus is on app **design/UI skeleton first**. Playback features come later.

## Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable) | Cross-platform, single codebase |
| Playback engine | `media_kit` (libmpv + bundled FFmpeg) | Supports DTS, DTS-HD, E-AC3, AC3, TrueHD via libmpv. This is the primary candidate. |
| Alt engine (research) | `ffmpeg_kit_extended_flutter` | FFmpeg 8.1.2 with native surface playback; fallback if media_kit lacks a feature |

### Playback research notes
- `media_kit` bundles libmpv which ships FFmpeg with broad codec support (`dts`, `dtshd`, `eac3`, `ac3`, `truehd` listed in its supported formats).
- Default Android libmpv build may be limited for some formats (e.g. TrueHD). The **full** mpv build (swap `default-*.jar` -> `full-*.jar` in `media_kit_libs_android_video` build.gradle) enables more codecs. Revisit when implementing playback.
- **Dolby Vision**: libmpv decodes DV (often as compatible HDR10 fallback on Android). True bitstream passthrough to a DV-capable display is device/HDMI dependent — open question to investigate on-device. iOS/iPad DV passthrough is restricted by Apple APIs.

## CI / Deployment

- **iOS builds happen in GitHub Actions** (user has no Mac). Workflow: `.github/workflows/ios.yml`
  - Runs on `macos-latest`, builds unsigned IPA artifact always.
  - Signed build + TestFlight upload run only when secrets are configured.
  - Secrets needed: `IOS_CERT_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `APPSTORE_API_KEY`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`.
- **Bundle ID (iOS)**: `com.dreamplayer.app`
- **Android**: build/test locally on user's phone via `flutter run`. Android package still `com.example.dream_player` (TODO: align).

## Repository / Git

- Remote: `https://github.com/mangeshghodke/DreamPlayer.git`
- Branch: `main`
- Never commit secrets.

## Commands

```bash
flutter pub get          # fetch dependencies
flutter analyze          # static analysis
flutter test             # run tests
flutter run              # run on connected Android phone (USB debugging)
flutter build apk        # release APK (use --split-per-abi)
flutter build appbundle  # for Play Store
```

## Project layout (planned)

```
lib/
  main.dart            # entry point
  app.dart             # root MaterialApp + theme
  theme/               # colors, dark theme (video apps are dark)
  models/              # VideoItem, etc.
  screens/
    home_screen.dart   # library of videos
    player_screen.dart # fullscreen playback (placeholder for now)
    settings_screen.dart
  widgets/             # reusable UI pieces
```

## Workflow for the user (no Mac)

1. Develop + test on Android phone (USB debugging, `flutter run`).
2. Commit/push to `main`; iOS workflow in GitHub Actions builds the iPad version.
3. Later: configure code-signing secrets + TestFlight for installing on iPad Pro M2.
