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
- **FLAC via FFmpeg + E-AC3 decoder workaround**: a custom `MediaCodecSelector` in `ExoPlayerView.kt` does two things: (1) returns no decoder for `audio/flac` so FLAC falls through to the bundled FFmpeg renderer — the platform MediaCodec FLAC decoder on some devices (incl. this OnePlus) allocates fixed 32 KiB input buffers and large FLAC frames (24-bit multichannel ~54 KiB) die with `DecoderInputBuffer$InsufficientCapacityException: Buffer too small`; (2) skips any `c2.dolby.eac3.decoder` for `audio/eac3`/`audio/eac3-joc` — on this OnePlus the codec2 resource manager repeatedly releases that hardware decoder as soon as it starts, so Media3's audio renderer spins in an endless re-init loop and **no AudioTrack is ever created (silent playback)**. With the Dolby component excluded, the AOSP software E-AC3 decoder is used and the renderer is stable. Verified on-device: Sonic FLAC plays continuously; an E-AC3 (Dolby Atmos, 5.1) track plays with an active AudioTrack (48 kHz, channelMask `0x3f`, no churn, no errors).
- **File browser (CX-Explorer style)** (`lib/screens/file_browser_screen.dart`): browse the whole device storage in-app and play any video without importing. Folder icon in the home app bar opens it. Android side (`android/.../FileBrowser.kt`, channel `dreamplayer/files`): `hasAllFilesAccess` / `openAllFilesAccessSettings` / `getStorageRoots` (internal + SD card) / `listDirectory` (folders then video files, sorted, with sizes). Requires **`MANAGE_EXTERNAL_STORAGE`** (All Files Access) on Android 11+ — the screen shows a "Grant access" button that opens the system settings and re-checks on app resume. Tapping a video builds a `VideoItem` and pushes `PlayerScreen`. Verified on-device: Internal storage → Download → video → Dolby Vision People plays with live HDR/codec chips.
- **"Open with" / file-explorer integration** (`AndroidManifest.xml` `ACTION_VIEW` intent-filters for `content`/`file` schemes + video MIME types incl. `video/*`, matroska, mpeg, ts, avi, wmv, octet-stream): tapping a video anywhere on the device now offers DreamPlayer. `MainActivity` resolves the intent (file path or `content://` URI + display name via `OpenableColumns`) and forwards it over the `dreamplayer/intent` channel (`getInitialIntent` on launch / `open` on `onNewIntent`); `lib/services/open_intent.dart` turns it into a `VideoItem` and pushes `PlayerScreen` via a global `appNavigatorKey` in `lib/app.dart`. `VideoItem` gained an optional `uri` (content URIs) with `path` now nullable; `ExoPlayerView` opens a raw URI when no path is available. Verified on-device: "Open with" chooser lists DreamPlayer and launches Dolby Vision playback.
- **Home/settings status bar**: `RootShell` maps `MediaQuery.viewPadding.top` into `padding` (Android edge-to-edge reports `padding.top == 0`), so `SliverAppBar` never overlaps the status bar.
- **Responsive grid** (`lib/screens/home_screen.dart`): column count and card height computed from screen width; card text is `Expanded`/`Flexible`. Text scaling clamped to 1.3x app-wide.
- **Native refresh rate** (`lib/services/display_refresh_rate.dart`): calls `FlutterDisplayMode.setHighRefreshRate()` on Android at startup.
- **SMB / LAN playback (v1 core)** (`lib/screens/smb_screen.dart`, `lib/services/smb_client.dart`, `android/.../SMBClient.kt`, `SmbDataSource.kt`, channel `dreamplayer/smb`, smbj 0.14.0):
  - Saved servers with **Android Keystore AES-GCM encrypted passwords** in SharedPreferences (never plaintext); add/edit/delete/test connection.
  - **Share enumeration caveat**: SMB2 has no NetShareEnum, so smbj can't list a server's shares — `listShares` probes ~22 well-known names (videos/movies/media/downloads/home/...) and the user can add unusual share names manually (stored per-server, `addShare`).
  - **Direct streaming, no download**: custom ExoPlayer `SmbDataSource` (BaseDataSource, positioned `smbj File.read(offset)`) wired into `ExoPlayerView.kt` via `DefaultMediaSourceFactory(...).setDataSourceFactory(...)` (note: Media3 removed `ExoPlayer.Builder.setDataSourceFactory` — use `setMediaSourceFactory`). URIs are `smb://<serverId>/<share>/<path>`; credentials resolved natively in `SmbStore`, so passwords never reach Dart or the URI. Full seek (SMB2 read at offset), reconnect-per-open.
  - Home app bar `Icons.dns` entry. **Built + installed on CPH2573 but NOT yet verified against a real NAS.**
- Tests: 31 (`flutter test`) incl. no-overflow checks on small phone, tablet, landscape, and 2.0x text scale.

## Roadmap

### SMB / network shares (Android + iPad)

Play files from LAN/NAS SMB shares in-app, mirroring the existing file-browser pattern.

**Architecture**
- New native module per platform exposing a MethodChannel (same shape as `FileBrowser.kt` / `dreamplayer/files`):
  - Android: `SMBClient.kt` — channel `dreamplayer/smb`
  - iOS/iPad: `SMBClient.swift` — same channel
- Dart: `lib/services/smb_client.dart` (models + channel wrapper) + `lib/screens/smb_screen.dart` (server list → shares → folders → tap video → `PlayerScreen`).
- Playback passes an `smb://` URI through the existing `uri` path in `VideoItem` (like the "Open with" flow).

**Libraries**
| Platform | Choice | Why |
|---|---|---|
| Android | **smbj** (SMB2/3 only) | ~2× faster than jcifs-ng, handles 4K/REMUX bitrates; what Nova switched to for playback |
| Android (optional) | jcifs-ng | SMB1 legacy devices + LAN server auto-discovery only |
| iPad | **AMSMB2** / **SwiftSMB** (Swift wrapper over **libsmb2**, C) | Only mature SMB2/3 path on iOS; libsmb2 is what Nova is evaluating |
- **Licensing**: libsmb2 is LGPL-2.1 (constrains App Store distribution — needs relinkable/replaceable lib); app already ships GPLv3 FFmpeg extension so not a new concern for Android.

**Features**
1. *Servers*: add/edit/delete saved servers (name, host/IP, port 445, user, password, or Guest); credentials in Keychain (iOS) / Android Keystore (EncryptedSharedPreferences), never plaintext; LAN auto-discovery (broadcast/workgroup) + manual IP fallback; test connection + quick connect; saved-server status dot (online/offline).
2. *Browsing* (CX-Explorer style): server → shares → folders → files; breadcrumbs + up-nav; folders first, sorted by name/size/date; show size + modified date; player back returns to same folder.
3. *Playback*: direct streaming (no download) — Android = custom ExoPlayer `DataSource` over smbj seekable reads; iPad = `AVAssetResourceLoaderDelegate` serving bytes from the SMB stream; full seek; existing live HDR/codec chips unchanged; play-next-episode in folder; optional prefetch/cache-ahead setting + reconnect-on-drop/resume for high-bitrate files.
4. *Extras*: auto-pair subtitles from same folder (`.srt`/`.ass`); pin recently-used servers on home screen; DNS/WINS hostname resolution for NAS names.
- **Scope (v1)**: manual server add + Guest/basic auth + browse + stream + play-next. Add discovery + subtitles after.
- **Status**: v1 core landed (Android). Remaining: **on-device NAS verification**, LAN auto-discovery, saved-server status dots, play-next-episode, subtitles, reconnect/cache-ahead for high bitrates, and the iPad path (needs AVPlayer first).
- **Note**: iPad playback requires the AVPlayer path first (non-Android currently shows "not yet supported") — SMB-on-iPad lands with it.

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
