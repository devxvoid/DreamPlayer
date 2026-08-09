# DreamPlayer

A cross-platform video player built with Flutter.

## Goal

A video player app supporting:
- **Android** (primary, tested on user's Android phone — CPH2573, Android 16) and **iOS/iPad** (user's iPad Pro M2)
- **All audio codecs**: DTS, DTS-HD, E-AC3, AC3, TrueHD, etc.
- **Dolby Vision** where the display supports it
- **FFmpeg-based** decoding engine

## Current status

- App **UI skeleton** done (library, player, settings; dark theme).
- **HDR / codec on-screen display** done (Dolby Vision, HDR10+, HDR10, SDR; E-AC3, DTS-HD, TrueHD, AAC, ...).
- **Responsive layout** — no overflow on phones/tablets/landscape/large text.
- **Native refresh rate** selected at startup (verified 120 Hz on device).
- **DOLBY VISION PLAYBACK WORKS on Android via ExoPlayer/Media3 PlatformView.**
  Verified on-device: the DV P8 test file (`dolby-vision-people`) decodes on the
  Qualcomm hardware **`c2.qti.dv.decoder`** at 4K 3840x2160@60 fps with zero
  dropped frames, correct colors (no mpv pink/green), audio via
  `c2.dolby.eac3.decoder` / Media3 `FFmpegAudioRenderer`. Implementation:
  native `SurfaceView` PlayerView in a Flutter `AndroidView` (hybrid-composition
  fallback keeps its own SurfaceFlinger layer → real HDR to the display) +
  `MethodChannel`/`EventChannel` per view. `ExoPlayerController.open()` issued
  before the platform view attaches is queued and flushed in `_attach`.
  **Gotcha fixed:** the backend must `setState` after creating the controller,
  or the buttons/video layer stay frozen in the pre-init state.
- **media_kit / libmpv fully REMOVED** from `pubspec.yaml`, `main.dart`,
  `player_screen.dart`, and the APK (no more `libmpv.so`/mediakit libs; only
  `libflutter.so` + `libmedia3ext.so` remain). Non-Android screens show a
  "not yet supported" message until the iOS AVPlayer path lands.
- **New direction**: playback on Android via **ExoPlayer/Media3** in a Flutter
  **PlatformView + MethodChannel** (HDR/DV-capable native surface), modeled on
  **Nova Video Player** architecture. Keep the Flutter UI/shell, the rendering/
  decoding layer is native Android code.

## Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable, 3.44.x) | Cross-platform, single codebase |
| Playback engine (Android) | **ExoPlayer / Media3** (native, in PlatformView) | HDR/DV passthrough-capable; working (`c2.qti.dv.decoder`). |
| Android audio decode | Media3 `FFmpegAudioRenderer` (ffmpeg extension) | DTS, DTS-HD, E-AC3, AC3, TrueHD — same bundled-FFmpeg approach Nova uses. |
| Reference architecture | **Nova Video Player** (`nova-video-player/aos-AVP`) | See "Playback research notes". |
| ~~media_kit / libmpv~~ | **retired** | Cannot do Dolby Vision (no passthrough, no RPU). |
| Permissions | `permission_handler` | Runtime `READ_MEDIA_VIDEO` request on video open |
| Refresh rate | `flutter_displaymode` | Selects highest refresh mode at startup |

### Device research notes (user's Android phone)
- Display: 1440x3168, supports 60/90/120 Hz, max luminance ~1400 nits.
- `supportedHdrTypes=[1, 2, 3, 4]` → **HDR10, HDR10+, Dolby Vision, HLG** all supported on the panel. Good news for the Dolby Vision goal.
- The phone runs at 60 Hz when the UI is idle and jumps to 120 Hz during animations (adaptive). Verified via `dumpsys SurfaceFlinger` after app launch.

### Playback research notes
- **`media_kit`/mpv is dead for this project's DV goal.** On-device verification:
  - HDR10 (PQ/BT.2020) tone-maps to SDR correctly via mpv `gpu` vo.
  - Dolby Vision P8 renders **pink/green**: mpv v0.36 + FFmpeg 6.0 cannot parse the
    DOVI RPU (file VUI reports `color_transfer/primaries=unknown`), so wrong colors.
    `gpu-next` vo is a frozen frame (media_kit renders via legacy `gpu` path; mpv
    PR #16818 pending). `hwdec:no` (software) gives correct colors but is too slow
    for 4K.
  - Flutter textures (what media_kit uses) have **no HDR path on any platform**
    (media-kit issue #615) — the display only ever sees SDR.
- **New plan (ExoPlayer/Media3, Nova-style):**
  - Render video into a native Android `SurfaceView`/`SurfaceFlinger`-driven
    `PlatformView` so the display receives real HDR/DV signal (the panel supports
    DV — `supportedHdrTypes` includes it).
  - **Nova Video Player architecture** (`https://github.com/nova-video-player/aos-AVP`):
    entry-point repo with `default.xml` manifest. Sub-repos:
    - `aos-Video` — Video UI (Kotlin, ExoPlayer-based playback)
    - `aos-MediaLib` — media library / MediaStore scanning
    - `aos-FileCoreLibrary` — file management (root/network)
    - `aos-avos` — C core multimedia engine using FFmpeg (probing/decoding)
    - Uses ExoPlayer (`exoplayer.xml`) + FFmpeg audio extension for the lossless
      codecs. Building: `cd Video && ./gradlew -Puniversal assembleNoamazonRelease`
  - Android audio codecs map to Media3 `FFmpegAudioRenderer` extension modules;
    `dts`, `truehd`, `eac3`, `ac3` etc. are FFmpeg decoders.
  - iOS/iPad DV is restricted by Apple APIs — ExoPlayer/Media3 is Android-only;
    iOS will need a separate native path (AVPlayer). For now focus Android.

## Implemented features

- **HDR detection** (`lib/models/hdr_format.dart`, `lib/utils/codec_info.dart`): parses hints like `DV P8`, `HDR10+`, `HDR10` into a `HdrFormat` (incl. `HLG`); maps raw codec names (`dts_hd`, `eac3`, `truehd`, `aac`, ...) to display labels. Live detection from Media3 format info: DV track codecs (`dvhe`/`dvh1`/`dvav`), `colorTransfer` (6→HDR10, 7→HLG).
- **Real playback** (`lib/screens/player_screen.dart`): Android uses a native **ExoPlayer/Media3 PlatformView** (`lib/services/exo_player.dart`) with live codec/HDR/resolution chips, play/pause, seek, ±10s, mute, fullscreen, buffering spinner, error surface. Non-Android shows a "not yet supported" message. Widget tests run playback-less (`FLUTTER_TEST` gate).
- **Android permissions**: `READ_MEDIA_VIDEO` (+ `READ_EXTERNAL_STORAGE` ≤ API 32) requested at runtime via `permission_handler` when a video is opened. `compileSdk = 37` required by `permission_handler`.
- **Player overlay** shows HDR format + video/audio codec + resolution chips; library cards show an HDR badge + audio codec label.
  - **DV dedup**: for Dolby Vision the purple HDR chip already says "Dolby Vision", so the redundant video-codec chip is suppressed (no "Dolby Vision" twice).
  - **Chip layout**: landscape puts back button + title + chips in one `Wrap` on the same row; portrait shows title row, then chips `Wrap` below.
- **Player controls**: top bar (back + title) and a slim bottom bar (time + seekbar + audio/CC/tune/fullscreen) auto-hide after 3 s of playback (tap toggles them; kept visible while paused/buffering/dragging). **Center transport**: `replay_10` / big play-pause / `forward_10` float in a dark rounded pill in the middle of the screen, fading with the other controls. The bottom bar's background is a gradient mirroring the top bar (transparent → `black` 0.72), so both bars read at the same opacity. The player screen is **always immersive** (no system UI toggling during rotation — that fights the rotation animation and makes the video jitter); the bottom fullscreen button just forces landscape/portrait. Top-bar fullscreen button removed.
- **Audio track selection** (mute button replaced): the bottom bar's first button opens an "Audio tracks" bottom sheet listing every audio track from the native Media3 `currentTracks` (language · codec · channels · bitrate), with the active track check-marked. Picking a track calls `setAudioTrack` → native `TrackSelectionParameters` override → `onTracksChanged` re-emits → the top-bar audio chip (live codec + channel count) updates automatically. Native plumbing in `android/.../ExoPlayerView.kt` (`buildAudioTracks`, `selectAudioTrack`), pushed on every event as `audioTracks`/`selectedAudioTrack`; Dart model `ExoAudioTrack` in `lib/services/exo_player.dart`. Verified on-device: Sonic (DTS-HD MA + FLAC) switches DTS-HD → FLAC and the chip follows.
- **FLAC via FFmpeg**: the platform MediaCodec FLAC decoder on some devices (incl. this OnePlus) allocates fixed 32 KiB input buffers; large FLAC frames (24-bit multichannel ~54 KiB) then die with `DecoderInputBuffer$InsufficientCapacityException: Buffer too small`. Fixed with a custom `MediaCodecSelector` in `ExoPlayerView.kt` that returns no decoder for `audio/flac`, so FLAC falls through to the bundled FFmpeg renderer (dynamic buffers). Everything else keeps its normal decoder (E-AC3 → `c2.dolby.eac3.decoder`, video → hardware). Verified on-device: Sonic FLAC track plays continuously.
- **File browser (CX-Explorer style)** (`lib/screens/file_browser_screen.dart`): browse the whole device storage in-app and play any video without importing. Folder icon in the home app bar opens it. Android side (`android/.../FileBrowser.kt`, channel `dreamplayer/files`): `hasAllFilesAccess` / `openAllFilesAccessSettings` / `getStorageRoots` (internal + SD card) / `listDirectory` (folders then video files, sorted, with sizes). Requires **`MANAGE_EXTERNAL_STORAGE`** (All Files Access) on Android 11+ — the screen shows a "Grant access" button that opens the system settings and re-checks on app resume. Tapping a video builds a `VideoItem` and pushes `PlayerScreen`. Verified on-device: Internal storage → Download → video → Dolby Vision People plays with live HDR/codec chips. Known limitation: `.m2ts` files fail with `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED` (Media3 has no TS/M2TS extractor — its `TsExtractor.sniff` only accepts 188-byte TS packets; M2TS uses 192-byte packets).
- **"Open with" / file-explorer integration** (`AndroidManifest.xml` `ACTION_VIEW` intent-filters for `content`/`file` schemes + video MIME types incl. `video/*`, matroska, mpeg, ts, avi, wmv, octet-stream): tapping a video anywhere on the device now offers DreamPlayer. `MainActivity` resolves the intent (file path or `content://` URI + display name via `OpenableColumns`) and forwards it over the `dreamplayer/intent` channel (`getInitialIntent` on launch / `open` on `onNewIntent`); `lib/services/open_intent.dart` turns it into a `VideoItem` and pushes `PlayerScreen` via a global `appNavigatorKey` in `lib/app.dart`. `VideoItem` gained an optional `uri` (content URIs) with `path` now nullable; `ExoPlayerView` opens a raw URI when no path is available. Verified on-device: "Open with" chooser lists DreamPlayer and launches Dolby Vision playback.
- **Home/settings status bar**: `RootShell` maps `MediaQuery.viewPadding.top` into `padding` (Android edge-to-edge reports `padding.top == 0`), so `SliverAppBar` never overlaps the status bar.
- **Responsive grid** (`lib/screens/home_screen.dart`): column count and card height computed from screen width; card text is `Expanded`/`Flexible`. Text scaling clamped to 1.3x app-wide.
- **Native refresh rate** (`lib/services/display_refresh_rate.dart`): calls `FlutterDisplayMode.setHighRefreshRate()` on Android at startup.
- Tests: 31 (`flutter test`) incl. no-overflow checks on small phone, tablet, landscape, and 2.0x text scale.

## CI / Deployment

- **iOS builds happen in GitHub Actions** (user has no Mac). Workflow: `.github/workflows/ios.yml`
  - Runs on `macos-latest`, builds unsigned IPA artifact always.
  - Signed build + TestFlight upload run only when secrets are configured.
  - Secrets needed: `IOS_CERT_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `APPSTORE_API_KEY`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID`.
- **Bundle ID (iOS)**: `com.dreamplayer.app`. **App display name**: `DreamPlayer`.
- **Android**: app label `DreamPlayer`; package still `com.example.dream_player` (TODO: align). Build/test locally on the phone.

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
flutter run --release    # test real-world smoothness (debug is jankier)
flutter build apk --debug --target-platform android-arm64 && flutter install --debug -d <device-id>
flutter build apk        # release APK (use --split-per-abi)
flutter build appbundle  # for Play Store
adb shell monkey -p com.example.dream_player -c android.intent.category.LAUNCHER 1   # launch app
adb shell dumpsys SurfaceFlinger | grep -a activeMode                                  # check refresh rate
```

## Display & smoothness (native refresh rate)

- **Android**: `flutter_displaymode` selects the display's highest refresh rate at app startup (`lib/services/display_refresh_rate.dart`). Many Android devices default apps to 60 Hz even on 90/120/144 Hz panels. Verified: panel runs 120 Hz during animations, 60 Hz when idle.
- **iOS/iPad Pro**: ProMotion 120 Hz is unlocked via `CADisableMinimumFrameDurationOnPhone = true` in `ios/Runner/Info.plist` (already set).
- **Playback cadence**: ExoPlayer renders at the video's FPS onto the platform-view SurfaceView. Revisit frame pacing once smoothness is assessed on-device.

## Project layout

```
lib/
  main.dart                     # entry point (native refresh rate, runs app)
  app.dart                      # root MaterialApp, dark theme, text-scale clamp, nav shell
  theme/app_theme.dart          # colors, dark theme (video apps are dark)
  models/
    video_item.dart             # VideoItem + codec label getters
    hdr_format.dart             # HdrFormat enum (SDR/HDR10/HDR10+/DV/HLG)
  utils/codec_info.dart         # HDR detection + codec -> label mapping + live label merge
  services/display_refresh_rate.dart  # high refresh rate selection (Android)
  services/exo_player.dart        # ExoPlayerController + ExoPlayerView platform view
  screens/
    home_screen.dart            # library grid (adaptive columns, sample data pointing at real files)
    player_screen.dart          # ExoPlayer/Media3 playback + live codec/HDR chips + controls
    settings_screen.dart        # settings list
  widgets/
    video_card.dart             # library card with HDR/audio badges
    format_chip.dart            # colored codec/HDR chip
test/
  widget_test.dart              # shell/navigation/overflow tests
  codec_info_test.dart          # HDR + codec formatting unit tests
```

## Workflow for the user (no Mac)

1. Develop + test on Android phone (USB debugging, `flutter run`).
2. Commit/push to `main`; iOS workflow in GitHub Actions builds the iPad version.
3. Later: configure code-signing secrets + TestFlight for installing on iPad Pro M2.
